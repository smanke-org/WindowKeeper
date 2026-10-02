import Foundation
import Observation
import WindowKeeperKit

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// Save every window's position on a timer.
    var autoSave: Bool { didSet { store(autoSave, "autoSave"); scheduleChanged() } }
    /// The interval as typed: a number and a unit.
    var autoSaveValue: Int { didSet { store(autoSaveValue, "autoSaveValue"); scheduleChanged() } }
    var autoSaveUnit: IntervalUnit { didSet { store(autoSaveUnit.rawValue, "autoSaveUnit"); scheduleChanged() } }

    var autoSaveSeconds: TimeInterval { SaveInterval.seconds(value: autoSaveValue, unit: autoSaveUnit) }

    /// Put windows back when a known monitor setup with an external display is connected.
    var restoreOnProfileDetected: Bool { didSet { store(restoreOnProfileDetected, "restoreOnProfileDetected") } }
    /// Put windows back when WindowKeeper itself starts — normally at login after a restart.
    var restoreOnLaunch: Bool { didSet { store(restoreOnLaunch, "restoreOnLaunch") } }
    /// Put an app's windows back when that app is opened again.
    var restoreOnAppRelaunch: Bool { didSet { store(restoreOnAppRelaunch, "restoreOnAppRelaunch") } }

    /// Look for a newer release shortly after launch. Silent unless there is one.
    var checkForUpdatesAtLaunch: Bool { didSet { store(checkForUpdatesAtLaunch, "checkForUpdatesAtLaunch") } }
    /// A version the user chose to skip; the launch check stays quiet about it.
    var skippedUpdateVersion: String? { didSet { defaults.set(skippedUpdateVersion, forKey: "skippedUpdateVersion") } }
    /// Launch at login is switched on once, the first time the app runs from /Applications.
    /// After that it is the user's setting, and turning it off sticks.
    var didOfferLaunchAtLogin: Bool { didSet { store(didOfferLaunchAtLogin, "didOfferLaunchAtLogin") } }

    /// Called when anything affecting the auto-save timer changes.
    @ObservationIgnored var onScheduleChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "autoSave": true,
            "autoSaveValue": 5,
            "autoSaveUnit": IntervalUnit.minutes.rawValue,
            "restoreOnProfileDetected": true,
            "restoreOnLaunch": true,
            "restoreOnAppRelaunch": true,
            "checkForUpdatesAtLaunch": true,
            "didOfferLaunchAtLogin": false,
        ])
        autoSave = defaults.bool(forKey: "autoSave")
        autoSaveValue = max(1, defaults.integer(forKey: "autoSaveValue"))
        autoSaveUnit = IntervalUnit(rawValue: defaults.string(forKey: "autoSaveUnit") ?? "") ?? .minutes
        restoreOnProfileDetected = defaults.bool(forKey: "restoreOnProfileDetected")
        restoreOnLaunch = defaults.bool(forKey: "restoreOnLaunch")
        restoreOnAppRelaunch = defaults.bool(forKey: "restoreOnAppRelaunch")
        checkForUpdatesAtLaunch = defaults.bool(forKey: "checkForUpdatesAtLaunch")
        skippedUpdateVersion = defaults.string(forKey: "skippedUpdateVersion")
        didOfferLaunchAtLogin = defaults.bool(forKey: "didOfferLaunchAtLogin")
    }

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
    private func scheduleChanged() { onScheduleChange?() }
}
