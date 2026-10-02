import CoreGraphics
import Foundation

/// A rectangle in global screen coordinates with a top-left origin — the space the
/// Accessibility API and `CGDisplayBounds` use. Stored as named fields rather than
/// `CGRect`'s nested arrays so the saved JSON is readable.
public struct Frame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A monitor as it was when a profile last saw it.
public struct DisplayRecord: Codable, Hashable, Sendable {
    /// Stable identity, from the monitor's serial number where it has a real one. See `DisplayKey`.
    public var key: String
    public var name: String
    public var isBuiltin: Bool
    /// Where it sat in the arrangement, in global top-left coordinates.
    public var bounds: Frame

    public init(key: String, name: String, isBuiltin: Bool, bounds: Frame) {
        self.key = key
        self.name = name
        self.isBuiltin = isBuiltin
        self.bounds = bounds
    }
}

/// A monitor that is connected right now.
public struct LiveDisplay: Hashable, Sendable {
    public var key: String
    public var name: String
    public var isBuiltin: Bool
    public var isMain: Bool
    /// Whole display, global top-left coordinates.
    public var bounds: CGRect
    /// The part windows may use — below the menu bar, clear of the Dock.
    public var visible: CGRect

    public init(key: String, name: String, isBuiltin: Bool, isMain: Bool, bounds: CGRect, visible: CGRect) {
        self.key = key
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.bounds = bounds
        self.visible = visible
    }

    public var record: DisplayRecord {
        DisplayRecord(key: key, name: name, isBuiltin: isBuiltin, bounds: Frame(bounds))
    }
}

/// One window's saved place.
///
/// The position is stored relative to the monitor it was on, so rearranging monitors in
/// System Settings, or the menu bar moving, does not invalidate it.
public struct SavedWindow: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var displayKey: String
    /// Offset from the display's top-left corner; width and height are the window's size.
    public var offset: Frame
    /// When this entry last *changed* — not when it was last checked — so an unchanged
    /// snapshot encodes identically and nothing is rewritten or re-synced.
    public var savedAt: Date

    public init(bundleID: String, appName: String, title: String, displayKey: String, offset: Frame, savedAt: Date) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.displayKey = displayKey
        self.offset = offset
        self.savedAt = savedAt
    }

    /// Same place, ignoring when it was recorded.
    public func samePlace(as other: SavedWindow) -> Bool {
        bundleID == other.bundleID && title == other.title && displayKey == other.displayKey && offset == other.offset
    }
}

/// The saved window layout for one set of monitors — in practice, one desk.
public struct MonitorProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The set of display keys this profile belongs to. See `ProfileSignature`.
    public var signature: String
    public var displays: [DisplayRecord]
    public var windows: [SavedWindow]
    public var created: Date
    /// Last time a save changed something.
    public var lastSaved: Date?
    /// Set when the profile is copied from another Mac, for display only.
    public var importedFrom: String?

    public init(id: UUID = UUID(), name: String, signature: String, displays: [DisplayRecord],
                windows: [SavedWindow] = [], created: Date = Date(), lastSaved: Date? = nil, importedFrom: String? = nil) {
        self.id = id
        self.name = name
        self.signature = signature
        self.displays = displays
        self.windows = windows
        self.created = created
        self.lastSaved = lastSaved
        self.importedFrom = importedFrom
    }

    public var hasExternalDisplay: Bool { displays.contains { !$0.isBuiltin } }
}

/// Everything one Mac has saved. One of these per Mac, in that Mac's own iCloud folder.
public struct ProfileLibrary: Codable, Sendable {
    public var formatVersion: Int
    public var machineID: String
    public var machineName: String
    public var profiles: [MonitorProfile]

    public init(machineID: String, machineName: String, profiles: [MonitorProfile] = []) {
        self.formatVersion = 1
        self.machineID = machineID
        self.machineName = machineName
        self.profiles = profiles
    }

    public func profile(withSignature signature: String) -> MonitorProfile? {
        profiles.first { $0.signature == signature }
    }

    /// "Base", or "Base (2)" and up when a profile already has that name — two desks with
    /// the same monitor models would otherwise produce identical names.
    public func uniqueName(_ base: String) -> String {
        let taken = Set(profiles.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }
}

public enum ProfileSignature {
    /// Order-independent: the same monitors are the same desk however they are arranged.
    public static func make(_ keys: [String]) -> String {
        keys.sorted().joined(separator: "|")
    }

    /// The default name for a new profile, from its monitors' names.
    public static func defaultName(for displays: [DisplayRecord]) -> String {
        let ordered = displays.sorted { ($0.bounds.x, $0.bounds.y) < ($1.bounds.x, $1.bounds.y) }
        let names = ordered.map { $0.isBuiltin ? "Built-in" : $0.name }
        return names.isEmpty ? "No Displays" : names.joined(separator: " + ")
    }
}
