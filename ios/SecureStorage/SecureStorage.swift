import Foundation
import LocalAuthentication
import Security

final class SecureStorage {

    private static let serialQueue = DispatchQueue(label: "com.manna.securestorage", qos: .userInitiated)

    private static let enclaveAlgorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private static func enclaveKeyTag(service: String?) -> Data? {
        let tag = "com.lightning.manna.se.\(service ?? "default")"
        return tag.data(using: .utf8)
    }

    // MARK: - Enclave Key Management

    /// Returns an existing Secure Enclave key pair or creates a new one.
    /// Private key never leaves the Secure Enclave.
    @discardableResult
    static func ensureEnclaveKeyPair(service: String? = nil) -> Result<(private: SecKey, public: SecKey), Error> {
        guard let tag = enclaveKeyTag(service: service) else {
            return .failure(SecureStorageError.invalidTag)
        }

        let fetchQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecReturnRef as String: true,
        ]

        var item: CFTypeRef?
        let fetchStatus = SecItemCopyMatching(fetchQuery as CFDictionary, &item)

        if fetchStatus == errSecSuccess, let ref = item {
            let privateKey = ref as! SecKey
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                return .failure(SecureStorageError.cannotExportPublicKey)
            }
            return .success((privateKey, publicKey))
        }

        // Create new key in Secure Enclave
        var error: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &error
            )
        else {
            return .failure(error?.takeRetainedValue() ?? SecureStorageError.accessControlFailed)
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let err = error?.takeRetainedValue() {
                NSLog("SecureStorage: key generation failed: \(err.localizedDescription)")
                return .failure(err)
            }
            return .failure(SecureStorageError.keyGenerationFailed)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return .failure(SecureStorageError.cannotExportPublicKey)
        }

        return .success((privateKey, publicKey))
    }

    // MARK: - Crypto Helpers

    private static func encrypt(_ data: Data, with publicKey: SecKey) -> Result<Data, Error> {
        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(publicKey, enclaveAlgorithm, data as CFData, &error) else {
            if let err = error?.takeRetainedValue() {
                NSLog("SecureStorage: encrypt failed: \(err.localizedDescription)")
                return .failure(err)
            }
            return .failure(SecureStorageError.encryptionFailed)
        }
        return .success(ciphertext as Data)
    }

    private static func decrypt(_ data: Data, with privateKey: SecKey) -> Result<Data, Error> {
        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(privateKey, enclaveAlgorithm, data as CFData, &error) else {
            if let err = error?.takeRetainedValue() {
                NSLog("SecureStorage: decrypt failed: \(err.localizedDescription)")
                return .failure(err)
            }
            return .failure(SecureStorageError.decryptionFailed)
        }
        return .success(plaintext as Data)
    }

    // MARK: - Public API

    struct StorageOptions {
        /// optional service name for keychain item
        let service: String?
        /// String of enum ``SecAccessibility``, used to define when this keychain item can be accessed.
        let accessibility: CFString
        /// use secureEnclave to store private encryption key, if hardware doesn't supoprt secureEnclave, value will be stored in plaintext in keychain, default: true
        let useSecureEnclave: Bool
        /// optional groupId to share this keychain item to
        let accessGroup: String?
        /// optional: should the keychain item require authentication to be accessed
        let authenticationRequired: Bool
        /// bind the current biometrics to keychain item, if biometric changes keychain item will be invalidated permanently.
        let biometryCurrentSetOnly: Bool
        /// optional string to show user for auth prompt, used if ``authenticationRequired`` is true
        let authenticationPrompt: String?

        init(
            service: String? = nil,
            accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            useSecureEnclave: Bool = true,
            accessGroup: String? = nil,
            authenticationRequired: Bool = false,
            biometryCurrentSetOnly: Bool = true,
            authenticationPrompt: String? = nil
        ) {
            self.service = service
            self.accessibility = accessibility
            self.useSecureEnclave = useSecureEnclave
            self.accessGroup = accessGroup
            self.authenticationRequired = authenticationRequired
            self.biometryCurrentSetOnly = biometryCurrentSetOnly
            self.authenticationPrompt = authenticationPrompt
        }
    }

    enum SecureStorageError: Error {
        case invalidTag
        case cannotExportPublicKey
        case accessControlFailed
        case keyGenerationFailed
        case encryptionFailed
        case decryptionFailed
        case invalidDataFormat
        case itemAlreadyExists
        case notFound
        case authCancelled
        case authFailed
        case interactionNotAllowed
        case underlying(OSStatus)
    }

    /// Check if an item exists under the given alias.
    static func exists(key: String, options: StorageOptions = .init()) -> Bool {
        serialQueue.sync {
            var query = baseQuery(key: key, options: options)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = false
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Save data. If useSecureEnclave = true, data is encrypted before storage.
    static func save(key: String, data: Data, options: StorageOptions = .init()) -> Result<Void, Error> {
        serialQueue.sync {
            var dataToStore = data

            if options.useSecureEnclave {
                switch ensureEnclaveKeyPair(service: options.service) {
                case .success(let (_, publicKey)):
                    switch encrypt(data, with: publicKey) {
                    case .success(let encrypted): dataToStore = encrypted
                    case .failure(let e): return .failure(e)
                    }
                case .failure(let e):
                    return .failure(e)
                }
            }

            var query = baseQuery(key: key, options: options)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = dataToStore

            if options.authenticationRequired {
                let flags: SecAccessControlCreateFlags =
                    options.biometryCurrentSetOnly ? .biometryCurrentSet : .userPresence
                var acError: Unmanaged<CFError>?
                guard let acl = SecAccessControlCreateWithFlags(nil, options.accessibility, flags, &acError) else {
                    return .failure(acError?.takeRetainedValue() ?? SecureStorageError.accessControlFailed)
                }
                query[kSecAttrAccessControl as String] = acl
            } else {
                query[kSecAttrAccessible as String] = options.accessibility
            }

            let status = SecItemAdd(query as CFDictionary, nil)

            switch status {
            case errSecSuccess: return .success(())
            case errSecDuplicateItem: return .failure(SecureStorageError.itemAlreadyExists)
            default: return .failure(SecureStorageError.underlying(status))
            }
        }
    }

    /// Fetch data. If encrypted with Secure Enclave, automatically decrypts.
    static func fetch(key: String, options: StorageOptions = .init()) -> Result<Data?, Error> {
        serialQueue.sync {
            var query = baseQuery(key: key, options: options)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true

            if let prompt = options.authenticationPrompt {
                let context = LAContext()
                context.localizedReason = prompt
                query[kSecUseAuthenticationContext as String] = context
            }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            guard status != errSecItemNotFound else { return .success(nil) }
            guard status == errSecSuccess else {
                switch status {
                case errSecUserCanceled: return .failure(SecureStorageError.authCancelled)
                case errSecAuthFailed: return .failure(SecureStorageError.authFailed)
                case errSecInteractionNotAllowed: return .failure(SecureStorageError.interactionNotAllowed)
                default: return .failure(SecureStorageError.underlying(status))
                }
            }

            guard var data = item as? Data else {
                return .failure(SecureStorageError.invalidDataFormat)
            }

            defer { zeroize(&data) }

            if options.useSecureEnclave {
                switch ensureEnclaveKeyPair(service: options.service) {
                case .success(let (privateKey, _)):
                    switch decrypt(data, with: privateKey) {
                    case .success(let plaintext):
                        var mutable = plaintext
                        defer { zeroize(&mutable) }
                        return .success(plaintext)
                    case .failure(let e): return .failure(e)
                    }
                case .failure(let e): return .failure(e)
                }
            }

            return .success(data)
        }
    }

    static func delete(key: String, options: StorageOptions = .init()) -> Result<Void, Error> {
        serialQueue.sync {
            let query = baseQuery(key: key, options: options)
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return .success(())
            }
            return .failure(SecureStorageError.underlying(status))
        }
    }

    static func deleteAllKeychainItems() -> Result<Void, Error> {
        serialQueue.sync {
            let classes = [
                kSecClassGenericPassword,
                kSecClassInternetPassword,
                kSecClassCertificate,
                kSecClassKey,
                kSecClassIdentity,
            ]

            var lastError: OSStatus = errSecSuccess

            for itemClass in classes {
                let query: [String: Any] = [
                    kSecClass as String: itemClass,
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                ]

                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    lastError = status
                    NSLog("SecureStorage: deleteAll failed for class \(itemClass): \(status)")
                }
            }

            if lastError == errSecSuccess || lastError == errSecItemNotFound {
                return .success(())
            }
            return .failure(SecureStorageError.underlying(lastError))
        }
    }

    // MARK: - Helpers

    private static func baseQuery(key: String, options: StorageOptions) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            // No icloud sync
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        if let service = options.service {
            query[kSecAttrService as String] = service
        }
        if let group = options.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        #if os(macOS)
            if #available(macOS 10.15, *) {
                query[kSecUseDataProtectionKeychain as String] = true
            }
        #endif

        return query
    }

    private static func zeroize(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: ptr.count)
        }
    }
}
