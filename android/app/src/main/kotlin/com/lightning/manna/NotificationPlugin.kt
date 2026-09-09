package com.lightning.manna

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class NotificationPlugin : FlutterPlugin, ActivityAware {
    private val channelName = "com.lightning.manna/notifications"
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var context: Context? = null

    companion object {
        private var pluginInstance = WeakReference<NotificationPlugin>(null)

        @JvmStatic
        fun getPlugin(): NotificationPlugin? {
            return pluginInstance.get()
        }

        fun getActiveChatUUID(context: Context): String? {
            return context.getSharedPreferences("Prefs", Context.MODE_PRIVATE)
                .getString("activeChatUUID", null)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginInstance = WeakReference(this)
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> isPermissionGranted(result)
                "showNotification" -> handleShowNotification(call, result)
                "cancelNotification" -> cancelNotification(call, result)
                "getActiveNotifications" -> getActiveNotifications(result)
                "setActiveChatUUID" -> setActiveChatUUID(call, result)
                "getFCMToken" -> handleGetFcmToken(result)
                "getInitialClickedNotification" -> {
                    if (MainActivity.pendingNotificationData != null) {
                        result.success(MainActivity.pendingNotificationData)
                        MainActivity.pendingNotificationData = null
                    } else {
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }
        NotificationService.createNotificationChannels(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        pluginInstance.clear()
    }

    private fun isPermissionGranted(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        val granted = (activity ?: context)?.let {
            ContextCompat.checkSelfPermission(
                it,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }
        result.success(granted)
    }

    private fun handleShowNotification(call: MethodCall, result: MethodChannel.Result) {
        try {
            val ctx = context
            if (ctx == null) {
                result.error("INVALID_STATE", "Context is null", null)
                return
            }

            val title = call.argument<String>("title")
            val body = call.argument<String>("body")
            val dataMap = call.argument<Map<String, String>>("data") ?: emptyMap()
            val channelId = call.argument<String>("channelId") ?: "manna"
            val groupId = call.argument<String>("groupId")
            val notificationId =
                call.argument<Int>("notificationId") ?: NotificationService.generateNotificationId()

            NotificationService.showNativeNotification(
                ctx,
                title = title,
                body = body,
                notificationId = notificationId,
                channelId = channelId,
                data = dataMap,
                groupId = groupId
            )

            result.success(true)
        } catch (e: Exception) {
            result.error("SHOW_NOTIFICATION_ERROR", e.message, null)
            AppLogger.logE("Error showing notification :${e.message}")
        }
    }

    private fun cancelNotification(call: MethodCall, result: MethodChannel.Result) {
        try {
            val notificationId = call.argument<String>("notificationId")

            val ctx = context
            if (ctx == null) {
                result.error("INVALID_STATE", "Context is null", null)
                return
            }

            val notificationManager = NotificationService.getNotificationManager(ctx)
            if (notificationId != null) {
                notificationManager.cancel(
                    notificationId.toIntOrNull() ?: notificationId.hashCode()
                )
            } else {
                notificationManager.cancelAll()
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("CANCEL_ERROR", e.message, null)
            AppLogger.logE("Error cancelling notification :${e.message}")
        }
    }

    private fun getActiveNotifications(result: MethodChannel.Result) {
        try {
            val ctx = context
            if (ctx == null) {
                result.error("INVALID_STATE", "Context is null", null)
                return
            }

            val notificationManager = NotificationService.getNotificationManager(ctx)

            val activeNotifications = notificationManager.activeNotifications
            val list = activeNotifications.map { noti ->
                val extras = noti.notification.extras

                mapOf<String, Any>(
                    "id" to noti.id,
                    "title" to (extras.getString(Notification.EXTRA_TITLE) ?: ""),
                    "body" to (extras.getString(Notification.EXTRA_TEXT) ?: ""),
                    "channelId" to (noti.notification.channelId ?: "manna"),
                    "groupId" to noti.groupKey,
                    "data" to (extras.getString("notification_data")?.let { json ->
                        try {
                            Gson().fromJson(
                                json,
                                object : TypeToken<HashMap<String, Any>>() {}.type
                            )
                        } catch (_: Exception) {
                            emptyMap<String, Any>()
                        }
                    } ?: emptyMap()),
                    "timestamp" to noti.notification.`when`
                )
            }

            result.success(list)
        } catch (e: Exception) {
            result.error("GET_ACTIVE_NOTIFICATIONS_ERROR", e.message, null)
            AppLogger.logE("Error getting active notifications :${e.message}")
        }
    }

    private fun setActiveChatUUID(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("INVALID_STATE", "Context is null", null)
            return
        }

        val uuid = call.argument<String>("uuid")
        val sharedPref = ctx.getSharedPreferences("Prefs", Context.MODE_PRIVATE)
        sharedPref.edit {
            if (uuid != null) putString("activeChatUUID", uuid) else remove("activeChatUUID")
        }
        result.success(null)
    }

    private fun handleGetFcmToken(result: MethodChannel.Result) {
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            if (task.isSuccessful) {
                result.success(task.result)
            } else {
                AppLogger.logE("Error fetching fcm token :${task.exception}")
                result.success(null)
            }
        }
    }

    fun invokeMethod(method: String, arguments: Any?) {
        activity?.runOnUiThread {
            channel?.invokeMethod(method, arguments)
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        this.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        this.activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        this.activity = null
    }
}