import Cocoa
import FirebaseCore
import FirebaseMessaging
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
    private let appGroupIdentifier = "group.com.lightning.manna"
    public var pendingNotificationData: [String: Any]?
    
    var flutterBinaryMessenger: FlutterBinaryMessenger? {
        if let mainWindow = NSApplication.shared.windows.first(where: { $0 is MainFlutterWindow }),
            let flutterVC = mainWindow.contentViewController as? FlutterViewController
        {
            return flutterVC.engine.binaryMessenger
        }
        return nil
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.registerForRemoteNotifications()
        setupLifecycleObservers()
    }

    // MARK: - macOS Specific APNs Token Forwarding
    override func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    // MARK: - Foreground notification handling
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        /// to eliminate cycle, this code force shows the notification created by app via ``NotificationPlugin/showNotification``
        if let isLocal = userInfo["isLocalNotification"] as? Bool, isLocal {
            completionHandler([.banner, .sound, .badge, .list])
            return
        }

        var shouldShowNotification = true
        let shared = UserDefaults(suiteName: appGroupIdentifier)
        let activeChatUUID = shared?.string(forKey: "activeChatUUID") ?? ""
        let notificationType = userInfo["type"] as? String
        
        if notificationType == "new_message_chat", let senderId = userInfo["senderId"] as? String {
            shouldShowNotification = senderId != activeChatUUID
        } else if let messenger = flutterBinaryMessenger {
            let channel = FlutterMethodChannel(
                name: NotificationPlugin.channelName,
                binaryMessenger: messenger
            )
            print("invoke onForegroundMessage")
            channel.invokeMethod("onForegroundMessage", arguments: mergeNotificationData(userInfo: userInfo))
            completionHandler([])
            return
        }

        if shouldShowNotification {
            completionHandler([.banner, .sound, .badge, .list])
            return
        }
        completionHandler([])
    }

    // MARK: - Notification tap (didReceive)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationTap(
            userInfo: mergeNotificationData(userInfo: response.notification.request.content.userInfo)
        )
        completionHandler()
    }

    private func handleNotificationTap(userInfo: [String: Any]) {
        let cleanData = mergeNotificationData(userInfo: userInfo)

        let isAppForeground =
            UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: "is_foreground") ?? false

        if let messenger = flutterBinaryMessenger, isAppForeground {
            let channel = FlutterMethodChannel(
                name: NotificationPlugin.channelName,
                binaryMessenger: messenger
            )
            channel.invokeMethod("onNotificationClicked", arguments: cleanData)
        } else {
            pendingNotificationData = cleanData
        }
    }

    private func mergeNotificationData(userInfo: [AnyHashable: Any]) -> [String: Any] {
        var cleanData: [String: Any] = Dictionary(
            uniqueKeysWithValues: userInfo.compactMap { (key, value) -> (String, Any)? in
                guard let stringKey = key as? String else { return nil }
                return (stringKey, value)
            }
        )

        if let aps = userInfo["aps"] as? [String: Any],
            let alert = aps["alert"] as? [String: Any]
        {
            cleanData.merge(alert) { _, new in new }
        }

        if let dataPayload = userInfo["data"] as? [String: Any] {
            cleanData.merge(dataPayload) { _, new in new }
        }
        return cleanData
    }

    // MARK: - macOS App Lifecycle Mapping
    private func setupLifecycleObservers() {
        let center = NotificationCenter.default

        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateForegroundState(isForeground: true)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateForegroundState(isForeground: false)
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateForegroundState(isForeground: false)
        }
    }

    private func updateForegroundState(isForeground: Bool) {
        if let shared = UserDefaults(suiteName: appGroupIdentifier) {
            shared.set(isForeground, forKey: "is_foreground")
        }
    }
}
