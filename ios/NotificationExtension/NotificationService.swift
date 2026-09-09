//
//  NotificationService.swift
//  NotificationExtension
//
//  Created by Manna dev on 18/12/25.
//

import Foundation
import Intents
import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private let appGroupIdentifier = "group.com.lightning.manna"

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler:
            @escaping (UNNotificationContent) -> Void
    ) {
        let shared = UserDefaults(suiteName: appGroupIdentifier)
        let isAppForeground = shared?.bool(forKey: "is_foreground") ?? false
        let activeChatUUID = shared?.string(forKey: "activeChatUUID") ?? ""
        let notificationType = request.content.userInfo["type"] as? String

        if notificationType == nil {
            contentHandler(request.content)
            return
        }

        // Skip processing here; let the main app do it
        if notificationType == "new_message_chat" {
            if let senderId = request.content.userInfo["senderId"] as? String {
                if senderId == activeChatUUID {
                    contentHandler(request.content)
                    return
                }
            }
        } else if notificationType == "bolt12" {
            // do nothing, let rust handle it
        } else if isAppForeground {
            contentHandler(request.content)
            return
        }

        self.contentHandler = contentHandler
        self.bestAttemptContent =
            (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else { return }

        do {
            // Prepare data for rust
            var userInfo = content.userInfo
            let keysToTrim = ["google.c.fid", "gcm.message_id", "google.c.sender.id", "google.c.a.e", "aps"]
            for key in keysToTrim {
                userInfo.removeValue(forKey: key)
            }

            let notificationData =
                (try? JSONSerialization.data(withJSONObject: userInfo))
                ?? Data()
            let notificationDataStr =
                String(data: notificationData, encoding: .utf8) ?? "{}"

            let fileManager = FileManager.default
            let appGroupDir = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )

            // fetch token
            let secureStorageOptions = SecureStorage.StorageOptions.init(
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                useSecureEnclave: false,
                accessGroup: appGroupIdentifier
            )
            guard
                let filePassword = try SecureStorage.fetch(
                    key: "sharedFilePassword",
                    options: secureStorageOptions
                ).get()
            else {
                throw NSError(
                    domain: "NSE",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Missing File password to decrypt"
                    ]
                )
            }

            let tokens: [String] = [0, 1, 2].map { index in
                let result = SecureStorage.fetch(key: "supabase_jwt_\(index)", options: secureStorageOptions)

                if let data = try? result.get(),
                    let token = String(data: data, encoding: .utf8)
                {
                    return token
                }

                return ""
            }

            // call rust processor
            guard let appGroupPath = appGroupDir?.path, let logDirPath = AppLogger.shared.logDir?.path
            else {
                throw NSError(
                    domain: "NSE",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to access appGroup Directory"
                    ]
                )
            }

            AppLogger.shared.logI("starting rust handler: \(notificationDataStr)")

            let result = try handleNotification(
                appGroupDirPath: appGroupPath,
                logDirPath: logDirPath,
                payloadJsonStr: notificationDataStr,
                filePassword: filePassword,
                jwtTokens: tokens,
            )

            if let jsonData = try? JSONSerialization.data(withJSONObject: result.map { $0.dictionaryRepresentation }),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                AppLogger.shared.logI("Rust handler result: \(jsonString)")
            }

            if result.isEmpty {
                // TODO implement filtering
                content.title = "Background processing..."
                content.body = "Ignore"
                content.threadIdentifier = "ignore"
                contentHandler(content)
                return
            }

            // Apply Rust results safely
            updateContent(with: result)

            // Handle Chat UI (Communication Notifications)
            if userInfo["type"] as? String == "new_message_chat" && !result.isEmpty {
                applyCommunicationIntent(
                    result: result.first!,
                    appGroupDir: appGroupDir
                ) { updatedContent in
                    self.contentHandler?(updatedContent)
                }
                return
            }
        } catch {
            AppLogger.shared.logE("\(error)", tag: "NSE")
            content.title = "Notification Processing failed"
            content.body = "Please open the app to resolve."
        }

        contentHandler(content)
    }

    private func updateContent(with result: [NotificationInfo]) {
        guard let content = bestAttemptContent else { return }

        for (i, notification) in result.enumerated() {
            if i == 0 {
                // update current notification of NSE
                if let title = notification.title { content.title = title }
                if let body = notification.body { content.body = body }
                if let threadId = notification.threadId {
                    content.threadIdentifier = threadId
                }

                // Merge Payload
                if let payload = notification.payload,
                    let jsonData = payload.data(using: .utf8),
                    let newFields = try? JSONSerialization.jsonObject(with: jsonData)
                        as? [AnyHashable: Any]
                {
                    var existingUserInfo = content.userInfo
                    newFields.forEach { existingUserInfo[$0.key] = $0.value }
                    content.userInfo = existingUserInfo
                }
            } else {
                // extra notifications
                let content = UNMutableNotificationContent()
                if let title = notification.title { content.title = title }
                if let body = notification.body { content.body = body }
                if let threadId = notification.threadId {
                    content.threadIdentifier = threadId
                }

                if let payload = notification.payload,
                    let jsonData = payload.data(using: .utf8),
                    let newFields = try? JSONSerialization.jsonObject(with: jsonData)
                        as? [AnyHashable: Any]
                {
                    content.userInfo = [
                        "isLocalNotification": true
                    ]
                    content.userInfo.merge(newFields) { (current, new) in new }
                }

                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                )
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func applyCommunicationIntent(
        result: NotificationInfo,
        appGroupDir: URL?,
        completion: @escaping (UNNotificationContent) -> Void
    ) {
        let content = bestAttemptContent ?? UNMutableNotificationContent()
        guard let senderName = result.title, let message = result.body,
            let threadId = result.threadId
        else {
            completion(content)
            return
        }

        fetchAvatar(
            urlString: result.senderPicture,
            threadId: threadId,
            appGroupDir: appGroupDir
        ) { avatarImage in
            let sender = INPerson(
                personHandle: INPersonHandle(value: threadId, type: .unknown),
                nameComponents: nil,
                displayName: senderName,
                image: avatarImage,
                contactIdentifier: nil,
                customIdentifier: threadId
            )

            let intent = INSendMessageIntent(
                recipients: nil,
                outgoingMessageType: .outgoingMessageText,
                content: message,
                speakableGroupName: nil,
                conversationIdentifier: threadId,
                serviceName: nil,
                sender: sender,
                attachments: nil
            )

            if let avatarImage = avatarImage {
                intent.setImage(avatarImage, forParameterNamed: \.sender)
            }

            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)

            do {
                let updatedContent = try content.updating(from: intent)
                completion(updatedContent)
            } catch {
                completion(content)
            }
        }
    }

    private func fetchAvatar(
        urlString: String?,
        threadId: String,
        appGroupDir: URL?,
        completion: @escaping (INImage?) -> Void
    ) {
        guard let urlString = urlString, let url = URL(string: urlString),
            let appGroupDir = appGroupDir
        else {
            completion(nil)
            return
        }

        let avatarsDir = appGroupDir.appendingPathComponent(
            "avatars",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: avatarsDir,
            withIntermediateDirectories: true
        )
        let avatarFileURL = avatarsDir.appendingPathComponent(
            "\(threadId)_\(urlString.hashValue).jpg"
        )

        if let cachedData = try? Data(contentsOf: avatarFileURL) {
            completion(INImage(imageData: cachedData))
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data {
                try? data.write(to: avatarFileURL)
                completion(INImage(imageData: data))
            } else {
                completion(nil)
            }
        }
        task.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler,
            let bestAttemptContent = bestAttemptContent
        {
            contentHandler(bestAttemptContent)
        }
    }
}

extension NotificationInfo {
    var dictionaryRepresentation: [String: Any] {
        let mirror = Mirror(reflecting: self)
        var dict = [String: Any]()

        for child in mirror.children {
            guard let key = child.label else { continue }

            // Unwraps the Optional to see if it actually contains a value
            let value = child.value
            let mirrorOfValue = Mirror(reflecting: value)

            if mirrorOfValue.displayStyle == .optional {
                if mirrorOfValue.children.count > 0 {
                    if let actualValue = mirrorOfValue.children.first?.value {
                        dict[key] = actualValue
                    }
                }
            } else {
                dict[key] = value
            }
        }
        return dict
    }
}
