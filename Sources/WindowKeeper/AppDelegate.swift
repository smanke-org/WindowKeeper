import AppKit
import Observation

/// Owns the long-lived objects and starts them at launch. Restoring after a restart has to
/// run from the moment the app starts at login, not from the first time the menu opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProfileStore()
    private lazy var keeper = Keeper(store: store)
    private let launchAtLogin = LaunchAtLogin()
    private let notifier = NewDeskNotifier()
    private var settingsWindow: SettingsWindowController!
    private var profilesWindow: ProfilesWindowController!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.note("launch \(AppInfo.displayVersion) from \(Bundle.main.bundlePath)")
        settingsWindow = SettingsWindowController(keeper: keeper, launchAtLogin: launchAtLogin)
        profilesWindow = ProfilesWindowController(keeper: keeper)
        statusItem = StatusItemController(keeper: keeper, settingsWindow: settingsWindow, profilesWindow: profilesWindow)

        keeper.onNewProfile = { [weak self] profile in self?.notifier.announce(profile) }
        notifier.onOpen = { [weak self] id in self?.profilesWindow.show(highlight: id) }
        keeper.start()
        observeTrust()
        listenForDebugCommands()

        launchAtLogin.enableOnFirstRun()
        if AppSettings.shared.checkForUpdatesAtLaunch {
            // Deferred so startup is not waiting on the network; silent unless there is
            // something to offer, and even then it only adds a menu item.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { UpdateController.checkForUpdates(silent: true) }
        }
        if !keeper.isTrusted {
            // First run: show why nothing will happen yet. Opened at launch, which is a
            // deliberate act by the user, never from a background timer.
            settingsWindow.show()
        }
    }

    /// Keeps the menu bar icon's warning badge in step with the Accessibility permission.
    private func observeTrust() {
        withObservationTracking {
            _ = keeper.isTrusted
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.statusItem.updateIcon()
                self?.observeTrust()
            }
        }
    }

    /// Development affordance, only with WINDOWKEEPER_DEBUG=1. A distributed notification
    /// whose object is "save:<bundle id>", "restore:<bundle id>", "show:settings",
    /// "show:profiles" or "dump:menu" runs that action, so the installed, permission-holding
    /// build can be tested against a throwaway app without driving the menu bar or touching
    /// anyone's real windows. Results go to the log.
    private func listenForDebugCommands() {
        guard Diagnostics.isEnabled else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.smanke.WindowKeeper.debug"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { [weak self] in self?.runDebugCommand(command) }
        }
    }

    private func runDebugCommand(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Diagnostics.note("debug: bad command \(command)") }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: parts[1]).first
        switch (parts[0], parts[1]) {
        case ("save", _) where app != nil:
            Diagnostics.note("debug: saved \(keeper.save(.app(app!)) ?? -1) window(s) of \(parts[1])")
        case ("restore", _) where app != nil:
            Diagnostics.note("debug: restored \(keeper.restore(.app(app!)) ?? -1) window(s) of \(parts[1])")
        case ("show", "settings"): settingsWindow.show()
        case ("show", "profiles"): profilesWindow.show(highlight: keeper.currentProfileID)
        case ("dump", "menu"): Diagnostics.note("debug: menu\n" + statusItem.dumpMenu())
        default: Diagnostics.note("debug: unknown command \(command)")
        }
    }
}
