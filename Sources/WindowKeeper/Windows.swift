import AppKit
import SwiftUI

/// Hosts a SwiftUI view in an ordinary window. The app is an accessory (menu bar only),
/// so it activates itself for the window to come to the front.
@MainActor
class HostedWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String

    init(title: String) {
        self.title = title
    }

    /// With `scrolls`, the window opens at the view's natural height but never taller than
    /// the screen (a MacBook Air couldn't fit Settings), and the content scrolls when cut short.
    /// The window is sized here rather than by SwiftUI: letting SwiftUI size a window that
    /// AppKit then clamps to the screen loops until AppKit aborts.
    func present<V: View>(_ view: V, resizable: Bool = false, scrolls: Bool = false) {
        let controller: NSViewController
        var size: NSSize?
        if scrolls {
            let natural = NSHostingView(rootView: view).fittingSize
            let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? natural
            size = NSSize(width: natural.width, height: min(natural.height, max(screen.height - 80, 240)))
            let hosting = NSHostingController(rootView: ScrollView(.vertical) { view }.frame(maxHeight: .infinity))
            hosting.sizingOptions = []
            controller = hosting
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
            // Fixed width; the height can shrink to scroll or grow back to the full content.
            window.contentMinSize = NSSize(width: size.width, height: 200)
            window.contentMaxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        }
        if isNew { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

@MainActor
final class SettingsWindowController: HostedWindowController {
    private let keeper: Keeper
    private let launchAtLogin: LaunchAtLogin

    init(keeper: Keeper, launchAtLogin: LaunchAtLogin) {
        self.keeper = keeper
        self.launchAtLogin = launchAtLogin
        super.init(title: "WindowKeeper Settings")
    }

    func show() {
        present(SettingsView(settings: .shared, launchAtLogin: launchAtLogin, store: keeper.store, keeper: keeper), scrolls: true)
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
