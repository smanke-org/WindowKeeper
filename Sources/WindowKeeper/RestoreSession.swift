import AppKit
import ApplicationServices

/// Puts windows where they belong, then keeps them there for a short while.
///
/// Apps and macOS both move windows after we do. An app restoring its own state, or macOS
/// re-placing windows once a monitor finishes reconnecting, can land seconds after our
/// move — Desktop Bins Widget 1.1.16 lost bins exactly that way. So each placed window is
/// watched for `duration`: a move nobody asked for is undone (at most `maxReapplies`
/// times), but a move made while a mouse button is down is the user dragging, and from
/// then on that window is theirs.
@MainActor
final class RestoreSession {
    private final class Entry {
        let element: AXUIElement
        let target: CGRect
        var reapplied = 0
        var released = false
        var pending: DispatchWorkItem?

        init(element: AXUIElement, target: CGRect) {
            self.element = element
            self.target = target
        }
    }

    /// Sessions keep themselves alive until they finish: their observers hold an unretained
    /// pointer back to them, so one must never be freed while still registered.
    private static var running: [RestoreSession] = []

    /// Ends every session, before a new restore sets different targets.
    static func finishAll() {
        for session in running { session.finish() }
    }

    private var entries: [Entry] = []
    private var observers: [pid_t: AXObserver] = [:]
    private let maxReapplies = 2
    private(set) var isFinished = false
    var onFinish: ((RestoreSession) -> Void)?

    init(duration: TimeInterval) {
        Self.running.append(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.finish() }
    }

    /// Moves the window and starts guarding it. Returns whether the move was accepted.
    @discardableResult
    func place(_ element: AXUIElement, pid: pid_t, target: CGRect) -> Bool {
        guard !isFinished else { return false }
        let ok = AXWindows.setFrame(element, target)
        guard ok else { return false }
        entries.append(Entry(element: element, target: target))
        watch(element, pid: pid)
        return true
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        for entry in entries { entry.pending?.cancel() }
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        entries.removeAll()
        Self.running.removeAll { $0 === self }
        onFinish?(self)
    }

    // MARK: - Watching

    private func watch(_ element: AXUIElement, pid: pid_t) {
        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            var created: AXObserver?
            guard AXObserverCreate(pid, restoreSessionCallback, &created) == .success, let created else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observers[pid] = created
            observer = created
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, element, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXResizedNotification as CFString, refcon)
    }

    fileprivate func windowChanged(_ element: AXUIElement) {
        guard !isFinished, let entry = entries.first(where: { CFEqual($0.element, element) }), !entry.released else { return }
        guard let frame = AXWindows.frame(of: element), !Self.close(frame, entry.target) else { return }

        if NSEvent.pressedMouseButtons != 0 {
            entry.released = true
            entry.pending?.cancel()
            return
        }
        guard entry.reapplied < maxReapplies else {
            entry.released = true
            return
        }
        // Debounced: an app settling its layout sends a burst of moves.
        entry.pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry, !self.isFinished, !entry.released, NSEvent.pressedMouseButtons == 0,
                  let now = AXWindows.frame(of: entry.element), !Self.close(now, entry.target)
            else { return }
            entry.reapplied += 1
            Diagnostics.note("window moved after restore (\(Self.describe(now))); putting it back at \(Self.describe(entry.target))")
            AXWindows.setFrame(entry.element, entry.target)
        }
        entry.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Apps round frames to whole points and some snap sizes to a grid (Terminal's
    /// character cells), so "where we put it" is not an exact comparison.
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 24 && abs(a.height - b.height) <= 24
    }

    static func describe(_ r: CGRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }
}

/// AXObserver callbacks arrive on the main run loop, where the observers were added.
private func restoreSessionCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let session = Unmanaged<RestoreSession>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated {
        session.windowChanged(element)
    }
}
