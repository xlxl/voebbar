import AppKit
import UserNotifications

/// User notifications for due-soon/overdue loans (and other rare, important events).
///
/// Authorization is requested lazily on first use — macOS's own permission dialog is the opt-in.
/// The feature can be turned off in Preferences (`AccountStorage.notificationsEnabled`).
/// Clicking a notification opens the loans overview window.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// UNUserNotificationCenter aborts in unbundled processes (`swift run`, bare debug binary) —
    /// only use it when running from a real .app bundle.
    private let available = Bundle.main.bundleIdentifier != nil

    private override init() {
        super.init()
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(title: String, body: String) {
        guard available, AccountStorage.shared.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Clicking the notification opens the overview of all loans.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            let data = (NSApp.delegate as? AppDelegate)?.statusBarController?.currentData ?? []
            OverviewWindowController.shared.showWindow(with: data)
        }
        completionHandler()
    }

    /// A menu-bar accessory app counts as "foreground" — show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
