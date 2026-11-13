import AppKit
import Foundation
import UserNotifications

/// True only when running from a real .app bundle. `swift test` runs from a bare tool,
/// where `UNUserNotificationCenter.current()` would crash.
enum NudgeRuntime {
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}

/// Local notifications only. Nothing here touches the network.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    enum Authorization: String, Codable, Sendable {
        case unavailable, notDetermined, denied, authorized, provisional, ephemeral, unknown
    }

    /// Called with (action identifier, notification identifier, userInfo) when the user clicks a notification or one of its buttons.
    var onResponse: ((String, String, [String: String]) -> Void)?

    private var center: UNUserNotificationCenter? { NudgeRuntime.isAppBundle ? .current() : nil }

    func configure(categories: Set<UNNotificationCategory> = []) {
        guard let center else { return }
        center.delegate = self
        if !categories.isEmpty { center.setNotificationCategories(categories) }
    }

    func authorization() async -> Authorization {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    /// Shows the macOS permission prompt the first time. Returns (granted, error text).
    func requestAuthorization() async -> (granted: Bool, error: String?) {
        guard let center else { return (false, "Not running from an app bundle.") }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return (granted, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Posts a local notification. Returns an error description, or nil on success.
    func post(id: String, title: String, body: String, category: String? = nil,
              userInfo: [String: String] = [:]) async -> String? {
        guard let center else { return "Not running from an app bundle." }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do { try await center.add(request); return nil } catch { return error.localizedDescription }
    }

    func openNotificationSettings() {
        let bundle = Bundle.main.bundleIdentifier ?? "com.local.MacSweep"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .unknown
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        await MainActor.run { NotificationService.shared.onResponse?(action, id, info) }
    }
}
