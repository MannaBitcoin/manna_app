package com.lightning.secure_storage

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class SecureStoragePlugin : FlutterPlugin {
    private val channelName = "com.lightning.manna/secure_storage"
    private lateinit var secureStorage: SecureStorage
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            if (call.method != "init" && !isInitialized()) {
                result.error(
                    "bad_state",
                    "Secure storage is not initialized, call init first",
                    null
                )
                return@setMethodCallHandler
            }
            when (call.method) {
                "init" -> handleInit(binding.applicationContext, call, result)
                "store" -> handleStore(call, result)
                "fetch" -> handleFetch(call, result)
                "delete" -> handleDelete(call, result)
                "exists" -> handleExists(call, result)
                "deleteKey" -> handleDeleteKey(call, result)
                "isStrongBoxAvailable" -> handleIsStrongBoxAvailable(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(p0: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun isInitialized(): Boolean {
        return ::secureStorage.isInitialized
    }

    private fun handleInit(context: Context, call: MethodCall, result: Result) {
        if (!isInitialized()) {
            val accessModeStr = call.argument<String>("accessMode")
                ?: return result.error("bad_args", "Missing accessMode.", null)
            val accessMode = runCatching { AccessMode.valueOf(accessModeStr) }.getOrNull()
                ?: return result.error(
                    "bad_args",
                    "Invalid accessMode string.",
                    "Possible values are ${AccessMode.entries.map { it.name }}"
                )
            val version = call.argument<Int>("version")
            val prefix = call.argument<String>("prefix")
            val unlockedDeviceRequired = call.argument<Boolean>("unlockedDeviceRequired")
            val strongBox = call.argument<Boolean>("strongBox")
            val userAuthenticationRequired = call.argument<Boolean>("userAuthenticationRequired")
            val invalidatedByBiometricEnrollment =
                call.argument<Boolean>("invalidatedByBiometricEnrollment")

            secureStorage = SecureStorage(
                context,
                accessMode,
                version,
                prefix,
                unlockedDeviceRequired,
                strongBox,
                userAuthenticationRequired,
                invalidatedByBiometricEnrollment
            )
            result.success(null)
        } else {
            result.success(null)
        }
    }

    private fun handleStore(call: MethodCall, result: Result) {
        val key = call.argument<String>("key")
            ?: return result.error("bad_args", "Missing key.", null)
        val value = call.argument<ByteArray>("value")
            ?: return result.error("bad_args", "Missing value.", null)
        try {
            secureStorage.store(key, value)
            result.success(true)
        } catch (e: Exception) {
            result.error("store_failed", e.message ?: e.toString(), null)
        }
    }

    private fun handleFetch(call: MethodCall, result: Result) {
        val key = call.argument<String>("key")
            ?: return result.error("bad_args", "Missing key.", null)
        try {
            result.success(secureStorage.fetch(key))
        } catch (e: Exception) {
            result.error("fetch_failed", e.message ?: e.toString(), null)
        }
    }

    private fun handleDelete(call: MethodCall, result: Result) {
        val key = call.argument<String>("key")
            ?: return result.error("bad_args", "Missing key.", null)
        try {
            secureStorage.delete(key)
            result.success(true)
        } catch (e: Exception) {
            result.error("delete_failed", e.message ?: e.toString(), null)
        }
    }

    private fun handleExists(call: MethodCall, result: Result) {
        val key = call.argument<String>("key")
            ?: return result.error("bad_args", "Missing key.", null)
        try {
            result.success(secureStorage.exists(key))
        } catch (e: Exception) {
            result.error("exists_failed", e.message ?: e.toString(), null)
        }
    }

    private fun handleDeleteKey(call: MethodCall, result: Result) {
        val alias = call.argument<String>("alias")
            ?: return result.error("bad_args", "Missing alias.", null)

        try {
            secureStorage.deleteKey(alias)
            result.success(null)
        } catch (e: Exception) {
            result.error("delete_entry_failed", e.message ?: e.toString(), null)
        }
    }

    private fun handleIsStrongBoxAvailable(result: Result) {
        try {
            result.success(secureStorage.isStrongBoxSupported())
        } catch (e: Exception) {
            result.error("is_strongbox_available_failed", e.message ?: e.toString(), null)
        }
    }
}
