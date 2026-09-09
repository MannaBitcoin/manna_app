package com.lightning.manna

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileWriter
import java.time.Clock
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset


object AppLogger {
    private const val APP_TAG = "Manna"
    lateinit var logDir: File

    fun init(context: Context) {
        logDir = File(context.filesDir, "logs")
        if (!logDir.exists()) logDir.mkdirs()
    }

    fun logD(message: String, tag: String? = null) = log(LogType.DEBUG, message, tag)
    fun logI(message: String, tag: String? = null) = log(LogType.INFO, message, tag)
    fun logW(message: String, tag: String? = null) = log(LogType.WARNING, message, tag)
    fun logE(message: String, tag: String? = null) = log(LogType.ERROR, message, tag)
    fun logF(message: String, tag: String? = null) = log(LogType.FATAL, message, tag)

    private fun log(
        level: LogType,
        message: String,
        tag: String?,
    ) {
        val entry = JSONObject().apply {
            put("ts", OffsetDateTime.now(ZoneOffset.UTC).toString())
            put("lvl", level)
            put("msg", message)
            put("tag", tag ?: "")
        }

        val stackTraceString = Thread.currentThread().stackTrace
            .drop(5)
            .joinToString("\n") { it.toString() }
        if (level == LogType.ERROR || level == LogType.FATAL) {
            entry.put("stack", stackTraceString)
        }

        try {
            val logFile = File(logDir, "android.jsonl")
            FileWriter(logFile, true).use { writer ->
                writer.append(entry.toString())
                writer.append("\n")
            }
        } catch (e: Exception) {
            Log.e(APP_TAG, "Failed to write log to file", e)
        }

        val logTag = tag ?: ""
        val fullMessage = "$level | $logTag | $message"

        when (level) {
            LogType.DEBUG -> Log.d(APP_TAG, fullMessage)
            LogType.INFO -> Log.i(APP_TAG, fullMessage)
            LogType.WARNING -> Log.w(APP_TAG, fullMessage)
            LogType.ERROR, LogType.FATAL -> {
                Log.e(APP_TAG, fullMessage)
                Log.e(APP_TAG, "Stack Trace:\n${stackTraceString}")
            }
        }
    }
}

enum class LogType {
    DEBUG, INFO, WARNING, ERROR, FATAL
}