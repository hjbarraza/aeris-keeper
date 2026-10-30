import SwiftUI
import AppKit
import IOKit
import ServiceManagement
import IOKit.hid
import CryptoKit

// FIDO security keys announce themselves with this HID usage page, whatever the brand.
let fidoUsagePage = 0xF1D0

/// A key registered by touch. Only the physical key that created `handle` will claim it.
struct RegisteredKey: Codable, Hashable, Identifiable {
    let vendor: Int
    let product: Int
    let name: String
    let handle: Data
    var added: Date? = nil
    /// Credential public key (P-256, x9.63), captured at registration so identity can be checked, not just the handle.
    var publicKey: Data? = nil
    var id: Data { handle }
    var model: String { String(format: "%04X:%04X", vendor, product) }
    /// Tells identical models apart in the list.
    var detail: String { added.map { "added " + $0.formatted(.dateTime.day().month(.abbreviated)) } ?? model }
}

/// A FIDO key currently plugged in.
struct Device: Identifiable {
    let id: UInt64 // IORegistry entry
    let vendor: Int
    let product: Int
    let name: String
    let hid: IOHIDDevice
    var checked = false
    var owner: Data? // handle of the registered key this device proved it holds
    var model: String { String(format: "%04X:%04X", vendor, product) }
}

/// One line in the log. Today's entries show the time; older ones add the date.
struct LogEntry: Codable, Hashable {
    let date: Date
    let text: String

    var stamp: String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: .current, calendar: .current))
            : date.formatted(.dateTime.day(.twoDigits).month(.abbreviated)) + " "
                + date.formatted(Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))
    }
}

enum RemovalAction: String, CaseIterable, Identifiable {
    case lock = "Lock"
    case logOut = "Log Out"
    case shutDown = "Shut Down"
    var id: String { rawValue }

    var code: String {
        switch self {
        case .lock: "Lock"
        case .logOut: "Logout"
        case .shutDown: "Halt"
        }
    }

    /// For the log: "Key removed, locked".
    var past: String {
        switch self {
        case .lock: "locked"
        case .logOut: "logged out"
        case .shutDown: "halted"
        }
    }

    var effect: String {
        switch self {
        case .lock: "Session preserved"
        case .logOut: "Session terminated"
        case .shutDown: "System power-off"
        }
    }
}

