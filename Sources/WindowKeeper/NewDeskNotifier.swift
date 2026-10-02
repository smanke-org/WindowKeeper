import AppKit
import UserNotifications
import WindowKeeperKit

/// Tells the user when an unfamiliar set of monitors became a new profile, with a way to
/// name it. Clicking the notification opens Monitor Profiles with the new one selected.
@MainActor
final class NewDeskNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private nonisolated static let renameAction = "rename"
    private nonisolated static let category = "newDesk"

    override init() {
        super.init()
        center.delegate = self
        let rename = UNNotificationAction(identifier: Self.renameAction, title: "Rename…", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [rename], intentIdentifiers: [])])
    }

    func announce(_ profile: MonitorProfile) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "New monitor setup"
            content.body = "Saved as “\(profile.name)”. Windows you arrange here are kept separately from your other desks."
            content.categoryIdentifier = Self.category
            content.userInfo = ["profile": profile.id.uuidString]
            // A fresh identifier each time: re-posting under one still in Notification
            // Centre updates it silently, with no banner.
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // The completion-handler forms, not the async ones: in NetworkToggle the async
    // delegate methods compiled and were never called.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["profile"] as? String).flatMap(UUID.init)
        completionHandler()
        Task { @MainActor in
            if let id { self.onOpen?(id) }
        }
    }
}
