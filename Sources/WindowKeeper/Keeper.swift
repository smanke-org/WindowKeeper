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

        if isNew {
            // The very first profile is just this Mac's setup, not a new desk worth announcing.
            if store.library.profiles.count > 1 { onNewProfile?(profile) }
            return
        }
        if isFirst {
            if settings.restoreOnLaunch { restore(.all, from: profile, reason: "WindowKeeper opened") }
        } else if (changed || disrupted), settings.restoreOnProfileDetected, profile.hasExternalDisplay {
            restore(.all, from: profile, reason: changed ? "monitors connected" : "monitors reconnected")
        }
    }

    // MARK: - Saving

    @discardableResult
    func save(_ scope: Scope, automatic: Bool = false) -> Int? {
        guard checkTrust(), var profile = currentProfile else { return nil }
        let live = DisplayCatalog.current()
        let now = Date()
        var captured: [SavedWindow] = []
        var replacing = Set<String>()

        for app in apps(in: scope) {
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
        return captured.count
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
        guard settings.autoSave, isTrusted, currentProfile != nil, !tracker.isSettling,
              Date().timeIntervalSince(lastDisplayChange) >= quietPeriod,
              launchRestores.isEmpty, !Self.screenIsLocked
        else { return }
        save(.all, automatic: true)
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Restoring

    @discardableResult
    func restore(_ scope: Scope, from profile: MonitorProfile? = nil, reason: String = "menu") -> Int? {
        guard checkTrust(), let profile = profile ?? currentProfile else { return nil }
        RestoreSession.finishAll()
        let live = DisplayCatalog.current()
        let session = RestoreSession(duration: 20)
        var placed = 0
        var missed = 0

        for app in apps(in: scope) {
            let saved = profile.windows.filter { $0.bundleID == app.bundleIdentifier }
            guard !saved.isEmpty else { continue }
            let windows = AXWindows.windows(of: app.processIdentifier).filter(\.isPlaceable)
            let pairs = WindowMatcher.match(live: windows.map { LiveWindowInfo(title: $0.title, size: $0.frame.size) }, saved: saved)
            for pair in pairs {
                guard let target = Placement.target(for: saved[pair.saved], savedDisplays: profile.displays, live: live) else { continue }
                if session.place(windows[pair.live].element, pid: app.processIdentifier, target: target) { placed += 1 } else { missed += 1 }
            }
        }
        let from = profile.id == currentProfileID ? "" : " from \(profile.name)"
        lastActivity = "Restored \(placed) window(s)\(from) · \(Date().formatted(date: .omitted, time: .shortened))"
        Diagnostics.note("restore (\(reason)) from \"\(profile.name)\": placed \(placed), refused \(missed)")
        return placed
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