final class KeyMonitor: ObservableObject {
    static let shared = KeyMonitor()
    @Published var armed = false // always starts unarmed
    /// Set while a log out / shut down we triggered is in progress, so the system quitting us doesn't re-prompt.
    var systemActionInFlight = false
    @Published private(set) var log: [LogEntry] = [] // newest first
    /// Times protection was tested. Kept on disk and only cleared with the admin password, so an intruder can't wipe them.
    @Published private(set) var incidents: [LogEntry] = UserDefaults.standard.data(forKey: "incidentLog")
        .flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) } ?? []
    @Published var registrationError: String?
    @Published private(set) var touchDeadline: Date? // set while registration waits for a touch
    var awaitingTouch: Bool { touchDeadline != nil }
    @Published private(set) var registered: [RegisteredKey] = []
    @Published private var present: [UInt64: Device] = [:]
    @AppStorage("action") var action = RemovalAction.lock.rawValue

    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var wasConnected = false
    private var pendingLoss: DispatchWorkItem?
    private let u2fQueue = DispatchQueue(label: "u2f")

    /// At least one registered key is plugged in and has proved it's the same physical key.
    var connected: Bool { present.values.contains { $0.owner != nil } }
    func isPresent(_ key: RegisteredKey) -> Bool { present.values.contains { $0.owner == key.handle } }
    var detected: [Device] { present.values.filter { $0.checked && $0.owner == nil }.sorted { $0.id < $1.id } }

    init() {
        try? SMAppService.mainApp.register() // launch at login

        if let data = UserDefaults.standard.data(forKey: "verifiedKeys"),
           let keys = try? JSONDecoder().decode([RegisteredKey].self, from: data) {
            registered = keys
        }

        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { ctx, iter in
            Unmanaged<KeyMonitor>.fromOpaque(ctx!).takeUnretainedValue().handle(iter, added: true)
        }, me, &addedIter)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { ctx, iter in
            Unmanaged<KeyMonitor>.fromOpaque(ctx!).takeUnretainedValue().handle(iter, added: false)
        }, me, &removedIter)

        // Draining the iterators arms the notifications and picks up keys already plugged in.
        handle(addedIter, added: true)
        handle(removedIter, added: false)

        // Unlocking without a key just locks again, so the password alone isn't enough.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.armed, !self.connected else { return }
            self.incident(lockScreen() ? "Re-locked, no key" : "Re-lock failed")
        }
    }

    /// Arming is free; disarming needs the admin password.
    func setArmed(_ on: Bool) {
        guard on || adminAuthorized() else { return }
        armed = on
        note(on ? "Armed" : "Disarmed")
    }

    /// Quitting while armed would drop the protection, so it needs the admin password. The check itself lives in
    /// AppDelegate.applicationShouldTerminate, so every termination path is gated, not just this button.
    func quit() { NSApp.terminate(nil) }

    func register(_ device: Device) {
        guard adminAuthorized() else { return }
        registrationError = nil
        touchDeadline = Date().addingTimeInterval(30) // matches U2FDevice.register's wait
        u2fQueue.async {
            let credential = U2FDevice.session(device.hid) { $0.register() }
            DispatchQueue.main.async {
                self.touchDeadline = nil
                guard let credential else { self.registrationError = "Registration failed, try again"; return }
                self.registered.append(RegisteredKey(vendor: device.vendor, product: device.product, name: device.name,
                                                    handle: credential.handle, added: Date(), publicKey: credential.publicKey))
                self.note("Key registered")
                self.save()
                self.present[device.id]?.owner = credential.handle
                self.update()
            }
        }
    }

    func remove(_ key: RegisteredKey) {
        guard adminAuthorized() else { return }
        registered.removeAll { $0 == key }
        save()
        note("Key unregistered")
        for (id, device) in present where device.owner == key.handle { present[id]?.owner = nil }
        if !connected { armed = false } // otherwise the next unlock would re-lock with no way to satisfy it
        update()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(registered), forKey: "verifiedKeys")
    }

    /// Silently asks the device which registered key, if any, it holds. No touch needed.
    private func verify(_ device: Device) {
        let candidates = registered.filter { $0.vendor == device.vendor && $0.product == device.product }
        u2fQueue.async {
            let owner = candidates.isEmpty ? nil : U2FDevice.session(device.hid) { u2f in candidates.first { u2f.owns($0) }?.handle }
            DispatchQueue.main.async {
                guard self.present[device.id] != nil else { return }
                self.present[device.id]?.checked = true
                self.present[device.id]?.owner = owner
                if self.armed && owner == nil {
                    self.incident("Unknown key inserted")
                }
                self.update()
            }
        }
    }

    private func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        dict["PrimaryUsagePage"] = fidoUsagePage
        return dict
    }

    private func handle(_ iter: io_iterator_t, added: Bool) {
        while case let obj = IOIteratorNext(iter), obj != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(obj, &entry)
            if added, let hid = IOHIDDeviceCreate(kCFAllocatorDefault, obj) {
                func prop(_ name: String) -> Any? { IORegistryEntryCreateCFProperty(obj, name as CFString, nil, 0)?.takeRetainedValue() }
                let device = Device(id: entry, vendor: prop("VendorID") as? Int ?? 0, product: prop("ProductID") as? Int ?? 0,
                                    name: prop("Product") as? String ?? "Security key", hid: hid)
                present[entry] = device
                verify(device)
            } else {
                present.removeValue(forKey: entry)
            }
            IOObjectRelease(obj)
        }
        update()
    }

    /// Logs a change in key presence and fires the removal action when armed.
    /// A loss only counts after 1.5s, so a wobbly cable or a hub resetting on wake doesn't trigger it.
    private func update() {
        guard connected != wasConnected else { return }
        wasConnected = connected
        if connected {
            if let loss = pendingLoss { loss.cancel(); pendingLoss = nil; return } // just a blip
            note("Key inserted")
            return
        }
        let loss = DispatchWorkItem { [weak self] in
            guard let self, !self.connected else { return }
            self.pendingLoss = nil
            guard self.armed else { self.note("Key removed"); return }
            let response = RemovalAction(rawValue: self.action) ?? .lock
            self.note("Key removed, " + response.past)
            self.perform(response)
        }
        pendingLoss = loss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: loss)
    }

    func incident(_ event: String) {
        incidents = Array(([LogEntry(date: Date(), text: event)] + incidents).prefix(20))
        saveIncidents()
    }

    func clearIncidents() {
        guard adminAuthorized() else { return }
        incidents = []
        saveIncidents()
        note("Incidents cleared")
    }

    private func saveIncidents() {
        UserDefaults.standard.set(try? JSONEncoder().encode(incidents), forKey: "incidentLog")
    }

    private func note(_ event: String) {
        log = Array(([LogEntry(date: Date(), text: event)] + log).prefix(5))
    }

    private func perform(_ action: RemovalAction) {
        switch action {
        case .lock:
            if !lockScreen() { incident("Lock failed") }
        case .logOut:
            systemActionInFlight = true // the system will quit us; don't make it ask for the password again
            if !sendToLoginWindow("rlgo") { systemActionInFlight = false; incident("Log out failed") } // kAEReallyLogOut
        case .shutDown:
            systemActionInFlight = true
            if !sendToLoginWindow("shut") { systemActionInFlight = false; incident("Shut down failed") } // kAEShutDown
        }
    }
}

