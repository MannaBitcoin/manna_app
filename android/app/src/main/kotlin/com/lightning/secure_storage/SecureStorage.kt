package com.lightning.secure_storage

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import androidx.core.content.edit
import java.security.KeyStore
import javax.crypto.SecretKey


enum class AccessMode(val alias: String) {
    evenLocked("secure_storage_even_locked"),
    onlyUnlocked("secure_storage_only_unlocked"),
    authenticated("secure_storage_authenticated"),

    /** if biometric enrollment changes — the secret becomes irrecoverable.*/
    authenticatedFatal("secure_storage_authenticated_fatal"),
}

class SecureStorage(
    val context: Context,
    val accessMode: AccessMode,
    version: Int? = null,
    prefix: String? = null,
    unlockedDeviceRequired: Boolean? = null,
    useStrongBox: Boolean? = null,
    userAuthenticationRequired: Boolean? = null,
    invalidatedByBiometricEnrollment: Boolean? = null,
) {
    private val version = version ?: SchemeRegistry.CURRENT_VERSION
    private val prefix = prefix ?: "manna"
    private val keyStoreType = "AndroidKeyStore"
    private val prefs: SharedPreferences =
        context.getSharedPreferences("secure_storage", Context.MODE_PRIVATE)

    init {
        if (!containsKey()) {
            val scheme =
                SchemeRegistry.schemeFor(this.version) ?: throw Exception("Invalid version")
            scheme.generateKey(
                accessMode.alias,
                unlockedDeviceRequired ?: false,
                (useStrongBox ?: false) && isStrongBoxSupported(),
                userAuthenticationRequired ?: false,
                invalidatedByBiometricEnrollment ?: false
            )
        }
    }

    fun containsKey(): Boolean {
        return getKey(accessMode.alias) != null
    }

    fun deleteKey(alias: String) {
        val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }

        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
        prefs.edit { clear() }
    }

    fun store(key: String, value: ByteArray) {
        val scheme = SchemeRegistry.schemeFor(version) ?: throw Exception("Invalid version")

        val storeKey = "$prefix-$key"
        val res = scheme.encrypt(accessMode.alias, value, storeKey)
        prefs.edit { putString(storeKey, res.toJson()) }
    }

    fun fetch(key: String): ByteArray? {
        val scheme = SchemeRegistry.schemeFor(version) ?: throw Exception("Invalid version")

        val storeKey = "$prefix-$key"
        val payloadStr = prefs.getString(storeKey, null) ?: return null
        val encryptedData = EncryptResult.fromJson(payloadStr)

        return scheme.decrypt(
            accessMode.alias,
            encryptedData.ciphertext,
            encryptedData.nonce,
            storeKey
        )
    }

    fun delete(key: String) {
        val storeKey = "$prefix-$key"
        prefs.edit { remove(storeKey) }
    }

    fun exists(key: String): Boolean {
        val storeKey = "$prefix-$key"
        return prefs.contains(storeKey)
    }

    fun isStrongBoxSupported(): Boolean {
        return context.packageManager
            .hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
    }

    private fun getKey(alias: String): SecretKey? {
        val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }
        return keyStore.getKey(alias, null) as? SecretKey
    }
}