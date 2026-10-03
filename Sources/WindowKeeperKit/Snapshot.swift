import Foundation

/// Folding a fresh capture into what a profile already holds.
public enum SnapshotMerge {
    /// Replaces the saved windows of every app in `replacing`, and keeps everything else.
    ///
    /// Apps that are not running, or running with no windows open, keep their entries:
    /// quitting an app must not erase where its windows go. Entries whose place has not
    /// changed keep their old `savedAt`, so an unchanged snapshot is byte-identical and
    /// nothing gets rewritten or re-synced.
    public static func merge(existing: [SavedWindow], captured: [SavedWindow], replacing apps: Set<String>) -> [SavedWindow] {
        var previous = existing.filter { apps.contains($0.bundleID) }
        var fresh: [SavedWindow] = []
        for var window in captured where apps.contains(window.bundleID) {
            if let i = previous.firstIndex(where: { $0.samePlace(as: window) }) {
                window.savedAt = previous[i].savedAt
                previous.remove(at: i)
            }
            fresh.append(window)
        }
        let kept = existing.filter { !apps.contains($0.bundleID) }
        return (kept + fresh).sorted { ($0.bundleID, $0.title, $0.displayKey) < ($1.bundleID, $1.title, $1.displayKey) }
    }
}

/// Folding a fresh read of the desktop into what a profile holds.
public enum IconMerge {
    /// The desktop is read whole, so the capture replaces the saved set — except volumes
    /// that are not mounted right now, which keep their spot for when they come back.
    /// Unchanged entries keep their `savedAt`, as with windows.
    public static func merge(existing: [SavedIcon], captured: [SavedIcon]) -> [SavedIcon] {
        var previous = existing
        var fresh: [SavedIcon] = []
        for var icon in captured {
            if let i = previous.firstIndex(where: { $0.samePlace(as: icon) }) {
                icon.savedAt = previous[i].savedAt
                previous.remove(at: i)
            }
            fresh.append(icon)
        }
        let capturedVolumes = Set(captured.filter { $0.kind == .volume }.map(\.name))
        let absentVolumes = existing.filter { $0.kind == .volume && !capturedVolumes.contains($0.name) }
        return (fresh + absentVolumes).sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }
}

/// Catches snapshots taken while macOS has piled windows onto one display.
///
/// After sleep, monitors reconnect one at a time and macOS moves windows off whichever are
/// briefly missing. An automatic save at that moment would record the pile-up as the
/// layout. Desktop Bins Widget lost bin positions this way twice.
public enum SnapshotCheck {
    public static func looksDisplaced(captured: [SavedWindow], previous: [SavedWindow], connectedDisplays: Int) -> Bool {
        looksDisplaced(captured: captured.map(\.displayKey), previous: previous.map(\.displayKey), connectedDisplays: connectedDisplays)
    }

    /// The icon version looks for Finder's evacuation pattern instead: when a display goes
    /// away, *every* icon on it lands on one other display. Desktops are lopsided (most icons
    /// usually sit on one screen), so the window rule would flag a user dragging their only
    /// icon from a side screen — here one moved icon never counts, and a display that still
    /// has some of its icons was not evacuated.
    public static func looksDisplaced(captured: [SavedIcon], previous: [SavedIcon], connectedDisplays: Int) -> Bool {
        guard connectedDisplays >= 2 else { return false }
        let now = Dictionary(captured.map { ($0.name, $0.displayKey) }, uniquingKeysWith: { a, _ in a })
        let moved = previous.filter { old in now[old.name].map { $0 != old.displayKey } ?? false }
        guard moved.count >= 2, Set(moved.compactMap { now[$0.name] }).count == 1 else { return false }
        let sources = Set(moved.map(\.displayKey))
        let stayed = previous.filter { sources.contains($0.displayKey) && now[$0.name] == $0.displayKey }
        return stayed.isEmpty
    }

    /// Takes the display key of each thing captured and each thing previously saved.
    public static func looksDisplaced(captured: [String], previous: [String], connectedDisplays: Int) -> Bool {
        guard connectedDisplays >= 2, captured.count >= 3, previous.count >= 3 else { return false }
        return Set(previous).count >= 2 && Set(captured).count == 1
    }
}

/// The auto-save interval, as the user enters it.
public enum IntervalUnit: String, Codable, CaseIterable, Sendable {
    case seconds, minutes, hours

    public var seconds: TimeInterval {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        }
    }
}

/// Whether an automatic save may write to a profile.
public enum AutoSavePolicy {
    public static func mayWrite(to profile: MonitorProfile) -> Bool { !profile.isLocked }
}

public enum SaveInterval {
    /// Below this, auto-save would be hammering every app's Accessibility interface.
    public static let minimumSeconds: TimeInterval = 10

    public static func seconds(value: Int, unit: IntervalUnit) -> TimeInterval {
        max(minimumSeconds, TimeInterval(max(1, value)) * unit.seconds)
    }
}
