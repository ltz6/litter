package com.litter.android.core.bridge

import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Kotlin wrapper around the `codex_mobile_client_*` C FFI functions exposed via JNI.
 *
 * This replaces the WebSocket-based transport ([JsonRpcWebSocketClient] + [BridgeRpcTransport])
 * with a direct in-process channel to the Rust `MobileClient`. All communication is done
 * through JSON strings over JNI callbacks — no TCP sockets involved.
 *
 * ## Usage
 *
 * ```kotlin
 * val client = RustMobileClient()
 * client.init()
 * client.subscribeEvents { event -> handleEvent(event) }
 * val result = client.call("connect_local", JSONObject().put("config", ...))
 * client.destroy()
 * ```
 *
 * ## Threading
 *
 * - [init] and [destroy] must be called from the same logical owner (not concurrently).
 * - [call] is a suspend function safe to call from any coroutine context.
 * - Event callbacks are invoked from a native background thread; callers should
 *   dispatch to the main thread if needed.
 */
class RustMobileClient {

    /**
     * Opaque native handle returned by `codex_mobile_client_init`.
     * Zero means not initialized.
     */
    private val nativeHandle = AtomicLong(0L)

    /**
     * Whether the native library was loaded successfully.
     */
    val isLoaded: Boolean get() = NativeCodexBridge.isLibraryLoaded

    /**
     * Whether [init] has been called and [destroy] has not yet been called.
     */
    val isInitialized: Boolean get() = nativeHandle.get() != 0L

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /**
     * Create a new `MobileClient` on the native side.
     *
     * This sets up the Rust runtime, in-memory auth storage, and event broadcast
     * channel. Must be called before [call] or [subscribeEvents].
     *
     * @throws IllegalStateException if the native library is not loaded or init fails.
     */
    fun init() {
        check(isLoaded) { "Native library codex_bridge not loaded" }
        check(!isInitialized) { "RustMobileClient already initialized" }

        val handle = NativeCodexBridge.nativeMobileClientInit()
        if (handle == 0L) {
            throw IllegalStateException("codex_mobile_client_init returned null handle")
        }
        nativeHandle.set(handle)
    }

    /**
     * Destroy the native `MobileClient` and free all resources.
     *
     * After this call, [call] and [subscribeEvents] will throw. Safe to call
     * multiple times (subsequent calls are no-ops).
     */
    fun destroy() {
        val handle = nativeHandle.getAndSet(0L)
        if (handle != 0L) {
            NativeCodexBridge.nativeMobileClientDestroy(handle)
        }
    }

    // -----------------------------------------------------------------------
    // RPC
    // -----------------------------------------------------------------------

