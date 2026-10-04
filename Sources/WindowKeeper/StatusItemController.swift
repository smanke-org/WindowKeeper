import AppKit
import WindowKeeperKit

/// The menu bar menu. Rebuilt each time it opens so names, profiles and status are current.
///
/// The menu holds actions; preferences live in Settings (the rule settled on in Desktop Bins
/// Widget, whose menu had grown cluttered with duplicated toggles).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let keeper: Keeper
    private let settingsWindow: SettingsWindowController
    private let profilesWindow: ProfilesWindowController
    /// The app that was in front when the menu opened. Opening a status menu does not
    /// activate WindowKeeper, so this is the app the user means by "this app".
    private var frontmost: NSRunningApplication?

    init(keeper: Keeper, settingsWindow: SettingsWindowController, profilesWindow: ProfilesWindowController) {
        self.keeper = keeper
        self.settingsWindow = settingsWindow
        self.profilesWindow = profilesWindow
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        // Enabled state is set by hand below; auto-enabling would override it.
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        // Settings can hide the menu bar icon (the app then lives in the Dock, or nowhere).
        statusItem.isVisible = AppPresence.showInMenuBar
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.isVisible = AppPresence.showInMenuBar }
        }
    }

    /// A car's side window. Badged with "!" while a permission it needs is missing:
    /// Accessibility (nothing works without it) or, with desktop icons on, Finder.
    func updateIcon() {
        let symbol = keeper.isTrusted && !finderBlocked ? "car.window.right" : "car.window.right.exclamationmark"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WindowKeeper")
    }

    private var finderBlocked: Bool {
        AppSettings.shared.rememberDesktopIcons && FinderDesktop.access == .denied
    }

    private var iconsOn: Bool { AppSettings.shared.rememberDesktopIcons }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateIcon()
        let candidate = NSWorkspace.shared.frontmostApplication
        frontmost = candidate?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : candidate

        if !keeper.isTrusted {
            menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(grantAccess), target: self)
                .toolTip = "WindowKeeper needs Accessibility access to read and move other apps' windows."
            menu.addItem(.separator())
        }
        if finderBlocked {
            menu.addItem(withTitle: "Allow Finder Access…", action: #selector(grantFinderAccess), target: self)
                .toolTip = "WindowKeeper asks Finder to move desktop icons, which needs Automation › Finder."
            menu.addItem(.separator())
        }

        // Where we are.
        let profileName = keeper.currentProfile?.name ?? "Detecting monitors…"
        let lock = keeper.currentProfile?.isLocked == true ? "  🔒" : ""
        menu.addItem(disabled: "Monitors: \(profileName)\(lock)")
        if let activity = keeper.lastActivity { menu.addItem(disabled: activity) }
        menu.addItem(.separator())

        // Save.
        menu.addItem(withTitle: iconsOn ? "Save All Windows & Icons Now" : "Save All Windows Now",
                     action: #selector(saveAll), keyEquivalent: "s", target: self)
        let saveApp = menu.addItem(withTitle: "Save \(appLabel) Windows", action: #selector(saveFrontmost), target: self)
        saveApp.isEnabled = frontmost != nil
        menu.addItem(.separator())

        // Restore.
        menu.addItem(withTitle: iconsOn ? "Restore All Windows & Icons" : "Restore All Windows",
                     action: #selector(restoreAll), keyEquivalent: "r", target: self)
        let restoreApp = menu.addItem(withTitle: "Restore \(appLabel) Windows", action: #selector(restoreFrontmost), target: self)
        restoreApp.isEnabled = frontmost != nil
        if iconsOn {
            let icons = menu.addItem(withTitle: "Restore Desktop Icons", action: #selector(restoreIcons), target: self)
            icons.isEnabled = keeper.currentProfile?.icons.isEmpty == false
        }
        menu.addItem(submenuTitled: "Restore from Profile", profilesMenu())
        let undo = menu.addItem(withTitle: "Undo Last Restore", action: #selector(undoRestore), keyEquivalent: "z", target: self)
        undo.isEnabled = keeper.undoSnapshot != nil
        menu.addItem(.separator())

        menu.addItem(withTitle: "Monitor Profiles…", action: #selector(showProfiles), target: self)
        if let pending = UpdateAvailability.shared.pending {
            menu.addItem(withTitle: "Update to \(pending)…", action: #selector(checkForUpdates), target: self)
                .toolTip = "A newer release is available. Installing it needs your confirmation."
        } else {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), target: self)
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",", target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WindowKeeper", action: #selector(quit), keyEquivalent: "q", target: self)
        menu.addItem(.separator())
        menu.addItem(disabled: "WindowKeeper \(AppInfo.displayVersion)")
    }

    /// The menu as text, submenus indented — for the debug log.
    func dumpMenu() -> String {
        guard let menu = statusItem.menu else { return "" }
        menuNeedsUpdate(menu)
        func lines(_ menu: NSMenu, _ depth: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                let indent = String(repeating: "    ", count: depth)
                let mark = item.state == .on ? "✓ " : ""
                let line = item.isSeparatorItem ? indent + "---" : indent + mark + item.title + (item.isEnabled ? "" : "  (disabled)")
                return [line] + (item.submenu.map { lines($0, depth + 1) } ?? [])
            }
        }
        return lines(menu, 1).joined(separator: "\n")
    }

    private var appLabel: String {
        guard let name = frontmost?.localizedName else { return "Current App’s" }
        return "“\(name)”"
    }

    /// Every saved profile; choosing one restores all windows from it, wherever its
    /// monitors are. Each also offers just the frontmost app.
    private func profilesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let profiles = keeper.store.library.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !profiles.isEmpty else {
            menu.addItem(disabled: "No saved profiles")
            return menu
        }
        for profile in profiles {
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(withTitle: "All Windows", action: #selector(restoreProfileAll(_:)), target: self).representedObject = profile.id
            let app = sub.addItem(withTitle: "\(appLabel) Windows", action: #selector(restoreProfileApp(_:)), target: self)
            app.representedObject = profile.id
            app.isEnabled = frontmost != nil
            sub.addItem(.separator())
            sub.addItem(disabled: "\(profile.windows.count) saved window(s), \(profile.icons.count) icon(s)")

            let item = menu.addItem(submenuTitled: profile.name, sub)
            item.state = profile.id == keeper.currentProfileID ? .on : .off
            item.isEnabled = !profile.windows.isEmpty
        }
        return menu
    }

    // MARK: - Actions

    @objc private func grantAccess() {
        AXWindows.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func grantFinderAccess() { FinderDesktop.openAutomationSettings() }
    @objc private func restoreIcons() { keeper.restoreIconsOnly() }
    @objc private func undoRestore() { keeper.undoLastRestore() }
    @objc private func saveAll() { keeper.save(.all) }
    @objc private func restoreAll() { keeper.restore(.all) }

    @objc private func saveFrontmost() {
        guard let app = frontmost else { return }
        keeper.save(.app(app))
    }

    @objc private func restoreFrontmost() {
        guard let app = frontmost else { return }
        keeper.restore(.app(app))
    }

    @objc private func restoreProfileAll(_ sender: NSMenuItem) {
        guard let profile = keeper.store.profile(id: sender.representedObject as? UUID) else { return }
        keeper.restore(.all, from: profile)
    }

    @objc private func restoreProfileApp(_ sender: NSMenuItem) {
        guard let app = frontmost, let profile = keeper.store.profile(id: sender.representedObject as? UUID) else { return }
        keeper.restore(.app(app), from: profile)
    }

    @objc private func showProfiles() { profilesWindow.show() }
    @objc private func showSettings() { settingsWindow.show() }
    @objc private func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String = "", target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
        return item
    }

    @discardableResult
    func addItem(submenuTitled title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }

    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
