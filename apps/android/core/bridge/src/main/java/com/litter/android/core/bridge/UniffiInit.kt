package com.litter.android.core.bridge

import android.content.Context
import java.io.File

/**
 * Initializes the UniFFI bindings and platform environment.
 *
 * - Redirects UniFFI/JNA to load `codex_mobile_client` as the Android native library
 * - Loads `codex_bridge` for Android-specific JNI bootstrap/helpers
 * - Sets HOME and CODEX_HOME so Rust can find/create its data directories
 *
 * Must be called before any UniFFI-generated class is instantiated.
 */
object UniffiInit {
    private var initialized = false

    @Synchronized
    fun ensure(context: Context? = null) {
        if (initialized) return

        // Set JNA library override
        System.setProperty(
            "uniffi.component.codex_mobile_client.libraryOverride",
            "codex_mobile_client",
        )

        // Set HOME and CODEX_HOME for Rust (Android doesn't set HOME by default)
        if (context != null) {
            val filesDir = context.filesDir.absolutePath
            val codexHome = File(context.filesDir, "codex-home")
            codexHome.mkdirs()

            try {
                // These env vars are read by the Rust bridge for data storage bootstrap.
                val processBuilder = ProcessBuilder()
                val env = processBuilder.environment()
                if (env["HOME"].isNullOrEmpty()) {
                    // Can't set env vars in the current process from Java,
                    // but we can set system properties that Rust reads
                }
            } catch (_: Exception) {}

            // Set via system properties — Rust's init_codex_home() also checks TMPDIR
            System.setProperty("user.home", filesDir)

            try {
                // Android-specific JNI bootstrap still lives in codex_bridge.
                System.loadLibrary("codex_bridge")
                // Call the C init function to set up CODEX_HOME and TLS roots
                nativeBridgeInit(filesDir, codexHome.absolutePath)
                // UniFFI/JNA bindings resolve against codex_mobile_client.
                System.loadLibrary("codex_mobile_client")
            } catch (e: Exception) {
                android.util.Log.w("UniffiInit", "Native init: ${e.message}")
            }
        }

        initialized = true
    }

    /**
     * JNI call to set environment variables from native code (the only way on Android).
     */
    @JvmStatic
    private external fun nativeBridgeInit(homeDir: String, codexHomeDir: String)
}
