import AppKit
import WindowKeeperKit

/// Places an app's windows as they open, for a short while after the app launches.
///
/// Apps open their windows one at a time, some only seconds after launch, so a single pass
/// at launch would miss most of them. Each new window is matched against the saved entries
/// not yet used and handed to a `RestoreSession`, which also stops touching it the moment
/// the user drags it.
@MainActor
final class AppLaunchRestore {
    let pid: pid_t
    private let bundleID: String
    private var remaining: [SavedWindow]
    private let savedDisplays: [DisplayRecord]
    private let session: RestoreSession
    private var seen: [AXUIElement] = []
    private var waiting: [AXUIElement] = []
    private var timer: Timer?
    private var placed = 0
    var onFinish: ((AppLaunchRestore) -> Void)?

    init(app: NSRunningApplication, saved: [SavedWindow], savedDisplays: [DisplayRecord], watchFor duration: TimeInterval = 15) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier ?? ""
        remaining = saved
        self.savedDisplays = savedDisplays
        session = RestoreSession(duration: duration + 5)

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.stop() }
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        Diagnostics.note("\(bundleID) launched: placed \(placed) window(s)")
        onFinish?(self)
    }

    private func poll() {
        let windows = AXWindows.windows(of: pid).filter(\.isPlaceable)
        // A window is matched on the poll after it first appears, by which time its title
        // has usually been set — a window is often created untitled and named a moment later.
        let ready = windows.filter { w in waiting.contains { CFEqual($0, w.element) } }
        waiting = windows.filter { w in !seen.contains { CFEqual($0, w.element) } }.map(\.element)
        seen += waiting

        guard !ready.isEmpty, !remaining.isEmpty else { return }
        let live = DisplayCatalog.current()
        let pairs = WindowMatcher.match(live: ready.map { LiveWindowInfo(title: $0.title, size: $0.frame.size) }, saved: remaining)
        for pair in pairs {
            guard let target = Placement.target(for: remaining[pair.saved], savedDisplays: savedDisplays, live: live) else { continue }
            if session.place(ready[pair.live].element, pid: pid, target: target) { placed += 1 }
        }
        let used = Set(pairs.map(\.saved))
        remaining = remaining.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        if remaining.isEmpty { stop() }
    }
}