/// Speaks U2F (CTAP1) to a security key over HID. Blocking: use off the main thread.
final class U2FDevice {
    private let hid: IOHIDDevice
    private var inbox: [[UInt8]] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var channel: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    /// U2F application ID for Keeper's credentials. Fixed on purpose: changing it orphans every registered key,
    /// so it must not follow the bundle ID.
    private let appID = [UInt8](SHA256.hash(data: Data("aeris-keeper".utf8)))

    private init(_ hid: IOHIDDevice) { self.hid = hid }
    deinit { buffer.deallocate() }

    /// Opens the device, runs `body`, closes it.
    /// Each session gets its own IOHIDDevice: callbacks can't be unregistered, so a shared one would keep
    /// delivering reports to sessions that are already gone.
    static func session<T>(_ device: IOHIDDevice, _ body: (U2FDevice) -> T?) -> T? {
        guard let hid = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(device)),
              IOHIDDeviceOpen(hid, 0) == kIOReturnSuccess else { return nil }
        let u2f = U2FDevice(hid)
        let runLoop = CFRunLoopGetCurrent()!
        IOHIDDeviceRegisterInputReportCallback(hid, u2f.buffer, 64, { ctx, _, _, _, _, report, length in
            Unmanaged<U2FDevice>.fromOpaque(ctx!).takeUnretainedValue().inbox.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(u2f).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(hid, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(hid, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(hid, 0)
        }
        return u2f.openChannel() ? body(u2f) : nil
    }

    /// Creates a credential once the key has been touched (up to 30s). Returns the handle and the credential
    /// public key so later checks can be cryptographic rather than a bare "I know this handle".
    func register() -> (handle: Data, publicKey: Data)? {
        let challenge = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let deadline = Date().addingTimeInterval(30)
        let registerCommand = { self.apdu(0x01, 0x00, challenge + self.appID) }
        var response = registerCommand()
        let touched = response.sw == 0x6985 // most keys wait for a touch here
        while response.sw == 0x6985 && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.3, true)
            response = registerCommand()
        }
        // Response: 0x05 | public key (65) | handle length | handle | ...
        guard response.sw == 0x9000, response.data.count > 67 else { return nil }
        let publicKey = Data(response.data[1..<66])
        let length = Int(response.data[66])
        guard response.data.count >= 67 + length else { return nil }
        let handle = Data(response.data[67..<(67 + length)])

        // Some keys (the Feitian ePass) register without a touch but always want one to sign, so make them sign once.
        guard !touched else { return (handle, publicKey) }
        let signCommand = { self.apdu(0x02, 0x03, challenge + self.appID + [UInt8(length)] + [UInt8](handle)) }
        var signed = signCommand()
        while signed.sw == 0x6985 && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.3, true)
            signed = signCommand()
        }
        return signed.sw == 0x9000 ? (handle, publicKey) : nil
    }

    /// Does this physical key hold `key`? Recognition is a check-only authenticate: a key answers 0x6985 (touch
    /// required) only for a handle it created, and an error for a foreign one. When registration stored a public
    /// key, also ask for a silent signed assertion and verify it, so a device that merely echoes 0x6985 is not
    /// enough. Keys that insist on a touch even there fall back to recognition (the previous behaviour).
    func owns(_ key: RegisteredKey) -> Bool {
        let handle = [UInt8](key.handle)
        let challenge = [UInt8](repeating: 0, count: 32)
        let body = challenge + appID + [UInt8(handle.count)] + handle
        guard apdu(0x02, 0x07, body).sw == 0x6985 else { return false }
        guard let publicKey = key.publicKey else { return true }

        let reply = apdu(0x02, 0x08, body) // 0x08 = don't enforce user presence, sign
        guard reply.sw == 0x9000, reply.data.count > 5, reply.data[0] == 0x01,
              let pub = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: Data(reply.data[5...])) else {
            return true // the key can't prove itself silently; trust recognition
        }
        let counter = Data(reply.data[1..<5])
        let message = Data(appID + [0x01] + counter + challenge)
        return pub.isValidSignature(signature, for: message)
    }

    private func openChannel() -> Bool {
        let nonce = (0..<8).map { _ in UInt8.random(in: 0...255) }
        send(0x86, nonce)
        guard let reply = receive(), reply.cmd == 0x86, reply.data.count >= 12, Array(reply.data[0..<8]) == nonce else { return false }
        channel = Array(reply.data[8..<12])
        return true
    }

    private func apdu(_ ins: UInt8, _ p1: UInt8, _ body: [UInt8]) -> (sw: UInt16, data: [UInt8]) {
        send(0x83, [0x00, ins, p1, 0x00, 0x00, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body + [0x00, 0x00])
        // Ignore anything that isn't a MSG reply: keys send CTAPHID KEEPALIVE (0xBB) while they wait for a touch,
        // and treating that 1-byte packet as the answer made the touch loop bail out and registration fail.
        var reply: (cmd: UInt8, data: [UInt8])?
        while let next = receive() { if next.cmd == 0x83, next.data.count >= 2 { reply = next; break } }
        guard let reply else { return (0, []) }
        let sw = UInt16(reply.data[reply.data.count - 2]) << 8 | UInt16(reply.data[reply.data.count - 1])
        return (sw, Array(reply.data.dropLast(2)))
    }

    // CTAPHID framing: one init packet (channel, command, length, 57 bytes), then continuation packets (channel, seq, 59 bytes).
    private func send(_ cmd: UInt8, _ data: [UInt8]) {
        func out(_ packet: [UInt8]) {
            var report = packet + [UInt8](repeating: 0, count: 64 - packet.count)
            IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, 0, &report, 64)
        }
        out(channel + [cmd, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data.prefix(57))
        var rest = Array(data.dropFirst(57)), seq: UInt8 = 0
        while !rest.isEmpty {
            out(channel + [seq] + rest.prefix(59))
            rest = Array(rest.dropFirst(59))
            seq += 1
        }
    }

    private func receive() -> (cmd: UInt8, data: [UInt8])? {
        let deadline = Date().addingTimeInterval(3)
        func next() -> [UInt8]? {
            while inbox.isEmpty && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
            return inbox.isEmpty ? nil : inbox.removeFirst()
        }
        guard let first = next(), first.count >= 7 else { return nil }
        let total = Int(first[5]) << 8 | Int(first[6])
        var data = Array(first[7...].prefix(total))
        while data.count < total, let more = next() {
            guard more.count >= 5 else { continue } // a short report would trap on more[5...] below
            data += more[5...].prefix(total - data.count)
        }
        return (first[4], data)
    }
}

