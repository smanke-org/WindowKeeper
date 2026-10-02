import AppKit
import ApplicationServices

/// A window of another app, as seen through the Accessibility API.
struct AXWindow {
    let element: AXUIElement
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFullScreen: Bool
    let isStandard: Bool

    /// Worth saving: an ordinary window, not a sheet, panel or full-screen space.
    var isSaveable: Bool { isStandard && !isFullScreen }
    /// Worth moving: saveable and on screen.
    var isPlaceable: Bool { isSaveable && !isMinimized }
}

/// Reads and moves other apps' windows. Needs the Accessibility permission.
@MainActor
enum AXWindows {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility. Only ever
    /// called from a click.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Apps whose windows WindowKeeper looks after: ordinary Dock apps, not itself.
    static func managedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func appElement(for pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hang WindowKeeper with it.
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    static func windows(of pid: pid_t) -> [AXWindow] {
        let app = appElement(for: pid)
        guard let elements = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return elements.compactMap(window)
    }

    static func window(_ element: AXUIElement) -> AXWindow? {
        // Under some conditions macOS answers the window list with stand-ins (each one the
        // application element itself) instead of windows; only real windows count.
        guard copy(element, kAXRoleAttribute) as? String == kAXWindowRole,
              let frame = frame(of: element) else { return nil }
        let subrole = copy(element, kAXSubroleAttribute) as? String
        return AXWindow(
            element: element,
            title: copy(element, kAXTitleAttribute) as? String ?? "",
            frame: frame,
            isMinimized: copy(element, kAXMinimizedAttribute) as? Bool ?? false,
            isFullScreen: copy(element, "AXFullScreen") as? Bool ?? false,
            isStandard: subrole == kAXStandardWindowSubrole
        )
    }

    /// One line for the log: how many window entries each app reports, and how many are
    /// usable windows. Counts only — never titles, which can hold private document names.
    static func probe() -> String {
        var listed = 0
        var usable = 0
        for app in managedApps() {
            let elements = copy(appElement(for: app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            listed += elements.count
            usable += elements.compactMap(window).count
        }
        return "window probe: trusted=\(isTrusted) apps=\(managedApps().count) listed=\(listed) usable=\(usable)"
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = copy(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Moves and resizes a window. Position goes first and again last: an app clamps a new
    /// size to the display the window is on *now*, so moving to a larger display first and
    /// re-asserting the position after the resize gets the frame that was asked for.
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let a = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        let b = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let c = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return a == .success || b == .success || c == .success
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