    /**
     * Make a JSON-RPC style call into the native `MobileClient`.
     *
     * The [method] is dispatched to the corresponding Rust handler (e.g.
     * `"connect_local"`, `"start_thread"`, `"send_message"`). [params] is the
     * JSON parameters object (may be null for parameterless methods).
     *
     * The call suspends until the Rust side delivers a response via the JNI
     * callback. On success the `"result"` field of the response is returned;
     * on failure an [IllegalStateException] is thrown with the error message.
     *
     * ## Available methods
     *
     * | Method              | Params                                          |
     * |---------------------|-------------------------------------------------|
     * | `connect_local`     | `{ config: ServerConfig, in_process: ... }`     |
     * | `connect_remote`    | `ServerConfig`                                  |
     * | `disconnect_server` | `{ server_id: String }`                         |
     * | `list_threads`      | `{ server_id: String }`                         |
     * | `start_thread`      | `{ server_id, params: ThreadStartParams }`      |
     * | `resume_thread`     | `{ server_id, thread_id }`                      |
     * | `send_message`      | `{ key: ThreadKey, params: TurnStartParams }`   |
     * | `interrupt_turn`    | `ThreadKey`                                     |
     * | `archive_thread`    | `ThreadKey`                                     |
     * | `approve`           | `{ request_id: Value }`                         |
     * | `deny`              | `{ request_id: Value }`                         |
     * | `pending_approvals` | (none)                                          |
     * | `scan_servers`      | (none)                                          |
     * | `set_api_key`       | `{ server_id, key }`                             |
     * | `parse_tool_calls`  | `{ text: String }`                               |
     */
    suspend fun call(method: String, params: JSONObject? = null): JSONObject =
        suspendCancellableCoroutine { continuation ->
            val handle = requireHandle()

            val envelope = JSONObject().apply {
                put("method", method)
                if (params != null) {
                    put("params", params)
                }
            }
            val json = envelope.toString()

            val status = NativeCodexBridge.nativeMobileClientCall(
                handle = handle,
                methodJson = json,
            ) { responseJson ->
                val response = runCatching { JSONObject(responseJson) }.getOrNull()
                if (response == null) {
                    continuation.resumeWithException(
                        IllegalStateException("Invalid JSON response from native call: $method"),
                    )
                    return@nativeMobileClientCall
                }

                val ok = response.optBoolean("ok", false)
                if (ok) {
                    val result = when (val value = response.opt("result")) {
                        null, JSONObject.NULL -> JSONObject()
                        is JSONObject -> value
                        else -> JSONObject().put("value", value)
                    }
                    continuation.resume(result)
                } else {
                    val error = response.optString("error", "Unknown native error")
                    continuation.resumeWithException(
                        IllegalStateException("MobileClient.$method failed: $error"),
                    )
                }
            }

            if (status != 0) {
                continuation.resumeWithException(
                    IllegalStateException(
                        "codex_mobile_client_call dispatch failed (status=$status) for method: $method",
                    ),
                )
            }
        }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /**
     * Subscribe to `UiEvent` delivery from the native `MobileClient`.
     *
     * Events are delivered as [RustUiEvent] instances parsed from the JSON
     * payload. The [callback] is invoked from a native background thread;
     * callers should dispatch to the appropriate thread if needed.
     *
     * Only one subscription is active at a time. Calling this again replaces
     * the previous subscription.
     *
     * @throws IllegalStateException if the client is not initialized.
     */
    fun subscribeEvents(callback: (RustUiEvent) -> Unit) {
        val handle = requireHandle()

        val status = NativeCodexBridge.nativeMobileClientSubscribeEvents(
            handle = handle,
        ) { eventJson ->
            val parsed = runCatching {
                val obj = JSONObject(eventJson)
                val method = obj.optString("method", "")
                val params = obj.optJSONObject("params") ?: run {
                    // If there's no "method"/"params" envelope, the whole object IS the event.
                    // Try to extract the notification type from the top-level "type" field.
                    val eventType = obj.optString("type", "")
                    if (eventType.isNotEmpty()) {
                        RustUiEvent.fromNotification(eventType, obj)
                    } else if (method.isNotEmpty()) {
                        RustUiEvent.fromNotification(method, obj.optJSONObject("params") ?: JSONObject())
                    } else {
                        RustUiEvent.Other("unknown", obj)
                    }
                    return@runCatching RustUiEvent.fromNotification(
                        method.ifEmpty { obj.optString("type", "unknown") },
                        obj.optJSONObject("params") ?: obj,
                    )
                }
                RustUiEvent.fromNotification(method, params)
            }.getOrNull()

            if (parsed != null) {
                callback(parsed)
            }
        }

        if (status != 0) {
            throw IllegalStateException(
                "codex_mobile_client_subscribe_events failed (status=$status)",
            )
        }
    }

    // -----------------------------------------------------------------------
    // Convenience helpers
    // -----------------------------------------------------------------------