/// With auto-login, a restart lands in the account with no password, and Keeper starts disarmed.
func autoLoginEnabled() -> Bool {
    NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist")?["autoLoginUser"] != nil
}

/// Locks the screen via a private login.framework symbol. Returns false when the symbol is missing or the call
/// fails, so callers record it rather than claiming the Mac is locked.
@discardableResult
func lockScreen() -> Bool {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
          let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
    typealias Fn = @convention(c) () -> Int32
    return unsafeBitCast(sym, to: Fn.self)() == 0
}

/// Shows the standard macOS admin password prompt.
func adminAuthorized() -> Bool {
    var auth: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return false }
    defer { AuthorizationFree(auth, [.destroyRights]) }
    return "system.privilege.admin".withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { ptr in
            var rights = AuthorizationRights(count: 1, items: ptr)
            return AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .extendRights, .destroyRights], nil) == errAuthorizationSuccess
        }
    }
}

@discardableResult
func sendToLoginWindow(_ code: String) -> Bool {
    func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
    let event = NSAppleEventDescriptor(eventClass: fourCC("aevt"), eventID: fourCC(code), targetDescriptor: target,
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    do { try event.sendEvent(options: [.noReply], timeout: 10); return true } catch { return false }
}

/// Gates every way the app can quit. The panel button, ⌘Q, the Quit AppleEvent and `killall`/SIGTERM all reach
/// applicationShouldTerminate, so the admin password is required however the quit started. Force Quit (SIGKILL)
/// still bypasses — see ROADMAP.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let monitor = KeyMonitor.shared
        guard monitor.armed, !monitor.systemActionInFlight else { return .terminateNow }
        return adminAuthorized() ? .terminateNow : .terminateCancel
    }
}

