---
name: windowkeeper
description: Drive WindowKeeper, the app on this Mac that saves and restores window layouts per desk (each set of connected monitors, known by their serial numbers), from the shell with the `windowkeeper` command: show the current desk and its monitors, list monitor profiles and their saved windows, save the layout now, rename, lock or delete a profile, pause or resume auto-save, and restore windows. Use when the user asks where their windows were saved, wants their layout saved or put back, or names WindowKeeper.
---

# WindowKeeper

`windowkeeper` runs commands in the WindowKeeper app (a menu bar app). If the app is closed, the
command opens it in the background. If `windowkeeper` isn't on PATH, use
`/Applications/WindowKeeper.app/Contents/MacOS/WindowKeeper` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- A profile is one desk: the windows saved for one set of monitors. Find ids with
  `windowkeeper profiles list`. An id is 8 characters; any unique start, or the name, works.
- `windows restore` and `windows undo` move the person's real windows, and `profiles delete`
  can't be undone. Without `--yes` they only report what they would do. Show the user that
  report and ask before you run it again with `--yes`.
- `no_access`: WindowKeeper needs Accessibility permission. Only the person can give it.
- `busy`: the monitors are still settling (after wake or plugging in). Wait a few seconds.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/windowkeeper-test`
  in front. A test copy never moves windows.

## Main commands

| Command | Does |
| --- | --- |
| `windowkeeper status --json` | Current desk, connected displays, last save or restore, settings |
| `windowkeeper profiles list --json` / `profiles show <id> [--app A] --json` | Desks, and the windows saved for each app |
| `windowkeeper windows save [--app A] --json` | Save where windows are now (the open apps) |
| `windowkeeper windows restore [--app A] [--profile ID] [--yes] --json` | Put windows back; then `windows undo --yes` if wanted |
| `windowkeeper profiles update <id> [--name N] [--locked] --json` | Rename, or lock against auto-save |
| `windowkeeper autosave pause --json` / `autosave resume --json` | Stop or restart saving on a timer |

Everything else: `windowkeeper help`, and `windowkeeper help <command>` for its options.
