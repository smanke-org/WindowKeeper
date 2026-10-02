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

/// Catches snapshots taken while macOS has piled windows onto one display.
///
/// After sleep, monitors reconnect one at a time and macOS moves windows off whichever are
/// briefly missing. An automatic save at that moment would record the pile-up as the
/// layout. Desktop Bins Widget lost bin positions this way twice.
public enum SnapshotCheck {
    public static func looksDisplaced(captured: [SavedWindow], previous: [SavedWindow], connectedDisplays: Int) -> Bool {
        guard connectedDisplays >= 2, captured.count >= 3, previous.count >= 3 else { return false }
        let before = Set(previous.map(\.displayKey))
        let now = Set(captured.map(\.displayKey))
        return before.count >= 2 && now.count == 1
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

public enum SaveInterval {
    /// Below this, auto-save would be hammering every app's Accessibility interface.
    public static let minimumSeconds: TimeInterval = 10

    public static func seconds(value: Int, unit: IntervalUnit) -> TimeInterval {
        max(minimumSeconds, TimeInterval(max(1, value)) * unit.seconds)
    }
}
