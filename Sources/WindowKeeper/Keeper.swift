import AppKit
import Observation
import WindowKeeperKit

/// Detects the current monitor profile, saves and restores window positions, and runs the
/// automatic triggers.
@Observable
@MainActor
final class Keeper {
    enum Scope {
        case all
        case app(NSRunningApplication)
    }

    let store: ProfileStore
    private(set) var currentProfileID: UUID?
    /// One line about the last thing done, for the menu.
    private(set) var lastActivity: String?
    private(set) var isTrusted = AXWindows.isTrusted
    /// Where everything was just before the last restore, for Undo Last Restore.
    private(set) var undoSnapshot: MonitorProfile?

    var currentProfile: MonitorProfile? { store.profile(id: currentProfileID) }

    /// A monitor set never seen before became a new profile.
    @ObservationIgnored var onNewProfile: ((MonitorProfile) -> Void)?

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private var tracker = SettleTracker()
    @ObservationIgnored private var settleTimer: Timer?
    @ObservationIgnored private var lastDisplayChange = Date()
    @ObservationIgnored private var autoSaveTimer: Timer?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var launchRestores: [AppLaunchRestore] = []
    @ObservationIgnored private var hasSettledOnce = false
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    /// After monitors change, automatic saves wait this long: macOS can still be moving
    /// windows back for a while after the last display event.
    private let quietPeriod: TimeInterval = 60

    init(store: ProfileStore) {
        self.store = store
    }

