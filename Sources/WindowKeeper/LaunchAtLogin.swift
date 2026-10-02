import Foundation
import Observation
import ServiceManagement

/// Starting at login is how windows go back after a restart, so it is switched on the
/// first time the app runs from /Applications. Uses SMAppService.mainApp; there is no helper.
@Observable
@MainActor
final class LaunchAtLogin {
    private(set) var isEnabled = false
    private(set) var needsApproval = false

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diagnostics.note("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Turns it on once, and only from /Applications: registering a copy running from a
    /// build folder would start that copy at every login.
    func enableOnFirstRun() {
        let settings = AppSettings.shared
        guard !settings.didOfferLaunchAtLogin,
              Bundle.main.bundlePath.hasPrefix("/Applications/")
        else { return }
        settings.didOfferLaunchAtLogin = true
        if !isEnabled { set(true) }
        Diagnostics.note("launch at login enabled on first run: \(isEnabled)")
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
