import Foundation
import UserNotifications
import Combine

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled")
            if isEnabled {
                requestAuthorization()
            } else {
                disableNotifications()
            }
        }
    }

    private init() {
        // Load saved preference, default to true for backwards compatibility
        self.isEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// Request notification authorization from the system
    func requestAuthorization() {
        guard isEnabled else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            #if DEBUG
            if let error = error {
                print("❌ Notification authorization error: \(error.localizedDescription)")
            } else if granted {
                print("✅ Notifications authorized")
            } else {
                print("⚠️ Notification authorization denied by user")
            }
            #endif
        }
    }

    /// Disable notifications by removing all pending and delivered notifications
    func disableNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Check if the user has granted notification permissions
    func checkAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    /// Display a notification if notifications are enabled
    func displayNotification(title: String, subtitle: String? = nil, body: String, identifier: String, userInfo: [String: String] = [:]) {
        guard isEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }
}
