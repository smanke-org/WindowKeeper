import AppKit
import WindowKeeperKit

/// The app's objects the commands work on, handed over at launch by AppDelegate.
@MainActor
enum AgentContext {
    static var keeper: Keeper?
    static var showProfiles: ((UUID?) -> Void)?
    /// Nil in a test copy: Settings shows the installed app's own preferences.
    static var showSettings: (() -> Void)?
}

/// Everything an agent can do in WindowKeeper. Add a command here and the CLI, `help`, and
/// the MCP tools all get it. Each `run` is on the main actor and calls the same code as the
/// menu bar menu, Monitor Profiles and the windowkeeper:// actions.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the current desk (the profile for the monitors connected now), the connected displays with their keys, the last save or restore (`lastActivity`), whether Accessibility access is allowed, and the automatic save and restore settings.",
                     example: "windowkeeper status --json", readOnly: true) { _ in
            let keeper = try keeper()
            let settings = AppSettings.shared
            let live = DisplayCatalog.current()
            var result: JSONObject = [
                "app": AppInfo.name, "version": AppInfo.version,
                "accessibilityAllowed": AXWindows.isTrusted,
                "desk": keeper.currentProfile.map { summary($0, current: true) } ?? NSNull(),
                "detecting": keeper.currentProfileID == nil,
                "displays": live.map { ["name": $0.name, "key": $0.key, "builtIn": $0.isBuiltin, "main": $0.isMain] as JSONObject },
                "lastActivity": keeper.lastActivity ?? NSNull(),
                "autoSave": settings.autoSave,
                "autoSaveEvery": interval(settings),
                "restoreWhenMonitorsConnect": settings.restoreOnProfileDetected,
                "restoreAtLaunch": settings.restoreOnLaunch,
                "restoreWhenAppOpens": settings.restoreOnAppRelaunch,
                "desktopIcons": settings.rememberDesktopIcons,
                "undoAvailable": keeper.undoSnapshot != nil,
                "restoring": RestoreSession.isActive,
                "profiles": keeper.store.library.profiles.count,
                "iCloud": cloud(keeper.store.cloudState),
            ]
            if AgentSocket.isTestRun { result["testCopy"] = true }
            return result
        },

        // MARK: Profiles

        AgentCommand(name: "profiles list", summary: "List the saved monitor profiles, one per desk (set of monitors). Returns `profiles` (id, name, current, monitors, windows, apps, icons, locked, lastSaved in UTC), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "windowkeeper profiles list --json", readOnly: true) { args in
            let keeper = try keeper()
            return try page(keeper.store.library.profiles, args, key: "profiles") { summary($0, current: $0.id == keeper.currentProfileID) }
        },
        AgentCommand(name: "profiles show", summary: "Show one profile: its monitors (and which are connected now) and the saved windows of each app, with the display each is on and its place on that display.",
                     params: [profileParam,
                              .init(name: "app", help: "only this app's windows (its name or bundle ID)")],
                     example: "windowkeeper profiles show 3f2a9c1e --json", readOnly: true) { args in
            let keeper = try keeper()
            let profile = try find(args.required("profile"))
            return detail(profile, current: profile.id == keeper.currentProfileID, app: args.string("app"))
        },
        AgentCommand(name: "profiles update", summary: "Rename a profile or lock it, as Monitor Profiles does. A locked profile is never changed by auto-save; Save still writes to it. Only the options you give change.",
                     params: [profileParam,
                              .init(name: "name", help: "a new name, like \"Home office\""),
                              .init(name: "locked", kind: .boolean, help: "true or false")],
                     example: "windowkeeper profiles update 3f2a9c1e --name \"Home office\" --locked --json") { args in
            let keeper = try keeper()
            let before = try find(args.required("profile"))
            if let name = args.string("name") {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.invalid("--name can't be empty") }
                keeper.store.rename(before.id, to: name)
            }
            if let locked = try args.bool("locked"), locked != before.isLocked { keeper.setLocked(locked, profileID: before.id) }
            guard let after = keeper.store.profile(id: before.id) else { throw AgentError.notFound("the profile went away while it was changing") }
            var result = summary(after, current: after.id == keeper.currentProfileID)
            result["changed"] = after != before
            return result
        },
        AgentCommand(name: "profiles delete", summary: "Forget a profile and every window and icon place saved in it, as Monitor Profiles' Delete does. Without --yes it only shows what it would delete.",
                     params: [profileParam],
                     example: "windowkeeper profiles delete 3f2a9c1e --yes --json", destructive: true) { args in
            let keeper = try keeper()
            let profile = try find(args.required("profile"))
            let current = profile.id == keeper.currentProfileID
            guard args.confirmed else {
                return ["wouldDelete": summary(profile, current: current),
                        "hint": "add --yes (over MCP, set yes to true) to delete it. It can't be undone"
                            + (current ? ". It is the current desk: WindowKeeper saves to a new profile for these monitors the next time they change" : "")]
            }
            keeper.store.delete(profile.id)
            return ["deleted": short(profile.id), "name": profile.name, "wasCurrent": current]
        },

        // MARK: Windows

        AgentCommand(name: "windows save", summary: "Save where windows are now into the current desk's profile, as the menu's Save All Windows Now (desktop icons too, when that setting is on) or Save <app> Windows does. Only apps that are open are saved.",
                     params: [.init(name: "app", help: "only this open app (its name or bundle ID)")],
                     example: "windowkeeper windows save --json") { args in
            let keeper = try keeper()
            guard AXWindows.isTrusted else { throw AgentError.noAccess }
            guard let profile = keeper.currentProfile else { throw detecting }
            let app = try args.string("app").map(openApp)
            let count = keeper.save(app.map { .app($0) } ?? .all)
            guard let count else { throw AgentError.invalid("WindowKeeper couldn't save just now. Run `windowkeeper status` to see why") }
            let after = keeper.store.profile(id: profile.id) ?? profile
            var result: JSONObject = ["saved": count, "desk": summary(after, current: true)]
            if let app { result["app"] = app.localizedName ?? app.bundleIdentifier ?? "" }
            if app == nil, AppSettings.shared.rememberDesktopIcons { result["icons"] = "saving in the background" }
            return result
        },
        AgentCommand(name: "windows restore", summary: "Move windows back to where a profile saved them, as the menu's Restore All Windows, Restore <app> Windows, Restore from Profile and Restore Desktop Icons do. This moves the person's real windows. Without --yes it only shows what it would restore.",
                     params: [.init(name: "app", help: "only this open app (its name or bundle ID)"),
                              .init(name: "profile", help: "restore from this profile instead of the current desk's (id or name)"),
                              .init(name: "icons-only", kind: .boolean, help: "only the desktop icons, from the current desk")],
                     example: "windowkeeper windows restore --app Safari --yes --json", destructive: true) { args in
            let keeper = try keeper()
            let iconsOnly = try args.bool("icons-only") == true
            if iconsOnly, args.string("app") != nil || args.string("profile") != nil {
                throw AgentError.usage("--icons-only restores the current desk's icons; leave out --app and --profile")
            }
            if iconsOnly, !AppSettings.shared.rememberDesktopIcons {
                throw AgentError.invalid("\"Remember desktop icon positions too\" is off in Settings, so WindowKeeper doesn't save or restore icons")
            }
            let app = try args.string("app").map(openApp)
            let chosen = try args.string("profile").map(find)
            guard let profile = chosen ?? keeper.currentProfile else { throw detecting }
            let apps = app.map { [$0] } ?? AXWindows.managedApps()

            guard args.confirmed else {
                var plan: JSONObject = ["profile": profile.name, "current": profile.id == keeper.currentProfileID]
                if iconsOnly {
                    plan["icons"] = profile.icons.count
                } else {
                    let open = Set(apps.compactMap(\.bundleIdentifier))
                    let byApp = Dictionary(grouping: profile.windows, by: \.bundleID)
                    plan["apps"] = byApp.keys.filter(open.contains).sorted().map { id -> JSONObject in
                        ["app": byApp[id]!.first!.appName, "bundleID": id, "windows": byApp[id]!.count]
                    }
                    plan["windows"] = profile.windows.filter { open.contains($0.bundleID) }.count
                    if app == nil {
                        plan["icons"] = AppSettings.shared.rememberDesktopIcons ? profile.icons.count : 0
                        plan["skippedNotOpen"] = byApp.keys.filter { !open.contains($0) }.map { byApp[$0]!.first!.appName }.sorted()
                    }
                }
                return ["wouldRestore": plan,
                        "hint": "add --yes (over MCP, set yes to true) to move these windows. It moves the person's real windows; `windowkeeper windows undo --yes` puts them back"]
            }
            try mayMoveWindows()
            if iconsOnly {
                keeper.restoreIconsOnly()
                return ["restoredIcons": profile.icons.count, "profile": profile.name, "undoAvailable": true]
            }
            let scope: Keeper.Scope = app.map { .app($0) } ?? .all
            guard let placed = keeper.restore(scope, from: chosen) else {
                throw AgentError.invalid("WindowKeeper couldn't restore just now. Run `windowkeeper status` to see why")
            }
            return ["restored": placed, "profile": profile.name, "undoAvailable": keeper.undoSnapshot != nil,
                    "note": "WindowKeeper guards the restored windows for 20 seconds; a window the person drags in that time stays where they put it"]
        },
        AgentCommand(name: "windows undo", summary: "Put windows (and desktop icons) back where they were just before the last restore, as the menu's Undo Last Restore does. Without --yes it only shows what it would do.",
                     example: "windowkeeper windows undo --yes --json", destructive: true) { args in
            let keeper = try keeper()
            guard let snapshot = keeper.undoSnapshot else {
                throw AgentError.invalid("there's no restore to undo. WindowKeeper keeps only the last one, until it quits")
            }
            guard args.confirmed else {
                return ["wouldUndo": ["windows": snapshot.windows.count, "apps": Set(snapshot.windows.map(\.appName)).sorted()] as JSONObject,
                        "hint": "add --yes (over MCP, set yes to true) to move these windows back. It moves the person's real windows"]
            }
            try mayMoveWindows()
            keeper.undoLastRestore()
            return ["undone": true, "windows": snapshot.windows.count]
        },

        // MARK: Settings and windows

        AgentCommand(name: "autosave pause", summary: "Pause auto-save: turns off Settings' \"Save window positions automatically\", so the saved layout stays as it is until it's resumed. Restores still happen.",
                     example: "windowkeeper autosave pause --json") { _ in
            try setAutoSave(false)
        },
        AgentCommand(name: "autosave resume", summary: "Resume auto-save: turns Settings' \"Save window positions automatically\" back on.",
                     example: "windowkeeper autosave resume --json") { _ in
            try setAutoSave(true)
        },
        AgentCommand(name: "open", summary: "Show one of WindowKeeper's windows: profiles (Monitor Profiles, with a profile picked out if you give one), settings, or help.",
                     params: [.init(name: "page", required: true, positional: true, help: "profiles, settings or help"),
                              .init(name: "profile", help: "with profiles: the profile to pick out (id or name)")],
                     example: "windowkeeper open profiles --json") { args in
            let keeper = try keeper()
            let page = try args.required("page").lowercased()
            switch page {
            case "profiles":
                let id = try args.string("profile").map { try find($0).id } ?? keeper.currentProfileID
                AgentContext.showProfiles?(id)
            case "settings":
                guard let show = AgentContext.showSettings else {
                    throw AgentError.invalid("a test copy doesn't open Settings: it would show the installed app's preferences")
                }
                show()
            case "help":
                // Help remembers its window's place in the preferences, which a test copy must not write.
                guard !AgentSocket.isTestRun else {
                    throw AgentError.invalid("a test copy doesn't open Help: it would write the window's place into the preferences")
                }
                HelpWindow.shared.show()
            default:
                throw AgentError.usage("no page \"\(page)\". Pages: profiles, settings, help")
            }
            return ["open": page]
        },
    ]

    // MARK: - Helpers

    private static let profileParam = AgentCommand.Param(name: "profile", required: true, positional: true,
                                                         help: "the profile's id (the first 8 characters are enough) or its name")

    private static var detecting: AgentError {
        AgentError.busy("WindowKeeper is still working out which monitors are connected. Try again in a few seconds")
    }

    @MainActor
    private static func keeper() throws -> Keeper {
        guard let keeper = AgentContext.keeper else { throw AgentError.busy("WindowKeeper is still starting. Try again in a moment") }
        return keeper
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// A profile by any unique start of its id, or by its name.
    @MainActor
    private static func find(_ text: String) throws -> MonitorProfile {
        let profiles = try keeper().store.library.profiles
        let key = text.lowercased()
        if let named = profiles.first(where: { $0.name.lowercased() == key }) { return named }
        let matches = profiles.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        guard !matches.isEmpty else { throw AgentError.notFound("no profile with id or name \"\(text)\". Run `windowkeeper profiles list`") }
        guard matches.count == 1 else {
            throw AgentError.usage("\"\(text)\" fits \(matches.count) profiles. Give more of the id. Run `windowkeeper profiles list`")
        }
        return matches[0]
    }

    /// An open app WindowKeeper looks after, by bundle ID or name.
    @MainActor
    private static func openApp(_ text: String) throws -> NSRunningApplication {
        let apps = AXWindows.managedApps()
        let key = text.lowercased()
        if let app = apps.first(where: { $0.bundleIdentifier?.lowercased() == key })
            ?? apps.first(where: { $0.localizedName?.lowercased() == key }) {
            return app
        }
        let names = apps.compactMap(\.localizedName).sorted().prefix(12).joined(separator: ", ")
        throw AgentError.notFound("no open app called \"\(text)\". WindowKeeper saves and restores only apps that are open: \(names)")
    }

    /// Restoring moves the person's real windows: never from a test copy, and only with access.
    @MainActor
    private static func mayMoveWindows() throws {
        if AgentSocket.isTestRun { throw AgentError.invalid("a test copy never moves windows. Leave out --yes to see what would move") }
        guard AXWindows.isTrusted else { throw AgentError.noAccess }
    }

    @MainActor
    private static func setAutoSave(_ on: Bool) throws -> JSONObject {
        let settings = AppSettings.shared
        let changed = settings.autoSave != on
        if changed { settings.autoSave = on }
        return ["autoSave": settings.autoSave, "autoSaveEvery": interval(settings), "changed": changed]
    }

    @MainActor
    private static func interval(_ settings: AppSettings) -> String {
        let value = settings.autoSaveValue
        let unit = settings.autoSaveUnit.rawValue
        return "\(value) \(value == 1 ? String(unit.dropLast()) : unit)"
    }

    private static func cloud(_ state: ProfileStore.CloudState) -> String {
        switch state {
        case .unknown: "not written yet"
        case .synced(let date): "synced \(JSON.date(date))"
        case .unavailable: "iCloud Drive is off: profiles are on this Mac only"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func summary(_ profile: MonitorProfile, current: Bool) -> JSONObject {
        var result: JSONObject = [
            "id": short(profile.id), "name": profile.name, "current": current,
            "monitors": profile.displays.map { $0.isBuiltin ? "Built-in" : $0.name },
            "windows": profile.windows.count, "apps": Set(profile.windows.map(\.bundleID)).count,
            "icons": profile.icons.count, "locked": profile.isLocked,
            "lastSaved": profile.lastSaved.map(JSON.date) ?? NSNull(),
        ]
        if let from = profile.importedFrom { result["importedFrom"] = from }
        return result
    }

    @MainActor
    private static func detail(_ profile: MonitorProfile, current: Bool, app filter: String?) -> JSONObject {
        let liveKeys = Set(DisplayCatalog.current().map(\.key))
        let open = Set(AXWindows.managedApps().compactMap(\.bundleIdentifier))
        let names = Dictionary(profile.displays.map { ($0.key, $0.isBuiltin ? "Built-in" : $0.name) }, uniquingKeysWith: { a, _ in a })
        var windows = profile.windows
        if let filter = filter?.lowercased() {
            windows = windows.filter { $0.bundleID.lowercased() == filter || $0.appName.lowercased() == filter }
        }
        let byApp = Dictionary(grouping: windows, by: \.bundleID)
        var result = summary(profile, current: current)
        result["created"] = JSON.date(profile.created)
        result["signature"] = profile.signature
        result["displays"] = profile.displays.map { display -> JSONObject in
            ["name": display.isBuiltin ? "Built-in" : display.name, "key": display.key, "builtIn": display.isBuiltin,
             "connected": liveKeys.contains(display.key),
             "x": display.bounds.x, "y": display.bounds.y, "width": display.bounds.width, "height": display.bounds.height]
        }
        result["savedApps"] = byApp.keys.sorted { byApp[$0]![0].appName.lowercased() < byApp[$1]![0].appName.lowercased() }.map { id -> JSONObject in
            ["app": byApp[id]![0].appName, "bundleID": id, "open": open.contains(id),
             "windows": byApp[id]!.map { window -> JSONObject in
                 ["title": window.title, "display": names[window.displayKey] ?? window.displayKey,
                  "x": window.offset.x, "y": window.offset.y, "width": window.offset.width, "height": window.offset.height,
                  "saved": JSON.date(window.savedAt)]
             }]
        }
        return result
    }

    /// A page of a list: `--limit` (default 50) and `--offset`, with the total and the next offset.
    private static func page<T>(_ items: [T], _ args: Args, key: String, _ transform: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be above 0 and --offset 0 or more") }
        let slice = items.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(transform), "total": items.count]
        if offset + slice.count < items.count { result["nextOffset"] = offset + slice.count }
        return result
    }
}
