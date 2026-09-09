import Foundation

#if os(iOS)
    import Flutter
#elseif os(macOS)
    import FlutterMacOS
#endif

public class SecureStoragePlugin: NSObject, FlutterPlugin {
    static let channelName = "com.lightning.manna/secure_storage"

    init(channel: FlutterMethodChannel) {
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
            let messenger = registrar.messenger()
        #else
            let messenger = registrar.messenger
        #endif

        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        let instance = SecureStoragePlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "invalid_arguments", message: "Arguments must be a dictionary", details: nil))
            return
        }

        let key = args["key"] as? String ?? ""
        let service = args["service"] as? String
        let useSecureEnclave = args["useSecureEnclave"] as? Bool ?? true
        let accessibilityStr = args["accessibility"] as? String
        let authRequired = args["authenticationRequired"] as? Bool ?? false
        let biometryCurrentSet = args["biometryCurrentSetOnly"] as? Bool ?? true
        let prompt = args["authenticationPrompt"] as? String
        let accessGroup = args["accessGroup"] as? String

        let accessibility: CFString = {
            switch accessibilityStr {
            case "whenUnlocked": return kSecAttrAccessibleWhenUnlocked
            case "afterFirstUnlock": return kSecAttrAccessibleAfterFirstUnlock
            case "afterFirstUnlockThisDeviceOnly": return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case "whenPasscodeSetThisDeviceOnly": return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            case "whenUnlockedThisDeviceOnly": return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            default: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }()

        let options = SecureStorage.StorageOptions(
            service: service,
            accessibility: accessibility,
            useSecureEnclave: useSecureEnclave,
            accessGroup: accessGroup,
            authenticationRequired: authRequired,
            biometryCurrentSetOnly: biometryCurrentSet,
            authenticationPrompt: prompt
        )

        switch call.method {
        case "exists":
            result(SecureStorage.exists(key: key, options: options))

        case "store":
            guard let flutterData = args["value"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "invalid_data", message: "Data must be bytes", details: nil))
                return
            }
            let data = flutterData.data
            let res = SecureStorage.save(key: key, data: data, options: options)

            switch res {
            case .success: result(nil)
            case .failure(let error):
                result(FlutterError(code: "store_failed", message: String(describing: error), details: nil))
            }

        case "fetch":
            let res = SecureStorage.fetch(key: key, options: options)
            switch res {
            case .success(let data?):
                result(FlutterStandardTypedData(bytes: data))
            case .success(nil):
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "fetch_failed", message: String(describing: error), details: nil))
            }

        case "delete":
            let res = SecureStorage.delete(key: key, options: options)
            switch res {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "delete_failed", message: String(describing: error), details: nil))
            }

        // key can not be deleted, delete all entries instead
        case "deleteKey":
            let res = SecureStorage.deleteAllKeychainItems()
            switch res {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "wipe_failed", message: String(describing: error), details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
