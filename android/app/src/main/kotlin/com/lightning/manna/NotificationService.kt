package com.lightning.manna

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import androidx.core.graphics.scale
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.google.gson.Gson
import com.lightning.secure_storage.AccessMode
import com.lightning.secure_storage.SecureStorage
import uniffi.manna_core.NotificationInfo
import uniffi.manna_core.NseException
import uniffi.manna_core.handleNotification
import java.io.File
import java.net.URL
import java.util.concurrent.Executors

const val TAG = "NotificationService"

class NotificationService : FirebaseMessagingService() {
    companion object {
        fun getNotificationManager(context: Context): NotificationManager {
            return context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        }

        private fun createNotificationChannel(
            context: Context,
            id: String,
            name: String,
            importance: Int = NotificationManager.IMPORTANCE_DEFAULT,
            channelDescription: String? = null
        ) {
            if (getNotificationManager(context).notificationChannels.any { it.id == id }) return

            val channel = NotificationChannel(id, name, importance).apply {
                description = channelDescription
                enableLights(true)
                enableVibration(true)
            }
            getNotificationManager(context).createNotificationChannel(channel)
        }

        fun createNotificationChannels(context: Context) {
            createNotificationChannel(context, "manna", "Manna general notifications")
            createNotificationChannel(
                context, "received_tx", "Received Transactions",
                NotificationManager.IMPORTANCE_MAX
            )
            createNotificationChannel(
                context, "swap_info", "Swap updates",
                NotificationManager.IMPORTANCE_MAX
            )
            createNotificationChannel(
                context,
                "manna_chat_messages",
                "Chat messages",
                NotificationManager.IMPORTANCE_HIGH,
                "Channel for chat message notifications"
            )
        }


        fun generateNotificationId(threadId: String? = null): Int {
            return threadId?.hashCode() ?: System.currentTimeMillis().toInt()
        }

        fun showNativeNotification(
            context: Context,
            title: String? = null,
            body: String? = null,
            notificationId: Int = generateNotificationId(),
            channelId: String = "manna",
            data: Map<String, String>? = null,

            style: NotificationCompat.Style? = null,
            groupId: String? = null
        ) {
            val title = title ?: data?.get("title") ?: "Notification"
            val body = body ?: data?.get("body") ?: ""

            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (data != null) {
                    putExtra("notification_data", Gson().toJson(data))
                }
            }

            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notificationBuilder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.drawable.logo_white)
                .setContentTitle(title)
                .setContentText(body)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)

                .setStyle(style)
                .setGroup(groupId)

            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                getNotificationManager(context).notify(notificationId, notificationBuilder.build())
            }
        }
    }

    override fun onNewToken(token: String) {
    }

    override fun onMessageReceived(message: RemoteMessage) {
        try {
            AppLogger.init(applicationContext)

            createNotificationChannels(applicationContext)

            val type = message.data["type"]
            if (type == "new_message_chat") {
                val senderId = message.data["senderId"]
                val activeChatUUID = NotificationPlugin.getActiveChatUUID(applicationContext)
                if ((senderId != null && activeChatUUID != null && senderId == activeChatUUID)) {
                    return
                }
            } else if (type == "bolt12") {
                // do nothing, let rust handle it
            } else if (MainActivity.isForeground) {
                val data = HashMap(message.data)
                message.notification?.title?.let { data["title"] = it }
                message.notification?.body?.let { data["body"] = it }
                message.messageId?.let { data["messageId"] = it }
                message.from?.let { data["from"] = it }
                message.senderId?.let { data["senderId"] = it }
                message.sentTime.let { data["sentTime"] = it.toString() }
                message.ttl.let { data["ttl"] = it.toString() }
                message.collapseKey?.let { data["collapseKey"] = it }
                message.messageType?.let { data["messageType"] = it }
                message.priority.let { data["priority"] = it.toString() }
                message.originalPriority.let { data["originalPriority"] = it.toString() }

                NotificationPlugin.getPlugin()
                    ?.invokeMethod("onForegroundMessage", data)
                return
            }


            // process notification on rust
            val appDirPath = applicationContext.filesDir.absolutePath
            val secureStorage = SecureStorage(
                applicationContext,
                AccessMode.evenLocked,
                useStrongBox = false
            )

            val filePassword = secureStorage.fetch("sharedFilePassword")
                ?: throw Exception("Missing filePassword")
            val tokens =
                (0..2).map {
                    secureStorage.fetch("supabase_jwt_$it")?.toString(Charsets.UTF_8) ?: ""
                }.toList()

            val notificationData = Gson().toJson(
                message.data.minus(
                    arrayOf(
                        "google.c.fid",
                        "gcm.message_id",
                        "google.c.sender.id",
                        "google.c.a.e",
                        "aps"
                    )
                )
            )
            AppLogger.logI("starting rust handler: $notificationData")

            // Call Rust
            val result = handleNotification(
                appDirPath,
                AppLogger.logDir.absolutePath,
                notificationData,
                filePassword,
                tokens,
            )
            AppLogger.logI("Rust handler result: $result")

            // Apply Rust results safely
            handleRustResult(result, message, appDirPath)
        } catch (e: Exception) {
            AppLogger.logE("Error processing notification :${e.message}", TAG)
            showNativeNotification(
                this,
                title = message.notification?.title,
                body = message.notification?.body,
                data = message.data
            )
        }
    }

    private fun handleRustResult(
        notifications: List<NotificationInfo>,
        message: RemoteMessage,
        storageDir: String
    ) {
        if (notifications.isEmpty()) return

        if (message.data["type"] == "new_message_chat") {
            val res = notifications.first()
            val senderName = res.title ?: return
            val body = res.body ?: return
            val threadId = res.threadId ?: return

            // Fetch avatar async
            val executor = Executors.newSingleThreadExecutor()
            val handler = Handler(Looper.getMainLooper())
            executor.execute {
                val avatarIcon = fetchAvatar(res.senderPicture, threadId, storageDir)?.let {
                    IconCompat.createWithAdaptiveBitmap(
                        it.scale(256, 256)
                    )
                }

                handler.post {
                    val senderPerson = Person.Builder()
                        .setName(senderName)
                        .setIcon(avatarIcon)
                        .setKey(threadId)
                        .setImportant(true)
                        .build()

                    val messageStyle = NotificationCompat.MessagingStyle(senderPerson)

                    val activeNotifications =
                        getNotificationManager(applicationContext).activeNotifications
                    val existingStyle = activeNotifications
                        .find { it.id == generateNotificationId(threadId) }
                        ?.notification?.let {
                            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(
                                it
                            )
                        }
                    existingStyle?.messages?.forEach {
                        messageStyle.addMessage(it)
                    }

                    messageStyle.addMessage(body, System.currentTimeMillis(), senderPerson)
                        .setGroupConversation(false)
                        .setConversationTitle(null)

                    showNativeNotification(
                        this,
                        notificationId = generateNotificationId(threadId),
                        channelId = "manna_chat_messages",
                        style = messageStyle,
                        groupId = threadId,
                        data = getPayloadJson(message, res)
                    )
                }
            }
        } else {
            for (notification in notifications) {
                if (notification.title != null) {
                    showNativeNotification(
                        this,
                        title = notification.title,
                        body = notification.body,
                        groupId = notification.threadId,
                        channelId = if (message.data["type"] == "received_tx")
                            "received_tx"
                        else if (message.data["type"] == "swap_webhook" || message.data["type"] == "lnurl")
                            "swap_info"
                        else
                            "manna",
                        data = getPayloadJson(message, notification)
                    )
                }
            }
        }
    }

    private fun getPayloadJson(
        message: RemoteMessage,
        res: NotificationInfo
    ): HashMap<String, String> {
        val data: HashMap<String, String> = HashMap()
        message.data.forEach { data[it.key] = it.value }
        if (res.payload != null) {
            val payloadData = Gson().fromJson(res.payload, Map::class.java)
            payloadData.keys.forEach {
                data[it as String] = payloadData[it].toString()
            }
        }
        return data
    }

    private fun fetchAvatar(urlString: String?, threadId: String, appDirPath: String): Bitmap? {
        if (urlString.isNullOrBlank()) return null

        try {
            val avatarsDir = File(appDirPath, "avatars").apply { mkdirs() }
            val avatarFile = File(avatarsDir, "${threadId}_${urlString.hashCode()}.jpg")

            if (avatarFile.exists() && avatarFile.length() > 0) {
                val bitmap = BitmapFactory.decodeFile(avatarFile.absolutePath)
                if (bitmap != null) return bitmap
            }

            val connection = URL(urlString).openConnection()
            connection.connectTimeout = 5000
            connection.readTimeout = 5000

            val bytes = connection.getInputStream().use { it.readBytes() }

            if (bytes.isNotEmpty()) {
                avatarFile.writeBytes(bytes)
                return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }
        } catch (e: Exception) {
            AppLogger.logE("Error fetching avatar :${e.message}", TAG)
        }
        return null
    }
}