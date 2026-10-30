<p align="center"><img src="Icon/AppIcon-1024.png" width="96" alt=""></p>

<h1 align="center">Aeris Keeper</h1>

<p align="center">A security key for your Mac.<br>Remove the key, the Mac locks. Unlock without it, it locks again.</p>

<p align="center"><img src="docs/panel.png" width="320" alt="The Aeris Keeper panel, armed"></p>

## How it works

Register any FIDO security key. One touch at registration; after that, Keeper verifies it silently each time it is
inserted. An identical model will not pass.

Arm Keeper. While a registered key is present, nothing happens. Remove it, and after 1.5 seconds the Mac locks,
logs out, or shuts down — your choice. Unlock without the key and it locks again; the attempt is kept as an incident.

Disarming, quitting while armed, changing keys and clearing incidents require the administrator password.

## Install

Download `Aeris-Keeper.zip` from [Releases](https://github.com/hjbarraza/aeris-keeper/releases/latest), unzip it, and move **Aeris Keeper** to Applications.

Keeper is not notarized by Apple, so macOS stops it the first time. Allow it once, in any of these ways:

**Open Anyway** — any macOS version. Open Keeper, dismiss the warning, then go to **System Settings → Privacy & Security**,
scroll to Security and choose **Open Anyway**. Confirm with your password.

**Right-click → Open** — macOS 13 and 14. Right-click Keeper in Applications, choose **Open**, then **Open** again.
On macOS 15 and later this no longer works; use Open Anyway.

**Remove the quarantine flag** — from Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Aeris Keeper.app"
```

**Allow apps from anywhere** — turns Gatekeeper off for every app, not just Keeper. Run
`sudo spctl --master-disable`, then choose **Anywhere** under **System Settings → Privacy & Security → Allow
applications from**. Undo with `sudo spctl --master-enable`.

After the first launch Keeper opens normally.

## Use

Insert the key, then unlock. Unlock first, and Keeper will treat you as an intruder.

Everything else — responses, incidents, recovering a lost key — is in the [guide](docs/GUIDE.md).

## Lost your key

Keeper always starts disarmed, so a restart gets you back in.

1. Restart the Mac. If it's locked, hold the power button until it turns off, then turn it on. Unsaved work is lost.
2. Log in with your password as usual.
3. Open Keeper, choose **Remove** next to the lost key, and confirm with the administrator password.
4. Register a new key.

Register a second key as a backup, and keep it somewhere safe. Any registered key is enough.

## Build

```sh
./build.sh
```

Produces `Aeris Keeper.app` for Apple silicon and Intel, macOS 13 or later. It lives in the menu bar, opens at login,
and always starts disarmed. Tested on macOS 27.

## Limits

- Locking uses a private macOS function.
- Keys and incidents are stored in user preferences. The administrator password is enforced by Keeper, not by the system.
- Log out and shut down can be stopped by apps with unsaved work. Lock cannot.

## Roadmap

**Next**

- Notarized build — opens with a double-click
- Wrong passwords at the lock screen recorded as incidents
- A logout or shut down that doesn't happen falls back to lock
- Keeper restarts itself if force-quit while armed

**Later**

- Keys and incidents in storage only an administrator can change
- Signed challenges, so a key proves itself cryptographically
- Optional: arm automatically when a registered key is inserted
- Key nicknames · VoiceOver · incident export

The detail lives in [ROADMAP.md](ROADMAP.md).

## License

MIT. IBM Plex Mono is licensed under the SIL Open Font License 1.1.