    /**
     * Connect to a local (on-device) Codex server via the in-process channel.
     */
    suspend fun connectLocal(config: JSONObject = JSONObject(), inProcess: JSONObject = JSONObject()): String {
        val result = call("connect_local", JSONObject().apply {
            put("config", config)
            put("in_process", inProcess)
        })
        return result.optString("server_id", "")
    }

    /**
     * Connect to a remote Codex server.
     */
    suspend fun connectRemote(config: JSONObject): String {
        val result = call("connect_remote", config)
        return result.optString("server_id", "")
    }

    /**
     * Disconnect from a server.
     */
    suspend fun disconnectServer(serverId: String) {
        call("disconnect_server", JSONObject().put("server_id", serverId))
    }

    /**
     * List threads on a connected server.
     */
    suspend fun listThreads(serverId: String): RustThreadListResponse {
        val result = call("list_threads", JSONObject().put("server_id", serverId))
        return RustThreadListResponse.fromJson(result)
    }

    /**
     * Start a new thread on a server.
     */
    suspend fun startThread(serverId: String, params: RustThreadStartParams): RustThreadKey {
        val result = call("start_thread", JSONObject().apply {
            put("server_id", serverId)
            put("params", params.toJson())
        })
        return RustThreadKey.fromJson(result)
    }

    /**
     * Resume an existing thread.
     */
    suspend fun resumeThread(serverId: String, threadId: String): RustThreadKey {
        val result = call("resume_thread", JSONObject().apply {
            put("server_id", serverId)
            put("thread_id", threadId)
        })
        return RustThreadKey.fromJson(result)
    }

    /**
     * Send a message (start a turn) on a thread.
     */
    suspend fun sendMessage(key: RustThreadKey, params: RustTurnStartParams) {
        call("send_message", JSONObject().apply {
            put("key", key.toJson())
            put("params", params.toJson())
        })
    }

    /**
     * Interrupt the active turn on a thread.
     */
    suspend fun interruptTurn(key: RustThreadKey) {
        call("interrupt_turn", key.toJson())
    }

    /**
     * Archive a thread.
     */
    suspend fun archiveThread(key: RustThreadKey) {
        call("archive_thread", key.toJson())
    }

    /**
     * Approve a pending tool-call request.
     */
    suspend fun approve(requestId: Any?) {
        val params = JSONObject()
        if (requestId != null) {
            params.put("request_id", requestId)
        }
        call("approve", params)
    }

    /**
     * Deny a pending tool-call request.
     */
    suspend fun deny(requestId: Any?) {
        val params = JSONObject()
        if (requestId != null) {
            params.put("request_id", requestId)
        }
        call("deny", params)
    }

    /**
     * Get all pending approval requests.
     */
    suspend fun pendingApprovals(): List<RustPendingApproval> {
        val result = call("pending_approvals")
        val array = result.optJSONArray("value") ?: return emptyList()
        val out = mutableListOf<RustPendingApproval>()
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            out += RustPendingApproval.fromJson(obj)
        }
        return out
    }

    /**
     * Scan for available servers (mDNS, Tailscale, etc.).
     */
    suspend fun scanServers(): List<RustDiscoveredServer> {
        val result = call("scan_servers")
        val array = result.optJSONArray("value") ?: return emptyList()
        val out = mutableListOf<RustDiscoveredServer>()
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            out += RustDiscoveredServer.fromJson(obj)
        }
        return out
    }

    /**
     * Set an API key for a server.
     */
    suspend fun setApiKey(serverId: String, key: String) {
        call("set_api_key", JSONObject().apply {
            put("server_id", serverId)
            put("key", key)
        })
    }

    /**
     * List available models on a server.
     */
    suspend fun listModels(serverId: String): RustModelListResponse {
        val result = call("list_threads", JSONObject().put("server_id", serverId))
        return RustModelListResponse.fromJson(result)
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    private fun requireHandle(): Long {
        val handle = nativeHandle.get()
        check(handle != 0L) { "RustMobileClient not initialized — call init() first" }
        return handle
    }
}
