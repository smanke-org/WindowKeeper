# WindowKeeper

A macOS menu bar app that remembers where your windows go — per desk — and puts them back
after a restart, after sleep, when you dock at a different desk, or when an app reopens.

## What it does

- **Monitor Profiles.** Each set of monitors is its own profile, so a laptop that moves
  between desks keeps a separate layout for each one. Monitors are identified by their
  **serial number**, so two identical models are never confused and rearranging them in
  System Settings changes nothing. A new set of monitors becomes a new profile
  automatically; rename it to the desk it belongs to.
- **Save** all windows, or just the frontmost app's, from the menu — or automatically on an
  interval you choose (seconds, minutes or hours).
- **Restore** all windows or the frontmost app's, from the current profile or any other
  saved one (windows from another desk are mapped onto this desk's monitors left to right).
- **Automatic restore** — each can be switched off in Settings:
  - when a known monitor setup with an external display is connected (docking, waking),
  - when WindowKeeper opens (at login after a restart),
  - when an app reopens: each window goes back as the app opens it.
- **iCloud.** Profiles are copied to `iCloud Drive/WindowKeeper/Macs/<this Mac>/`. Every Mac
  keeps its own folder; *Monitor Profiles › Import from Another Mac…* copies a profile across
  when you want it.
- Launch at login, and self-updates from GitHub releases (it asks first).

## Install

Download `WindowKeeper.dmg` from the
[latest release](https://github.com/smanke-org/WindowKeeper/releases/latest/download/WindowKeeper.dmg),
drag WindowKeeper to Applications and open it. Then allow it under
**System Settings › Privacy & Security › Accessibility** — that is how it reads and moves
other apps' windows. Requires macOS 26 or later.

## Good to know

- Windows are restored on the Space they are already in; WindowKeeper does not move windows
  between Spaces. Full-screen windows are left alone.
- Apps that aren't running are skipped — WindowKeeper never launches apps. With *When an app
  reopens* on, their windows go back whenever you open them.
- After a restore, WindowKeeper keeps an eye on the windows for about 20 seconds and undoes
  moves made by the app or by macOS. If you drag a window during that time, it is yours.
- Automatic saves pause for a minute after monitors change and skip any snapshot where every
  window has piled onto one display, so the clutter macOS leaves while monitors reconnect is
  never saved as your layout.

## How it works

| Piece | Where |
|---|---|
| Monitor identity (EDID serial via the display's I/O Registry entry, with fallbacks) | `DisplayCatalog`, `DisplayKey` |
| Waiting for monitors to settle after wake/dock | `SettleTracker`, `Keeper` |
| Matching windows after a restart (title, then closest size) | `WindowMatcher` |
| Placing windows, mapping between desks, keeping title bars reachable | `Placement` |
| Guarding restored windows; respecting user drags | `RestoreSession`, `AppLaunchRestore` |
| Local + iCloud storage, import | `ProfileStore` |

Pure logic lives in `WindowKeeperKit` and is covered by `swift test`.

The log at `~/Library/Logs/WindowKeeper.log` records what was saved and restored, and why
(counts only, never window titles).

## Building

```bash
swift test
./build_app.sh        # universal, Developer ID signed
./install.sh          # updates /Applications/WindowKeeper.app in place and opens it
./release.sh 1.0.1    # build, notarize, DMG, GitHub release
```

Launching with `WINDOWKEEPER_DEBUG=1` enables a test hook: a distributed notification
named `com.smanke.WindowKeeper.debug` with object `save:<bundle id>`, `restore:<bundle id>`,
`show:settings`, `show:profiles` or `dump:menu`.
