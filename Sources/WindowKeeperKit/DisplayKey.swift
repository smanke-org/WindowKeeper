import Foundation

/// Turns what a monitor reports about itself into a stable identity.
///
/// Two monitors of the same model must not collide, so the serial number is the backbone —
/// but the numeric serial in a monitor's EDID is often junk. An HP E273q on the test desk
/// reports 16843009 (0x01010101) while its alphanumeric serial, 6CM91601YM, is real. So:
/// alphanumeric serial first, then a numeric serial that is not a known placeholder, then
/// macOS's display UUID as a last resort.
public enum DisplayKey {
    /// Numeric serials that monitors report when they have none.
    public static let placeholderSerials: Set<UInt32> = [0, 1, 0x0101_0101, 0xFFFF_FFFF]

    public struct Inputs: Sendable {
        public var isBuiltin: Bool
        public var vendor: UInt32
        public var model: UInt32
        public var numericSerial: UInt32
        public var alphanumericSerial: String?
        public var displayUUID: String

        public init(isBuiltin: Bool, vendor: UInt32, model: UInt32, numericSerial: UInt32,
                    alphanumericSerial: String?, displayUUID: String) {
            self.isBuiltin = isBuiltin
            self.vendor = vendor
            self.model = model
            self.numericSerial = numericSerial
            self.alphanumericSerial = alphanumericSerial
            self.displayUUID = displayUUID
        }
    }

    public static func make(_ i: Inputs) -> String {
        // Profiles are per Mac, so "the built-in screen" needs no further identity.
        if i.isBuiltin { return "builtin" }
        if let serial = usable(i.alphanumericSerial) {
            return "sn:\(i.vendor)-\(i.model)-\(serial)"
        }
        if !placeholderSerials.contains(i.numericSerial) {
            return "edid:\(i.vendor)-\(i.model)-\(i.numericSerial)"
        }
        return "uuid:\(i.displayUUID)"
    }

    /// Rejects empty serials and filler like "0000000000".
    static func usable(_ serial: String?) -> String? {
        guard let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.count >= 4, Set(trimmed).count > 1
        else { return nil }
        return trimmed
    }

    /// Two identical monitors with no usable serials can still end up with one key. Keep
    /// them apart by position, left to right, so each still gets its own windows.
    /// `keys` and `xs` are parallel arrays.
    public static func disambiguate(_ keys: [String], xs: [Double]) -> [String] {
        var result = keys
        let groups = Dictionary(grouping: keys.indices, by: { keys[$0] })
        for (key, indices) in groups where indices.count > 1 {
            for (n, index) in indices.sorted(by: { xs[$0] < xs[$1] }).enumerated() where n > 0 {
                result[index] = "\(key)#\(n + 1)"
            }
        }
        return result
    }
}
