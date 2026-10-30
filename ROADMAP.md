# Aeris Keeper — Roadmap

Status as of 30 Oct 2026. v1.0 locks, logs out or halts the Mac when a registered FIDO security key is removed,
re-locks if someone unlocks without one, and records incidents.

## Still to verify from 1.0

- Logout and Halt with unsaved work open.
- The 1.5s blip filter with a real unplug, and sleep/wake through a USB hub.
- First launch from a browser download on a fresh Mac, and on macOS 13 and Intel.

Verified live: lock on removal, re-lock without a key, back in with the key, incidents saved.

Decided: unlocking is strict. Inserting the key after unlocking re-locks and records an incident; the README tells
users to insert the key first. No grace window.

## Distribution

- **Notarization.** Requires the paid Apple Developer Program: a Developer ID certificate, hardened runtime with the
  Apple Events entitlement (logout and shut down), then notarize and staple. Removes the first-launch step.

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

6. **Restarted while armed** — remember that Keeper was armed; if the next launch follows a restart instead of a
   disarm, record an incident, so a restart used to get past Keeper leaves a trace.
7. **Stay armed across restarts (opt-in)** — start armed after login and re-lock until a registered key is present.
   Recovery for a lost key becomes Safe Mode (login items don't run), which an attacker with the password can use
   too: it adds friction, not a guarantee. Key-at-login proper needs macOS smart card login.

**UX**

8. **Auto-arm (opt-in)** — Keeper starts disarmed every login, so protection depends on remembering. Offer
   "Arm when a registered key is inserted".
9. **Key nicknames** — "Keychain", "Backup" instead of model + date once there are several identical keys.
10. **Registration feedback** — the admin prompt closes the panel; success is only visible by reopening it.
   Reopen the panel on success (Keeper deliberately sends no macOS notifications).
11. **Accessibility** — VoiceOver labels for the menu bar glyphs and status line; full keyboard navigation in the
   panel (no global shortcuts).
12. **Export incidents** — copy or save the incident history for a report.

**Engineering**

13. **Tests** — the state machine (blip filter, re-lock, arm/disarm rules) and CTAPHID framing are untested.
    Extract them from the UI so they can run headless.
14. **Split `Keeper.swift`** (~700 lines) into monitor, U2F, and UI files once tests exist.
15. **Fixtures for UI review** — the off-screen panel renderer used during design should live in the repo so every
    state can be re-rendered on each change.