@main
struct KeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = KeyMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(monitor: monitor)
        } label: {
            if monitor.awaitingTouch {
                keeperIcon(.touch)
            } else if monitor.armed {
                keeperIcon(.armed)
            } else if monitor.connected || monitor.registered.isEmpty {
                keeperIcon(.disarmed)
            } else {
                tinted("exclamationmark.triangle.fill", [.white, .systemRed])
            }
        }
        .menuBarExtraStyle(.window)
    }
}

let dim = Color(white: 0.5)

enum Glyph { case disarmed, armed, touch }

/// The Keeper glyph: a hexagon with a keyhole. Disarmed is an outline with a solid keyhole,
/// armed is a solid hexagon with the keyhole cut out, touch is an outline with a fingertip dot.
func keeperIcon(_ glyph: Glyph) -> Image {
    let armed = glyph == .armed
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let radius = armed ? 8.3 : 7.6 // the outline's stroke adds 0.7 outside, so the solid one grows to match
        let hexagon = NSBezierPath()
        for i in 0..<6 {
            let angle = Double.pi / 2 + Double(i) * .pi / 3 // pointy top, like SF Symbols' hexagon
            // CGFloat here resolves cos/sin ambiguously under the current SDK; compute in Double, widen.
            let point = NSPoint(x: 9 + radius * CGFloat(cos(angle)), y: 9 + radius * CGFloat(sin(angle)))
            i == 0 ? hexagon.move(to: point) : hexagon.line(to: point)
        }
        hexagon.close()

        let keyhole = NSBezierPath(ovalIn: NSRect(x: 7.1, y: 8.6, width: 3.8, height: 3.8))
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 8.3, y: 9.6))
        stem.line(to: NSPoint(x: 9.7, y: 9.6))
        stem.line(to: NSPoint(x: 10.3, y: 5.4))
        stem.line(to: NSPoint(x: 7.7, y: 5.4))
        stem.close()

        NSColor.black.set()
        if glyph == .touch {
            hexagon.lineWidth = 1.4
            hexagon.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.2, y: 6.2, width: 5.6, height: 5.6)).fill()
            return true
        }
        if armed {
            hexagon.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        } else {
            hexagon.lineWidth = 1.4
            hexagon.stroke()
        }
        keyhole.fill()
        stem.fill()
        return true
    }
    image.isTemplate = true
    return Image(nsImage: image)
}

/// Menu bar icons are monochrome templates unless built as a colored image.
/// Palette colors go from the symbol's front layer to its back (for the warning triangle: the "!", then the triangle).
func tinted(_ symbol: String, _ colors: [NSColor]) -> Image {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: colors))
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    image.isTemplate = false
    return Image(nsImage: image)
}

