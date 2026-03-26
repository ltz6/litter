package com.litter.android.util

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.litter.android.core.bridge.UniffiInit
import org.json.JSONObject
import uniffi.codex_mobile_client.LogConfig
import uniffi.codex_mobile_client.LogEvent
import uniffi.codex_mobile_client.LogLevel
import uniffi.codex_mobile_client.LogSource
import uniffi.codex_mobile_client.Logs
import java.io.File

object LLog {
    @Volatile private var bootstrapped = false
    private val logs by lazy { Logs() }

    fun bootstrap(context: Context) {
        if (bootstrapped) return
        synchronized(this) {
            if (bootstrapped) return
            UniffiInit.ensure(context)

            val codexHome = File(context.filesDir, "codex-home").apply { mkdirs() }
            val configFile = File(codexHome, "log-spool/config.json")
            if (!configFile.exists()) {
                logs.configure(
                    LogConfig(
                        enabled = false,
                        collectorUrl = null,
                        bearerToken = null,
                        minLevel = LogLevel.INFO,
                        deviceId = Settings.Secure.getString(
                            context.contentResolver,
                            Settings.Secure.ANDROID_ID,
                        ),
                        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
                        appVersion = appVersion(context),
                        build = appBuild(context),
                    ),
                )
            }

            bootstrapped = true
        }
    }

    fun d(tag: String, message: String, fields: Map<String, Any?> = emptyMap(), payloadJson: String? = null) {
        Log.d(tag, message)
        emit(LogLevel.DEBUG, tag, message, fields, payloadJson)
    }

    fun i(tag: String, message: String, fields: Map<String, Any?> = emptyMap(), payloadJson: String? = null) {
        Log.i(tag, message)
        emit(LogLevel.INFO, tag, message, fields, payloadJson)
    }

    fun w(tag: String, message: String, fields: Map<String, Any?> = emptyMap(), payloadJson: String? = null) {
        Log.w(tag, message)
        emit(LogLevel.WARN, tag, message, fields, payloadJson)
    }

    fun e(
        tag: String,
        message: String,
        throwable: Throwable? = null,
        fields: Map<String, Any?> = emptyMap(),
        payloadJson: String? = null,
    ) {
        if (throwable != null) {
            Log.e(tag, message, throwable)
        } else {
            Log.e(tag, message)
        }
        val mergedFields = fields.toMutableMap()
        if (throwable != null) {
            mergedFields["error"] = throwable.message ?: throwable.javaClass.simpleName
            mergedFields["stack"] = throwable.stackTraceToString()
        }
        emit(LogLevel.ERROR, tag, message, mergedFields, payloadJson)
    }

    private fun emit(
        level: LogLevel,
        subsystem: String,
        message: String,
        fields: Map<String, Any?>,
        payloadJson: String?,
    ) {
        logs.log(
            LogEvent(
                timestampMs = null,
                level = level,
                source = LogSource.ANDROID,
                subsystem = subsystem,
                category = subsystem,
                message = message,
                sessionId = null,
                serverId = null,
                threadId = null,
                requestId = null,
                payloadJson = payloadJson,
                fieldsJson = fieldsJson(fields),
            ),
        )
    }

    private fun fieldsJson(fields: Map<String, Any?>): String? {
        if (fields.isEmpty()) return null
        val filtered = fields.filterValues { it != null }
        if (filtered.isEmpty()) return null
        return JSONObject(filtered).toString()
    }

    private fun appVersion(context: Context): String? {
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        return pkg.versionName
    }

    private fun appBuild(context: Context): String {
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        return pkg.longVersionCode.toString()
    }
}
