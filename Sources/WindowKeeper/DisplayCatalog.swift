import AppKit
import IOKit
import WindowKeeperKit

/// The monitors connected right now, each with a stable key.
///
/// macOS has no public way to get a monitor's alphanumeric serial for a screen. The route
/// used here: CoreDisplay's info dictionary for a display ID names its framebuffer in the
/// I/O Registry (`IODisplayLocation`), and that framebuffer's `DisplayAttributes` carry the
/// EDID serials. Verified on Apple silicon with macOS 27 — it is private, so any failure
/// falls back to the public vendor/model/serial numbers, which `DisplayKey` copes with.
@MainActor
enum DisplayCatalog {
    static func current() -> [LiveDisplay] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let mainID = CGMainDisplayID()
        // AppKit's global space is bottom-left at the main display; Accessibility and
        // CGDisplayBounds are top-left. Flip around the main display's height.
        let mainHeight = CGDisplayBounds(mainID).height

        var displays: [LiveDisplay] = screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let v = screen.visibleFrame
            let visible = CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            return LiveDisplay(
                key: key(for: id, isBuiltin: isBuiltin),
                name: screen.localizedName,
                isBuiltin: isBuiltin,
                isMain: id == mainID,
                bounds: CGDisplayBounds(id),
                visible: visible
            )
        }
        let keys = DisplayKey.disambiguate(displays.map(\.key), xs: displays.map { Double($0.bounds.minX) })
        for i in displays.indices { displays[i].key = keys[i] }
        return displays
    }

    private static func key(for id: CGDirectDisplayID, isBuiltin: Bool) -> String {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
        return DisplayKey.make(.init(
            isBuiltin: isBuiltin,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            numericSerial: CGDisplaySerialNumber(id),
            alphanumericSerial: alphanumericSerial(for: id),
            displayUUID: uuid
        ))
    }

    private typealias InfoFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let createInfoDictionary: InfoFunction? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary")
        else { return nil }
        return unsafeBitCast(symbol, to: InfoFunction.self)
    }()

    static func alphanumericSerial(for id: CGDirectDisplayID) -> String? {
        guard let createInfoDictionary,
              let info = createInfoDictionary(id)?.takeRetainedValue() as? [String: Any],
              let path = info["IODisplayLocation"] as? String
        else { return nil }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let attributes = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "DisplayAttributes" as CFString, nil, options) as? [String: Any]
        let product = attributes?["ProductAttributes"] as? [String: Any]
        return product?["AlphanumericSerialNumber"] as? String
    }
}