struct Panel: View {
    @ObservedObject var monitor: KeyMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AERIS KEEPER").font(.custom("IBMPlexMono-Medm", size: 11)).foregroundStyle(dim)
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).foregroundStyle(dim)
            }
            .padding(12)
            rule
            if monitor.registered.isEmpty { setup } else { console }
        }
        .buttonStyle(HoverStyle())
        .font(.custom("IBMPlexMono", size: 11))
        .foregroundStyle(.white)
        .frame(width: 320)
        .background(Color(white: 0.06))
    }

    /// First run: nothing but registering a key.
    @ViewBuilder private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No keys registered")
            Text(monitor.detected.isEmpty ? "Insert a security key to register" : "Register a key to protect this Mac")
                .foregroundStyle(dim)
                .padding(.bottom, monitor.detected.isEmpty ? 0 : 6)
            ForEach(monitor.detected) { device in
                keyRow(device.name, device.model, present: true, action: monitor.awaitingTouch ? nil : "Register") { monitor.register(device) }
            }
            registrationStatus
        }
        .padding(12)
        rule
        HStack {
            Spacer()
            Button("Quit") { monitor.quit() }.foregroundStyle(dim)
        }
        .padding(12)
    }

    @ViewBuilder private var console: some View {
        // Status and the action that changes it, side by side.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        keeperIcon(monitor.armed ? .armed : .disarmed)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(monitor.armed ? "Armed" : "Disarmed").font(.custom("IBMPlexMono-Medm", size: 14))
                        Text(monitor.connected ? "· key present" : "· key missing").foregroundStyle(monitor.connected ? dim : .red)
                    }
                    .foregroundStyle(monitor.armed ? .green : .white)
                    // Arming without a registered key would lock you out on next unlock.
                    if !monitor.armed && !monitor.connected {
                        Text("Insert a registered key to arm").foregroundStyle(dim)
                    }
                }
                Spacer()
                if monitor.armed || monitor.connected {
                    Button { monitor.setArmed(!monitor.armed) } label: {
                        Text(monitor.armed ? "Disarm" : "Arm")
                            .font(.custom("IBMPlexMono-Medm", size: 11))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.35)))
                            .contentShape(Rectangle())
                    }
                }
            }
            if autoLoginEnabled() {
                Text("Auto-login is on: a restart bypasses Keeper").foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(monitor.armed ? Color.green.opacity(0.07) : .clear) // armed reads differently at a glance
        rule
        VStack(alignment: .leading, spacing: 6) {
            Text("On key loss").foregroundStyle(dim)
            ForEach(RemovalAction.allCases) { action in
                Button { monitor.action = action.rawValue } label: {
                    HStack(spacing: 8) {
                        Text(action.code).frame(width: 52, alignment: .leading)
                        Text(action.effect)
                    }
                    .foregroundStyle(monitor.action == action.rawValue ? .white : dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            if monitor.action != RemovalAction.lock.rawValue {
                Text("Unsaved work will be lost").foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(12)
        rule
        VStack(alignment: .leading, spacing: 6) {
            Text("Keys").foregroundStyle(dim)
            ForEach(monitor.registered) { key in
                keyRow(key.name, key.detail, present: monitor.isPresent(key), action: "Remove") { monitor.remove(key) }
            }
            if !monitor.detected.isEmpty {
                Text("Detected").foregroundStyle(dim).padding(.top, 6)
                ForEach(monitor.detected) { device in
                    keyRow(device.name, device.model, present: true, action: monitor.awaitingTouch ? nil : "Register") { monitor.register(device) }
                }
            }
            registrationStatus
        }
        .padding(12)
        rule
        VStack(alignment: .leading, spacing: 2) {
            if !monitor.incidents.isEmpty {
                Group {
                    HStack {
                        Text("Incidents")
                        Spacer()
                        Button("Clear") { monitor.clearIncidents() }.foregroundStyle(dim)
                    }
                    ForEach(Array(monitor.incidents.prefix(5).enumerated()), id: \.offset) { _, entry in logLine(entry) }
                    if monitor.incidents.count > 5 { Text("+\(monitor.incidents.count - 5) earlier") }
                }
                .foregroundStyle(.red)
                Spacer().frame(height: 8)
            }
            Text("Log")
            ForEach(Array(monitor.log.enumerated()), id: \.offset) { _, entry in logLine(entry) }
            if monitor.log.isEmpty { Text("Nothing yet") }
        }
        .foregroundStyle(dim)
        .padding(12)
        rule
        HStack {
            Spacer()
            Button("Quit") { monitor.quit() }.foregroundStyle(dim)
        }
        .padding(12)
    }

    private func logLine(_ entry: LogEntry) -> some View {
        HStack(spacing: 0) {
            Text(entry.stamp).frame(width: 92, alignment: .leading)
            Text(entry.text)
        }
    }

    /// Registration feedback: a live touch prompt with a countdown, or the failure message.
    @ViewBuilder private var registrationStatus: some View {
        if let deadline = monitor.touchDeadline {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.25)
                    Text("Touch the key to register").font(.custom("IBMPlexMono-Medm", size: 11))
                    Spacer()
                    Text("\(max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up))))s").foregroundStyle(dim)
                }
            }
            .padding(.top, 6)
        } else if let error = monitor.registrationError {
            Text(error).foregroundStyle(.red).padding(.top, 6)
        }
    }

    private func keyRow(_ name: String, _ model: String, present: Bool, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(present ? "■" : "□")
            Text(name).lineLimit(1)
            Text(model).foregroundStyle(dim)
            Spacer()
            if let action { Button(action, action: perform).foregroundStyle(dim) }
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
    }
}

// Plain button with a faint highlight under the pointer.
struct HoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverLabel(label: configuration.label) }

    private struct HoverLabel: View {
        let label: Configuration.Label
        @StateObject private var hover = Hover()

        var body: some View {
            label
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(hover.on ? 0.1 : 0)))
                .padding(.horizontal, -4)
                .onHover { hover.on = $0 }
        }
    }

    private final class Hover: ObservableObject { @Published var on = false }
}
