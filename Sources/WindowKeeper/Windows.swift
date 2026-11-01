import AppKit
import SwiftUI

/// Hosts a SwiftUI view in an ordinary window. The app is an accessory (menu bar only),
/// so it activates itself for the window to come to the front.
@MainActor
class HostedWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let title: String
    /// Where the size the user drags a scrolling window to is kept (per Mac), or nil.
    var sizeKey: String?

    init(title: String) {
        self.title = title
    }

    /// The lowest a scrolling window can be dragged to.
    static let minimumHeight: CGFloat = 280

    /// The content size the user last dragged the window to, or nil while they haven't.
    var chosenSize: NSSize? {
        get { sizeKey.flatMap { UserDefaults.standard.string(forKey: $0) }.map(NSSizeFromString) }
        set { if let sizeKey { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: sizeKey) } }
    }

    /// With `scrolls`, the window opens at the view's natural height (measured at `width`) but
    /// never taller than the screen (a MacBook Air couldn't fit Settings), and the content
    /// scrolls when cut short. It can be dragged wider and taller, and with a `sizeKey` the size
    /// the user drags to is used from then on. The window is sized here rather than by SwiftUI:
    /// letting SwiftUI size a window that AppKit then clamps to the screen loops until AppKit
    /// aborts.
    func present<V: View>(_ view: V, resizable: Bool = false, scrolls: Bool = false, width: CGFloat? = nil) {
        let controller: NSViewController
        var size: NSSize?
        var minWidth: CGFloat = 0
        if scrolls {
            let formWidth = width ?? NSHostingView(rootView: view).fittingSize.width
            minWidth = formWidth
            let naturalHeight = NSHostingView(rootView: view.frame(width: formWidth)).fittingSize.height
            let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: formWidth, height: naturalHeight)
            let available = max(screen.height - 80, 240)
            size = NSSize(width: formWidth, height: min(naturalHeight, available))
            if let chosen = chosenSize {
                size = NSSize(width: max(chosen.width, formWidth), height: min(max(chosen.height, Self.minimumHeight), available))
            }
            let hosting = NSHostingController(rootView: ScrollView(.vertical) {
                view.frame(minWidth: formWidth, maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity))
            hosting.sizingOptions = []
            // Inside a plain container, so SwiftUI doesn't manage the window's size limits
            // (as the window's own content controller it cleared the minimum size whenever a
            // sheet came and went).
            let container = NSViewController()
            container.view = NSView(frame: NSRect(origin: .zero, size: size ?? .zero))
            container.addChild(hosting)
            hosting.view.frame = container.view.bounds
            hosting.view.autoresizingMask = [.width, .height]
            container.view.addSubview(hosting.view)
            controller = container
        } else {
            controller = NSHostingController(rootView: view)
        }
        let isNew = window == nil
        if let window {
            window.contentViewController = controller
        } else {
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.styleMask = resizable || scrolls ? [.titled, .closable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        if let size, let window {
            window.setContentSize(size)
            // No narrower than the form, and the height can shrink to scroll.
            window.contentMinSize = NSSize(width: minWidth, height: min(Self.minimumHeight, size.height))
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        if isNew { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// A size the user dragged to is kept, and used next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard sizeKey != nil, let window else { return }
        chosenSize = window.contentRect(forFrameRect: window.frame).size
    }
}

@MainActor
final class SettingsWindowController: HostedWindowController {
    private let keeper: Keeper
    private let launchAtLogin: LaunchAtLogin

    /// The one Settings window, for the update notification and the What's New… button.
    private(set) static weak var shared: SettingsWindowController?

    init(keeper: Keeper, launchAtLogin: LaunchAtLogin) {
        self.keeper = keeper
        self.launchAtLogin = launchAtLogin
        super.init(title: "WindowKeeper Settings")
        sizeKey = "settings.contentSize"
        Self.shared = self
    }

    func show() {
        present(SettingsView(settings: .shared, launchAtLogin: launchAtLogin, store: keeper.store, keeper: keeper),
                scrolls: true, width: 460)
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }
}

@MainActor
final class ProfilesWindowController: HostedWindowController {
    private let keeper: Keeper

    init(keeper: Keeper) {
        self.keeper = keeper
        super.init(title: "Monitor Profiles")
    }

    func show(highlight: UUID? = nil) {
        present(ProfilesView(store: keeper.store, keeper: keeper, highlight: highlight))
    }
}
