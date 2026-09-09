package com.lightning.manna

import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.os.Bundle
import android.view.WindowManager
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.lightning.secure_storage.SecureStoragePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset

class MainActivity : FlutterFragmentActivity() {

    companion object {
        var isForeground: Boolean = false
        var pendingNotificationData: HashMap<String, Any>? = null

        var initialNfcData: String? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(SecureStoragePlugin())
        flutterEngine.plugins.add(NotificationPlugin())
        initNFCHCEPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLogger.init(this)

        handleNotificationIntent(intent)
        handleNfcIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
        handleNfcIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        isForeground = true
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onPause() {
        super.onPause()
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun onStop() {
        super.onStop()
        isForeground = false
    }

    fun initNFCHCEPlugin(binaryMessenger: BinaryMessenger) {
        val methodChannel = MethodChannel(binaryMessenger, "com.lightning.manna/nfc")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialNFCData" -> {
                    result.success(initialNfcData)
                }

                "startNFC_HCE" -> {
                    val uri = call.argument<String>("uri")
                        ?: return@setMethodCallHandler result.error("INVALID", "No uri", null)

                    val adapter = NfcAdapter.getDefaultAdapter(this)
                    if (adapter?.isEnabled == true && packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)) {
                        val intent = Intent(this@MainActivity, KHostApduService::class.java)
                        intent.putExtra("ndefURI", uri)
                        startService(intent)
                        return@setMethodCallHandler result.success(true)
                    }

                    result.success(false)
                }

                "stopNFC_HCE" -> {
                    val intent = Intent(this@MainActivity, KHostApduService::class.java)
                    val stopped = stopService(intent)
                    result.success(stopped)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val notificationData = intent?.getStringExtra("notification_data") ?: return

        try {
            val dataMap = Gson().fromJson(
                notificationData,
                object : TypeToken<HashMap<String, Any>>() {}.type
            ) as? HashMap<String, Any>
            dataMap?.let { data ->
                intent.removeExtra("notification_data")

                val plugin = NotificationPlugin.getPlugin()

                if (plugin != null && isForeground) {
                    plugin.invokeMethod("onNotificationClicked", data)
                    AppLogger.logI("Invoked onNotificationClicked with $data")
                } else {
                    pendingNotificationData = data
                    AppLogger.logI("Stored $data as pendingNotificationData")
                }
            }
        } catch (e: Exception) {
            AppLogger.logE("Failed to parse notification data ${e.message}")
        }
    }


    private fun handleNfcIntent(intent: Intent?) {
        if (NfcAdapter.ACTION_NDEF_DISCOVERED == intent?.action) {
            val rawMessages = intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
            if (rawMessages != null) {
                val messages = arrayOfNulls<NdefMessage>(rawMessages.size)
                for (i in rawMessages.indices) {
                    messages[i] = rawMessages[i] as NdefMessage
                }

                val record = messages[0]?.records?.get(0) ?: return
                val payload = record.payload

                val statusByte = payload[0].toInt()
                val languageCodeLength = statusByte and 0x3F
                val textEncoding =
                    if ((statusByte and 0x80) == 0) Charset.forName("UTF-8") else Charset.forName("UTF-16")

                initialNfcData = String(
                    payload,
                    1 + languageCodeLength,
                    payload.size - 1 - languageCodeLength,
                    textEncoding
                )
                AppLogger.logI("Stored $initialNfcData as initialNfcData")
            }
        }
    }

}
