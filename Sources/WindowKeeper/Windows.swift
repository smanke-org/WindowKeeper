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

    func present<V: View>(_ view: V, resizable: Bool = false) {
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
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
        present(SettingsView(settings: .shared, launchAtLogin: launchAtLogin, store: keeper.store, keeper: keeper))
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