    func start() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (Notification) -> Void) {
            tokens.append(c.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue, as asked for above.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { action(note) }
            })
        }
        on(center, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.displaysChanged("screen parameters") }
        on(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.displaysChanged("wake") }
        on(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.displaysChanged("screens woke") }
        // Last chance to record the layout while every monitor is still attached: displays
        // going to sleep often disconnect, and macOS starts moving windows at once.
        on(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.autoSave(reason: "displays sleeping") }
        on(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.autoSave(reason: "going to sleep") }
        on(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appLaunched(app)
        }
        on(workspace, NSWorkspace.didMountNotification) { [weak self] note in
            guard let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String else { return }
            self?.volumeMounted(name)
        }

        Diagnostics.note(AXWindows.probe())
        settings.onScheduleChange = { [weak self] in self?.scheduleAutoSave() }
        scheduleAutoSave()
        watchTrust()
        displaysChanged("launch")

        store.recoverFromCloudIfEmpty { [weak self] in
            guard let self else { return }
            self.hasSettledOnce = false
            self.tracker = SettleTracker()
            self.displaysChanged("recovered from iCloud")
        }
    }

    // MARK: - Monitor profiles

    private func displaysChanged(_ reason: String) {
        lastDisplayChange = Date()
        tracker.reset()
        settleTimer?.invalidate()
        sampleDisplays()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleDisplays() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
        Diagnostics.note("displays changed (\(reason)); waiting for them to settle")
    }

    private func sampleDisplays() {
        let live = DisplayCatalog.current()
        let signature = ProfileSignature.make(live.map(\.key))
        guard case let .settled(_, changed, disrupted)? = tracker.sample(signature) else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        lastDisplayChange = Date()
        settled(live: live, signature: signature, changed: changed, disrupted: disrupted)
    }

    private func settled(live: [LiveDisplay], signature: String, changed: Bool, disrupted: Bool) {
        let isFirst = !hasSettledOnce
        hasSettledOnce = true

        let profile: MonitorProfile
        var isNew = false
        if var existing = store.library.profile(withSignature: signature) {
            // Keep the arrangement current: it is what maps windows when this profile is
            // restored on a different desk.
            existing.displays = live.map(\.record)
            store.update(existing)
            profile = existing
        } else {
            let records = live.map(\.record)
            profile = MonitorProfile(name: store.library.uniqueName(ProfileSignature.defaultName(for: records)),
                                     signature: signature, displays: records)
            store.add(profile)
            isNew = true
        }
        currentProfileID = profile.id
        Diagnostics.note("settled on \"\(profile.name)\" [\(signature)] changed=\(changed) disrupted=\(disrupted) new=\(isNew)")

        if isFirst, settings.rememberDesktopIcons, FinderDesktop.access == .unknown {
            // Ask Finder once now, so a first-run permission prompt appears at launch rather
            // than minutes later from the first auto-save.
            Task { _ = await FinderDesktop.read(timeout: 120) }
        }

        if isNew {
            // The very first profile is just this Mac's setup, not a new desk worth announcing.
            if store.library.profiles.count > 1 { onNewProfile?(profile) }
            return
        }
        if isFirst {
            if settings.restoreOnLaunch { restore(.all, from: profile, reason: "WindowKeeper opened", waitForFinder: true) }
        } else if (changed || disrupted), settings.restoreOnProfileDetected, profile.hasExternalDisplay {
            restore(.all, from: profile, reason: changed ? "monitors connected" : "monitors reconnected", waitForFinder: true)
        }
    }

    // MARK: - Saving

    /// Saves windows, and for `.all` the desktop icons too. Returns the number of windows
    /// captured. Icons are read from Finder asynchronously and saved when the answer arrives.
    @discardableResult
    func save(_ scope: Scope, automatic: Bool = false) -> Int? {
        guard checkTrust(), var profile = currentProfile else { return nil }
        if automatic, !AutoSavePolicy.mayWrite(to: profile) { return nil }
        let live = DisplayCatalog.current()
        let now = Date()
        let (captured, replacing) = captureWindows(apps(in: scope), live: live, at: now)

        if automatic, SnapshotCheck.looksDisplaced(captured: captured, previous: profile.windows, connectedDisplays: live.count) {
            Diagnostics.note("auto-save skipped: every window is on one display, which looks like macOS moved them")
            return nil
        }

        let merged = SnapshotMerge.merge(existing: profile.windows, captured: captured, replacing: replacing)
        let changed = merged != profile.windows
        if changed {
            profile.windows = merged
            profile.lastSaved = now
            profile.displays = live.map(\.record)
            store.update(profile)
        }
        let what: String
        if case let .app(app) = scope { what = "\(captured.count) \(app.localizedName ?? "app") window(s)" } else { what = "\(captured.count) window(s)" }
        // A quiet auto-save that changed nothing leaves the last real activity showing.
        if !automatic || changed {
            lastActivity = "\(automatic ? "Auto-saved" : "Saved") \(what) · \(now.formatted(date: .omitted, time: .shortened))"
        }
        if !automatic { Diagnostics.note("saved \(what) to \"\(profile.name)\"") }
        if case .all = scope, settings.rememberDesktopIcons {
            saveIcons(profileID: profile.id, automatic: automatic)
        }
        return captured.count
    }

    /// Every saveable window of `apps`, positioned relative to its display, plus the bundle
    /// IDs that had at least one (those apps' saved entries get replaced).
    private func captureWindows(_ apps: [NSRunningApplication], live: [LiveDisplay], at now: Date) -> ([SavedWindow], Set<String>) {
        var captured: [SavedWindow] = []
        var replacing = Set<String>()
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let windows = AXWindows.windows(of: app.processIdentifier).filter(\.isSaveable)
            guard !windows.isEmpty else { continue }
            replacing.insert(bundleID)
            for window in windows {
                guard let display = Placement.display(for: window.frame, among: live) else { continue }
                captured.append(SavedWindow(
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    title: window.title,
                    displayKey: display.key,
                    offset: Frame(x: window.frame.minX - display.bounds.minX, y: window.frame.minY - display.bounds.minY,
                                  width: window.frame.width, height: window.frame.height),
                    savedAt: now
                ))
            }
        }
        return (captured, replacing)
    }

    // MARK: - Desktop icons

    private func saveIcons(profileID: UUID, automatic: Bool) {
        Task {
            guard let icons = await FinderDesktop.read() else { return }
            guard var profile = store.profile(id: profileID), !automatic || AutoSavePolicy.mayWrite(to: profile) else { return }
            let live = DisplayCatalog.current()
            let captured = Self.savedIcons(icons, live: live, at: Date())
            if automatic, SnapshotCheck.looksDisplaced(captured: captured, previous: profile.icons, connectedDisplays: live.count) {
                Diagnostics.note("icon auto-save skipped: every icon is on one display, which looks like Finder moved them")
                return
            }
            let merged = IconMerge.merge(existing: profile.icons, captured: captured)
            guard merged != profile.icons else { return }
            profile.icons = merged
            profile.lastSaved = Date()
            store.update(profile)
            if !automatic { Diagnostics.note("saved \(captured.count) desktop icon(s) to \"\(profile.name)\"") }
        }
    }

    private static func savedIcons(_ icons: [DesktopIcon], live: [LiveDisplay], at now: Date) -> [SavedIcon] {
        icons.compactMap { icon in
            guard let display = Placement.display(for: CGRect(origin: icon.position, size: CGSize(width: 1, height: 1)), among: live) else { return nil }
            return SavedIcon(name: icon.name, kind: icon.kind, fileID: icon.fileID, displayKey: display.key,
                             x: icon.position.x - display.bounds.minX, y: icon.position.y - display.bounds.minY, savedAt: now)
        }
    }

    /// Moves desktop icons to where `profile` has them.
    ///
    /// - `waitForFinder`: after monitors change, Finder reflows the desktop itself for a few
    ///   seconds; placing icons before it finishes just gets them shuffled again. So first
    ///   wait until two reads a second apart agree (at most 10 s). One more pass follows 6 s
    ///   later for anything Finder moved after that, unless a mouse button is down — then the
    ///   user may be dragging, and their move wins.
    func restoreIcons(from profile: MonitorProfile, waitForFinder: Bool = false, recordUndo: Bool = true) {
        guard settings.rememberDesktopIcons, !profile.icons.isEmpty else { return }
        Task {
            guard var current = await FinderDesktop.read() else { return }
            if waitForFinder {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let next = await FinderDesktop.read() else { return }
                    let settled = next.map(\.position) == current.map(\.position)
                    current = next
                    if settled { break }
                }
            }
            if recordUndo, undoSnapshot != nil {
                undoSnapshot?.icons = Self.savedIcons(current, live: DisplayCatalog.current(), at: Date())
            }
            let moves = iconMoves(for: profile, current: current)
            let placed = await FinderDesktop.place(moves) ?? 0
            Diagnostics.note("icons: placed \(placed) of \(moves.count) that needed moving (\(profile.icons.count) saved)")
            guard waitForFinder, placed > 0 else { return }

            // Where Finder actually put them (Snap to Grid rounds), to tell its later moves apart.
            guard let landed = await FinderDesktop.read() else { return }
            try? await Task.sleep(for: .seconds(6))
            guard NSEvent.pressedMouseButtons == 0, let later = await FinderDesktop.read() else { return }
            let landedAt = Dictionary(landed.map { ($0.name, $0.position) }, uniquingKeysWith: { a, _ in a })
            let movedNames = Set(later.filter { icon in landedAt[icon.name].map { $0 != icon.position } ?? false }.map(\.name))
            let again = iconMoves(for: profile, current: later).filter { movedNames.contains($0.name) }
            if !again.isEmpty {
                let replaced = await FinderDesktop.place(again) ?? 0
                Diagnostics.note("icons: Finder moved \(again.count) after the restore; put \(replaced) back")
            }
        }
    }

    /// Icons that are not where `profile` wants them, paired with their target. Matched by
    /// file identifier first, so an icon renamed since the save is still found, then by name.
    private func iconMoves(for profile: MonitorProfile, current: [DesktopIcon]) -> [(name: String, point: CGPoint)] {
        let live = DisplayCatalog.current()
        var moves: [(name: String, point: CGPoint)] = []
        for saved in profile.icons {
            let match = current.first { saved.fileID != nil && $0.fileID == saved.fileID }
                ?? current.first { $0.name == saved.name && $0.kind == saved.kind }
            guard let match, let target = Placement.point(for: saved, savedDisplays: profile.displays, live: live) else { continue }
            if abs(match.position.x - target.x) > 2 || abs(match.position.y - target.y) > 2 {
                moves.append((match.name, target))
            }
        }
        return moves
    }

    /// A disk or server just mounted: Finder shows its icon wherever it likes, so put it back.
    private func volumeMounted(_ name: String) {
        guard settings.rememberDesktopIcons, hasSettledOnce, let profile = currentProfile,
              let saved = profile.icons.first(where: { $0.kind == .volume && $0.name == name }),
              let target = Placement.point(for: saved, savedDisplays: profile.displays, live: DisplayCatalog.current())
        else { return }
        Task {
            // Finder needs a moment to put the new icon on the desktop.
            try? await Task.sleep(for: .seconds(1.5))
            let placed = await FinderDesktop.place([(name, target)]) ?? 0
            Diagnostics.note("volume mounted: \(placed == 1 ? "put its icon back" : "could not place its icon")")
        }
    }

    private func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        guard settings.autoSave else { return }
        let timer = Timer(timeInterval: settings.autoSaveSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoSave(reason: "interval") }
        }
        timer.tolerance = min(5, settings.autoSaveSeconds * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        autoSaveTimer = timer
    }

    /// Automatic saves only run when the snapshot can be trusted: monitors settled and
    /// quiet, no restore in progress, screen unlocked.
    private func autoSave(reason: String) {
        guard settings.autoSave, isTrusted, let profile = currentProfile, AutoSavePolicy.mayWrite(to: profile), !tracker.isSettling,
              Date().timeIntervalSince(lastDisplayChange) >= quietPeriod,
              launchRestores.isEmpty, !Self.screenIsLocked
        else { return }
        save(.all, automatic: true)
    }

    /// Debug hook: the automatic save, ignoring the timer and quiet period but keeping the
    /// lock and pile-up guards — the parts worth testing.
    func debugAutoSave() {
        guard let profile = currentProfile else { return }
        guard AutoSavePolicy.mayWrite(to: profile) else { return Diagnostics.note("debug: auto-save refused, profile is locked") }
        save(.all, automatic: true)
        Diagnostics.note("debug: auto-save ran")
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Restoring

    /// Restores windows, and for `.all` the desktop icons as well.
    /// - `waitForFinder`: for automatic restores after monitors change; see `restoreIcons`.
    /// - `recordUndo`: off only when undoing, so Undo itself can't be undone into a loop.
    @discardableResult
    func restore(_ scope: Scope, from profile: MonitorProfile? = nil, reason: String = "menu",
                 waitForFinder: Bool = false, recordUndo: Bool = true) -> Int? {
        guard checkTrust(), let profile = profile ?? currentProfile else { return nil }
        RestoreSession.finishAll()
        let live = DisplayCatalog.current()
        let targetApps = apps(in: scope)

        if recordUndo {
            let (windows, _) = captureWindows(targetApps, live: live, at: Date())
            undoSnapshot = MonitorProfile(name: "Before last restore", signature: "undo", displays: live.map(\.record), windows: windows)
        }

        let session = RestoreSession(duration: 20)
        var placed = 0
        var missed = 0
        for app in targetApps {
            let saved = profile.windows.filter { $0.bundleID == app.bundleIdentifier }
            guard !saved.isEmpty else { continue }
            let windows = AXWindows.windows(of: app.processIdentifier).filter(\.isPlaceable)
            let pairs = WindowMatcher.match(live: windows.map { LiveWindowInfo(title: $0.title, size: $0.frame.size) }, saved: saved)
            for pair in pairs {
                guard let target = Placement.target(for: saved[pair.saved], savedDisplays: profile.displays, live: live) else { continue }
                if session.place(windows[pair.live].element, pid: app.processIdentifier, target: target) { placed += 1 } else { missed += 1 }
            }
        }
        if case .all = scope { restoreIcons(from: profile, waitForFinder: waitForFinder, recordUndo: recordUndo) }

        let from = profile.id == currentProfileID ? "" : " from \(profile.name)"
        lastActivity = "Restored \(placed) window(s)\(from) · \(Date().formatted(date: .omitted, time: .shortened))"
        Diagnostics.note("restore (\(reason)) from \"\(profile.name)\": placed \(placed), refused \(missed)")
        return placed
    }

    /// Puts windows (and icons) back where they were just before the last restore.
    func undoLastRestore() {
        guard let snapshot = undoSnapshot else { return }
        undoSnapshot = nil
        restore(.all, from: snapshot, reason: "undo", recordUndo: false)
        lastActivity = "Undid the last restore · \(Date().formatted(date: .omitted, time: .shortened))"
    }

    /// Restores only the desktop icons, from the menu.
    func restoreIconsOnly() {
        guard let profile = currentProfile else { return }
        undoSnapshot = MonitorProfile(name: "Before last restore", signature: "undo", displays: DisplayCatalog.current().map(\.record))
        restoreIcons(from: profile)
        lastActivity = "Restored desktop icons · \(Date().formatted(date: .omitted, time: .shortened))"
    }

    func setLocked(_ locked: Bool, profileID: UUID) {
        guard var profile = store.profile(id: profileID) else { return }
        profile.isLocked = locked
        store.update(profile)
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard settings.restoreOnAppRelaunch, isTrusted, hasSettledOnce,
              let bundleID = app.bundleIdentifier, let profile = currentProfile,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let saved = profile.windows.filter { $0.bundleID == bundleID }
        guard !saved.isEmpty else { return }
        launchRestores.removeAll { $0.pid == app.processIdentifier }
        let restore = AppLaunchRestore(app: app, saved: saved, savedDisplays: profile.displays)
        restore.onFinish = { [weak self] finished in self?.launchRestores.removeAll { $0 === finished } }
        launchRestores.append(restore)
    }

    // MARK: - Helpers

    private func apps(in scope: Scope) -> [NSRunningApplication] {
        switch scope {
        case .all: AXWindows.managedApps()
        case .app(let app): [app]
        }
    }

    private func checkTrust() -> Bool {
        isTrusted = AXWindows.isTrusted
        if !isTrusted {
            lastActivity = "Needs Accessibility access"
            watchTrust()
        }
        return isTrusted
    }

    /// The permission is granted in System Settings, outside the app, with no notification.
    /// Poll while it is missing so the menu and auto-save notice as soon as it is given.
    private func watchTrust() {
        isTrusted = AXWindows.isTrusted
        guard !isTrusted, trustTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrusted = AXWindows.isTrusted
                if self.isTrusted {
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.lastActivity = nil
                    Diagnostics.note("Accessibility access granted")
                    Diagnostics.note(AXWindows.probe())
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }
}
