# WindowKeeper

**Remembers where your windows go at each desk, and puts them back.**

macOS loses your window layout all the time. A restart, waking from sleep, or plugging a
laptop into a different set of monitors leaves windows piled onto one screen or scattered
wherever macOS likes. Then you drag everything back by hand, every time. WindowKeeper is a
menu bar app that saves your layout for each monitor setup. It restores the layout after a
restart, after sleep, when you dock at a different desk, or when an app reopens.

---

## ⬇️ Download

<p align="center">
  <a href="https://github.com/smanke-org/WindowKeeper/releases/latest/download/WindowKeeper.dmg">
    <img src="https://img.shields.io/badge/Download-WindowKeeper.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download WindowKeeper.dmg" height="48">
  </a>
</p>

1. **[Download WindowKeeper.dmg](https://github.com/smanke-org/WindowKeeper/releases/latest/download/WindowKeeper.dmg)**
2. Open it and drag **WindowKeeper** to **Applications**.
3. Open WindowKeeper from Applications.
4. Grant **Accessibility** when asked (System Settings › Privacy & Security › Accessibility).
   WindowKeeper needs it to read and move other apps' windows.
5. Allow **Finder** the first time macOS asks. WindowKeeper uses it to save and restore
   desktop icon positions. You can turn that off in Settings.

Requires macOS 26 or later. Signed with Developer ID and notarized by Apple.

---

## What it does

- **Monitor Profiles.** Each set of monitors is its own profile, so a laptop that moves
  between desks keeps a separate layout for each one. Monitors are identified by their
  **serial number**. Two identical models are never confused, and rearranging them in
  System Settings changes nothing. A new set of monitors becomes a new profile
  automatically; rename it to the desk it belongs to.
- **Save** all windows, or just the frontmost app's, from the menu. Saves can also happen
  automatically on an interval you choose: seconds, minutes or hours.
- **Restore** all windows, or just the frontmost app's, from the current profile or any other
  saved one. Windows from another desk are mapped onto this desk's monitors left to right.
- **Automatic restore** happens in three cases, and each can be switched off in Settings:
  - when a known monitor setup with an external display is connected (docking, waking),
  - when WindowKeeper opens (at login after a restart),
  - when an app reopens: each window goes back as the app opens it.

## Features

- **Desktop icons.** Icon positions are saved and restored with the windows, for each desk.
  This includes disks and servers, which go back to their spot whenever they mount again.
  Icons are matched by file, so an icon renamed since the save is still found.
- **Undo Last Restore** puts windows and icons back where they were just before the last
  restore, whether it was automatic or not.
- **Lock a profile** in Monitor Profiles: auto-save never changes a locked layout. Save Now
  still does.
- **Keyboard shortcuts** for Save All and Restore All, set in Settings, work from any app.
- **iCloud.** Profiles are copied to `iCloud Drive/WindowKeeper/Macs/<this Mac>/`. Each Mac
  keeps its own folder. To copy a profile from another Mac, use
  *Monitor Profiles › Import from Another Mac…*.
- **Launch at login.**
- **Dock, menu bar, both or neither** (Settings › General). Right-click the Dock icon to open
  Settings. With both off, open WindowKeeper again from Applications to reach Settings.

## Good to know

- Windows are restored on the Space they are already in; WindowKeeper does not move windows
  between Spaces. Full-screen windows are left alone.
- WindowKeeper never launches apps; apps that aren't running are skipped. With *When an app
  reopens* on, their windows go back whenever you open them.
- After a restore, WindowKeeper watches the windows for about 20 seconds and undoes any
  moves made by the app or by macOS. If you drag a window yourself during that time,
  WindowKeeper leaves it where you put it.
- Finder ignores icon positions while the desktop is sorted (View › Sort By). Use *None* or
  *Snap to Grid*. Settings warns you when the desktop is sorted.
- After monitors change, Finder spends a few seconds rearranging the desktop. WindowKeeper
  waits for it to finish before putting icons back, and checks once more a few seconds later.
- Automatic saves pause for a minute after monitors change. They also skip any snapshot where
  every window has piled onto one display. So the clutter macOS leaves while monitors
  reconnect is never saved as your layout.

## Updates

WindowKeeper checks GitHub for a new release shortly after it opens. If there is one, the menu
shows *Update to …*, and nothing is installed until you click it and confirm. You can also
choose *Check for Updates…* at any time. To stop the automatic check, turn off
*Check for updates when WindowKeeper opens* in Settings.

Before installing, WindowKeeper makes sure the download is signed by the same developer and
notarized by Apple. It updates the app in place, so your Accessibility permission carries over.

## How it works

| Piece | Where |
|---|---|
| Monitor identity (EDID serial via the display's I/O Registry entry, with fallbacks) | `DisplayCatalog`, `DisplayKey` |
| Waiting for monitors to settle after wake/dock | `SettleTracker`, `Keeper` |
| Matching windows after a restart (title, then closest size) | `WindowMatcher` |
| Placing windows, mapping between desks, keeping title bars reachable | `Placement` |
| Guarding restored windows; respecting user drags | `RestoreSession`, `AppLaunchRestore` |
| Desktop icons over Apple Events (`osascript`, off the main thread) | `FinderDesktop` |
| Global shortcuts (Carbon hot keys) and the recorder | `HotKeys` |
| Local + iCloud storage, import | `ProfileStore` |

Pure logic lives in `WindowKeeperKit` and is covered by `swift test`.

The log at `~/Library/Logs/WindowKeeper.log` records what was saved and restored, and why.
It records counts only, never window titles.

## Building

```bash
swift test
./build_app.sh        # universal, Developer ID signed
./install.sh          # updates /Applications/WindowKeeper.app in place and opens it
./release.sh 1.0.1    # build, notarize, DMG, GitHub release
```

Launching with `WINDOWKEEPER_DEBUG=1` enables a test hook. It listens for a distributed
notification named `com.smanke.WindowKeeper.debug` with one of these as its object:
`save:<bundle id>`, `restore:<bundle id>`, `show:settings`, `show:profiles`, `dump:menu`,
`icons:save`, `icons:restore`, `undo:last`, `lock:on`/`lock:off` or `autosave:now`.
