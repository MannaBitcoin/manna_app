import Firebase
import FirebaseMessaging
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private var flutterBinaryMessenger: FlutterBinaryMessenger?
    public var pendingNotificationData: [String: Any]? = nil
    private let appGroupIdentifier = "group.com.lightning.manna"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication
            .LaunchOptionsKey: Any]?
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
        application.registerForRemoteNotifications()

        return super.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let registry = engineBridge.pluginRegistry
        SecureStoragePlugin.register(with: registry.registrar(forPlugin: "SecureStoragePlugin")!)
        NotificationPlugin.register(with: registry.registrar(forPlugin: "NotificationPlugin")!)

        self.flutterBinaryMessenger = engineBridge.applicationRegistrar.messenger()
    }

    // MARK: - Push Notification Token
    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    // MARK: - Foreground notification
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        /// to eliminate cycle, this code force shows the notification created by app via ``NotificationPlugin/showNotification``
        if let isLocal = userInfo["isLocalNotification"] as? Bool, isLocal {
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .sound, .badge, .list])
            } else {
                completionHandler([.alert, .sound, .badge])
            }
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

            channel.invokeMethod("onForegroundMessage", arguments: mergeNotificationData(userInfo: userInfo))
            completionHandler([])
            return
        }

        if shouldShowNotification {
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .sound, .badge, .list])
            } else {
                completionHandler([.alert, .sound, .badge])
            }
            return
        }

        completionHandler([])
    }

    // MARK: - Notification tap (didReceive)
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationTap(
            userInfo: mergeNotificationData(userInfo: response.notification.request.content.userInfo),
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

    // MARK: - App Lifecycle
    override func applicationDidBecomeActive(_ application: UIApplication) {
        super.applicationDidBecomeActive(application)
        updateForegroundState(isForeground: true)
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        updateForegroundState(isForeground: false)
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        super.applicationWillTerminate(application)
        updateForegroundState(isForeground: false)
    }

    override func applicationWillEnterForeground(_ application: UIApplication) {
        super.applicationWillEnterForeground(application)
        updateForegroundState(isForeground: true)
    }

    private func updateForegroundState(isForeground: Bool) {
        if let shared = UserDefaults(suiteName: appGroupIdentifier) {
            shared.set(isForeground, forKey: "is_foreground")
        }
    }
}
