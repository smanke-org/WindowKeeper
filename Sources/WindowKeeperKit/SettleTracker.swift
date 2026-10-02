import Foundation

/// Decides when the set of connected monitors has stopped changing.
///
/// Waking or docking reconnects monitors one at a time, passing through partial sets for a
/// few seconds. Desktop Bins Widget recorded a layout for every one of those transient sets
/// and its bins drifted. Here a set only counts once two consecutive samples agree, and
/// nothing is created or restored for the sets passed through on the way.
public struct SettleTracker: Sendable {
    public enum Event: Equatable, Sendable {
        /// The monitor set is stable.
        /// - `changed`: it differs from the last stable set (or is the first one seen).
        /// - `disrupted`: monitors came and went on the way here, even if the final set is
        ///   the one we started with — after sleep, macOS has likely moved windows around.
        case settled(signature: String, changed: Bool, disrupted: Bool)
    }

    public private(set) var lastSettled: String?
    private var pending: String?
    private var sawOtherSet = false

    public init() {}

    /// True while a change is being waited out.
    public var isSettling: Bool { pending != nil }

    /// Feed one sample. Returns an event once the same set has been seen twice in a row.
    public mutating func sample(_ signature: String) -> Event? {
        if signature != lastSettled { sawOtherSet = true }
        guard pending == signature else {
            pending = signature
            return nil
        }
        let event = Event.settled(signature: signature, changed: signature != lastSettled, disrupted: sawOtherSet)
        lastSettled = signature
        pending = nil
        sawOtherSet = false
        return event
    }

    /// A change notification arrived: the next sample starts a fresh wait.
    public mutating func reset() {
        pending = nil
    }
}
