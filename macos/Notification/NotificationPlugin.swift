import Foundation
import UserNotifications

#if os(iOS)
    import Flutter
    import FirebaseMessaging
#elseif os(macOS)
    import FlutterMacOS
    import FirebaseMessaging
#endif

public class NotificationPlugin: NSObject, FlutterPlugin {
    static let channelName = "com.lightning.manna/notifications"
    private var channel: FlutterMethodChannel
    private let appGroupIdentifier = "group.com.lightning.manna"

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    static public func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
            let messenger = registrar.messenger()
        #elseif os(macOS)
            let messenger = registrar.messenger
        #endif

        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)

        let instance = NotificationPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isPermissionGranted":
            isPermissionGranted(result: result)
        case "showNotification":
            self.showNotification(call: call, result: result)
        case "cancelNotification":
            self.cancelNotification(call: call, result: result)
        case "getActiveNotifications":
            self.getActiveNotifications(result: result)
        case "setActiveChatUUID":
            self.setActiveChatUUID(call: call, result: result)
        case "getFCMToken":
            self.handleGetFcmToken(result: result)
        case "getInitialClickedNotification":
            #if os(iOS)
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                    let pendingData = appDelegate.pendingNotificationData
                {
                    result(pendingData)
                    appDelegate.pendingNotificationData = nil
                } else {
                    result(nil)
                }
            #elseif os(macOS)
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                    let pendingData = appDelegate.pendingNotificationData
                {
                    result(pendingData)
                    appDelegate.pendingNotificationData = nil
                }
            #else
                result(nil)
            #endif
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func isPermissionGranted(result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                result(authorized)
            }
        }
    }

    private func showNotification(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(false)
            return
        }

        let title = args["title"] as? String ?? "Notification"
        let body = args["body"] as? String ?? ""
        let data = args["data"] as? [String: Any] ?? [:]

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [
            "data": data,
            "isLocalNotification": true,
        ]
        content.sound = .default

        if let threadId = args["groupId"] as? String {
            content.threadIdentifier = threadId
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        let request = UNNotificationRequest(
            identifier: args["notificationId"] as? String ?? UUID().uuidString,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
                if let error = error {
                    AppLogger.shared.logE("Failed to show notification: \(error)")
                    result(false)
                } else {
                    result(true)
                }
            }
        }
    }

    private func cancelNotification(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(false)
            return
        }

        let notificationId = args["notificationId"] as? String
        let center = UNUserNotificationCenter.current()
        if let id = notificationId {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        } else {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }

        result(true)
    }

    private func getActiveNotifications(result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()

        center.getDeliveredNotifications { notifications in
            let mapped = notifications.map { notification in
                let content = notification.request.content
                var data: [String: Any] = [:]

                if let userData = content.userInfo["data"] as? [String: Any] {
                    data = userData
                }

                return [
                    "id": notification.request.identifier,
                    "title": content.title,
                    "body": content.body,
                    "groupId": notification.request.content.threadIdentifier,
                    "data": data,
                    "timestamp": Int(notification.date.timeIntervalSince1970 * 1000),
                ] as [String: Any]
            }

            DispatchQueue.main.async {
                result(mapped)
            }
        }
    }

    private func setActiveChatUUID(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(nil)
            return
        }

        let uuid = args["uuid"] as? String
        let pref = UserDefaults(suiteName: appGroupIdentifier)
        pref?.set(uuid, forKey: "activeChatUUID")

        result(nil)
    }

    private func handleGetFcmToken(result: @escaping FlutterResult) {
        if let cachedToken = Messaging.messaging().fcmToken {
            result(cachedToken)
        } else {
            Messaging.messaging().token { token, error in
                if let error = error {
                    AppLogger.shared.logE("\(error)")
                    result(nil)
                } else if let token = token {
                    result(token)
                }
            }
        }
    }
}
