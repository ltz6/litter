package com.litter.android.core.bridge

object NativeCodexBridge {
    internal val isLibraryLoaded: Boolean =
        runCatching { System.loadLibrary("codex_bridge") }.isSuccess

    // -----------------------------------------------------------------------
    // Legacy WebSocket bridge server (used by JsonRpcWebSocketClient / BridgeRpcTransport)
    // -----------------------------------------------------------------------

    fun startServerPort(): Int {
        if (!isLibraryLoaded) {
            return -1000
        }
        return nativeStartServerPort()
    }

    fun stopServer() {
        if (isLibraryLoaded) {
            nativeStopServer()
        }
    }

    @JvmStatic
    private external fun nativeStartServerPort(): Int

    @JvmStatic
    private external fun nativeStopServer()

    // -----------------------------------------------------------------------
    // MobileClient FFI — new in-process transport (used by RustMobileClient)
    //
    // These JNI functions map to the `codex_mobile_client_*` C FFI entry points
    // defined in `shared/rust-bridge/codex-bridge/include/codex_bridge.h` and
    // implemented in `shared/rust-bridge/codex-bridge/src/lib.rs`.
    //
    // The Rust JNI glue lives in `shared/rust-bridge/codex-bridge/src/android_jni.rs`.
    // -----------------------------------------------------------------------

    /**
     * Create a new MobileClient with in-memory auth storage.
     *
     * Returns an opaque native handle (as a `long`) or 0 on failure.
     * Maps to `codex_mobile_client_init`.
     */
    @JvmStatic
    internal external fun nativeMobileClientInit(): Long

    /**
     * Destroy the MobileClient and free all resources.
     *
     * Maps to `codex_mobile_client_destroy`.
     *
     * @param handle the opaque native handle returned by [nativeMobileClientInit].
     */
    @JvmStatic
    internal external fun nativeMobileClientDestroy(handle: Long)

    /**
     * Generic JSON-RPC style call into MobileClient.
     *
     * [methodJson] is a JSON string like `{"method": "...", "params": {...}}`.
     * The [responseCallback] is invoked with the result JSON string when the
     * native side completes the call. The callback may be called from any thread.
     *
     * Maps to `codex_mobile_client_call`.
     *
     * @return 0 if the call was dispatched, negative on immediate failure.
     */
    @JvmStatic
    internal external fun nativeMobileClientCall(
        handle: Long,
        methodJson: String,
        responseCallback: NativeResponseCallback,
    ): Int

    /**
     * Subscribe to UiEvent delivery from the MobileClient.
     *
     * Events are serialized as JSON and delivered via the [eventCallback].
     * Only one subscription is active at a time — calling again replaces
     * the previous one.
     *
     * Maps to `codex_mobile_client_subscribe_events`.
     *
     * @return 0 on success, negative on failure.
     */
    @JvmStatic
    internal external fun nativeMobileClientSubscribeEvents(
        handle: Long,
        eventCallback: NativeEventCallback,
    ): Int
}

/**
 * Functional interface for receiving a single JSON response string from a native call.
 *
 * Used as the JNI callback type for [NativeCodexBridge.nativeMobileClientCall].
 */
fun interface NativeResponseCallback {
    fun onResponse(json: String)
}

/**
 * Functional interface for receiving streamed JSON event strings from native.
 *
 * Used as the JNI callback type for [NativeCodexBridge.nativeMobileClientSubscribeEvents].
 */
fun interface NativeEventCallback {
    fun onEvent(json: String)
}
