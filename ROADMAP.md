# Aeris Keeper — Roadmap

Status as of 30 Oct 2026. v1.0 locks, logs out or halts the Mac when a registered FIDO security key is removed,
re-locks if someone unlocks without one, and records incidents.

## Before v1.0 ships

**Must**

- **Owner gets flagged as an intruder.** Unlocking with the password *before* inserting the key re-locks the Mac
  and logs "Re-locked, no key" against the owner. Either teach the order (lock screen hint isn't possible, so the
  panel and README must say "insert key, then unlock") or give a short grace window after unlock for the key to
  appear before re-locking. The grace window weakens protection by the same few seconds; decide which.
- **Live-test what screenshots can't show:** Logout and Halt with unsaved work open, the 1.5s blip filter with a
  real unplug, sleep/wake through a USB hub. (Lock on removal and re-lock without a key: verified live 30 Oct.)
- **Repository:** `LICENSE` and `README.md`.

Done: bundle ID `com.aeris.keeper` with the U2F app ID fixed independently (`aeris-keeper`); app icon
(`Icon/make-icon.swift` → `Icon/AppIcon-1024.png`, packaged by `build.sh`).

**Should**

- **Distribution signing.** Ad-hoc signing only runs on this Mac. Anyone else needs a Developer ID–signed,
  notarized build, or they hit Gatekeeper.

## Next cycles

**Protection gaps**

1. **Action failed** — Logout/Halt can be blocked by an app with unsaved work, leaving the Mac open while the owner
   believes it's locked. Detect (session still active N seconds later), fall back to Lock, record an incident.
2. **Keeper killed while armed** — Quit asks for the admin password, but `kill` or Activity Monitor doesn't.
   Run under a LaunchAgent with `KeepAlive`, and on launch record "Stopped unexpectedly while armed".
3. **Tamper-proof storage** — registered keys and incidents live in user defaults, editable without admin.
   Move them behind a privileged helper (root-owned file), so the admin gate is real.
4. **Verify signatures** — identity relies on the key's "this handle is mine" answer; a purpose-built fake device
   could lie. Store the public key at registration and occasionally verify a signed challenge (needs a touch).
5. **Failed password attempts** — macOS only announces successful unlocks, so wrong passwords at the lock screen
   leave no trace in Keeper. Read failed authentications from the unified log and record them as incidents.

**UX**

6. **Auto-arm (opt-in)** — Keeper starts disarmed every login, so protection depends on remembering. Offer
   "Arm when a registered key is inserted".
7. **Key nicknames** — "Keychain", "Backup" instead of model + date once there are several identical keys.
8. **Registration feedback** — the admin prompt closes the panel; success is only visible by reopening it.
   Reopen the panel on success (Keeper deliberately sends no macOS notifications).
9. **Accessibility** — VoiceOver labels for the menu bar glyphs and status line; full keyboard navigation in the
   panel (no global shortcuts).
10. **Export incidents** — copy or save the incident history for a report.

**Engineering**

11. **Tests** — the state machine (blip filter, re-lock, arm/disarm rules) and CTAPHID framing are untested.
    Extract them from the UI so they can run headless.
12. **Split `Keeper.swift`** (~700 lines) into monitor, U2F, and UI files once tests exist.
13. **Fixtures for UI review** — the off-screen panel renderer used during design should live in the repo so every
    state can be re-rendered on each change.
