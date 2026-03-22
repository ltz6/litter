package com.litter.android.state

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.litter.android.core.bridge.RustApprovalKind
import com.litter.android.core.bridge.RustCodexModel
import com.litter.android.core.bridge.RustConnectionState
import com.litter.android.core.bridge.RustMobileClient
import com.litter.android.core.bridge.RustPendingApproval
import com.litter.android.core.bridge.RustSandboxMode
import com.litter.android.core.bridge.RustThreadKey
import com.litter.android.core.bridge.RustThreadStartParams
import com.litter.android.core.bridge.RustTurnStartParams
import com.litter.android.core.bridge.RustUiEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.Closeable

/**
 * Thin Kotlin wrapper around [RustMobileClient] that exposes Compose-compatible
 * [StateFlow]-based state, mirroring the public API surface of [ServerManager].
 *
 * This class is designed to **run alongside** the existing [ServerManager] during
 * a gradual migration. UI code can observe [stateFlow] for Rust-sourced state
 * while still using [ServerManager] for anything not yet ported.
 *
 * ## Threading
 *
 * - All public methods launch coroutines on an internal [CoroutineScope] bound to
 *   [Dispatchers.Main] + [SupervisorJob] so callers can invoke them from any context.
 * - The [RustMobileClient.call] suspend functions run on [Dispatchers.IO] internally.
 * - Event callbacks from native code are dispatched to the main thread before
 *   updating [_state].
 *
 * ## Usage
 *
 * ```kotlin
 * val bridge = RustServerManagerBridge()
 * bridge.initialize()
 * // Observe state in Compose:
 * val state by bridge.stateFlow.collectAsState()
 * // Connect, send messages, etc:
 * bridge.connectLocal()
 * bridge.sendMessage(threadKey, "Hello!")
 * // Cleanup:
 * bridge.close()
 * ```
 */
class RustServerManagerBridge(
    private val client: RustMobileClient = RustMobileClient(),
) : Closeable {

    companion object {
        private const val TAG = "RustServerManagerBridge"
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /**
     * Bridge-level state. Designed to be mappable to [AppState] via adapter
     * extensions added during migration (see server-manager-migration.md).
     */
    data class BridgeState(
        val connectionStatus: RustConnectionState = RustConnectionState.DISCONNECTED,
        val connectionError: String? = null,
        val activeServerId: String? = null,
        val activeThreadKey: RustThreadKey? = null,
        val threads: Map<RustThreadKey, BridgeThreadState> = emptyMap(),
        val availableModels: List<RustCodexModel> = emptyList(),
        val selectedModelId: String? = null,
        val selectedReasoningEffort: String? = null,
        val pendingApprovals: Map<Any?, RustPendingApproval> = emptyMap(),
        val accountJson: JSONObject? = null,
        val rateLimitsJson: JSONObject? = null,
    ) {
        val activeThread: BridgeThreadState?
            get() = activeThreadKey?.let { threads[it] }
    }

    /**
     * Per-thread state managed by the bridge. Accumulates streaming deltas
     * from [RustUiEvent] notifications.
     */
    data class BridgeThreadState(
        val key: RustThreadKey,
        val title: String? = null,
        val status: BridgeThreadStatus = BridgeThreadStatus.IDLE,
        val messages: List<BridgeChatMessage> = emptyList(),
        val activeTurnId: String? = null,
        val lastError: String? = null,
    ) {
        val hasTurnActive: Boolean get() = status == BridgeThreadStatus.THINKING
    }

    enum class BridgeThreadStatus {
        IDLE, THINKING, ERROR
    }

    /**
     * Minimal chat message representation assembled from item/delta events.
     * Will be extended as more event types are handled.
     */
    data class BridgeChatMessage(
        val id: String,
        val role: String, // "user" | "assistant" | "system"
        val content: StringBuilder = StringBuilder(),
        val reasoning: StringBuilder = StringBuilder(),
        val isComplete: Boolean = false,
    )

    private val _state = MutableStateFlow(BridgeState())

    /** Observable state flow for Compose collection. */
    val stateFlow: StateFlow<BridgeState> = _state.asStateFlow()

    /** Snapshot of the current state (non-suspending). */
    fun snapshot(): BridgeState = _state.value

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /**
     * Initialize the native [RustMobileClient] and subscribe to events.
     *
     * Safe to call from any thread. Throws if the native library is not loaded.
     */
    fun initialize() {
        if (client.isInitialized) return
        client.init()
        client.subscribeEvents { event ->
            mainHandler.post { handleEvent(event) }
        }
        Log.d(TAG, "Initialized RustMobileClient and subscribed to events")
    }

    override fun close() {
        client.destroy()
    }

    // -----------------------------------------------------------------------
    // Connection — mirrors ServerManager.connectLocalDefaultServer / connectServer / disconnect
    // -----------------------------------------------------------------------

    fun connectLocal(
        config: JSONObject = JSONObject(),
        onComplete: ((Result<String>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            updateState { it.copy(connectionStatus = RustConnectionState.CONNECTING, connectionError = null) }
            val result = runCatching { client.connectLocal(config) }
            result.onSuccess { serverId ->
                updateState { it.copy(connectionStatus = RustConnectionState.CONNECTED, activeServerId = serverId) }
            }
            result.onFailure { error ->
                updateState { it.copy(connectionStatus = RustConnectionState.DISCONNECTED, connectionError = error.message) }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun connectRemote(
        config: JSONObject,
        onComplete: ((Result<String>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            updateState { it.copy(connectionStatus = RustConnectionState.CONNECTING, connectionError = null) }
            val result = runCatching { client.connectRemote(config) }
            result.onSuccess { serverId ->
                updateState { it.copy(connectionStatus = RustConnectionState.CONNECTED, activeServerId = serverId) }
            }
            result.onFailure { error ->
                updateState { it.copy(connectionStatus = RustConnectionState.DISCONNECTED, connectionError = error.message) }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun disconnect(
        serverId: String? = null,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val targetId = serverId ?: _state.value.activeServerId ?: return@launch
            val result = runCatching { client.disconnectServer(targetId) }
            result.onSuccess {
                updateState { current ->
                    val newThreads = current.threads.filterKeys { it.serverId != targetId }
                    current.copy(
                        connectionStatus = if (current.activeServerId == targetId) RustConnectionState.DISCONNECTED else current.connectionStatus,
                        activeServerId = if (current.activeServerId == targetId) null else current.activeServerId,
                        activeThreadKey = if (current.activeThreadKey?.serverId == targetId) null else current.activeThreadKey,
                        threads = newThreads,
                    )
                }
            }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Threads — mirrors ServerManager.startThread / resumeThread / selectThread
    // -----------------------------------------------------------------------

    fun startThread(
        serverId: String? = null,
        params: RustThreadStartParams = RustThreadStartParams(),
        onComplete: ((Result<RustThreadKey>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val targetId = serverId ?: _state.value.activeServerId ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active server")))
                return@launch
            }
            val result = runCatching { client.startThread(targetId, params) }
            result.onSuccess { key ->
                updateState { current ->
                    val thread = BridgeThreadState(key = key)
                    current.copy(
                        activeThreadKey = key,
                        threads = current.threads + (key to thread),
                    )
                }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun resumeThread(
        serverId: String? = null,
        threadId: String,
        onComplete: ((Result<RustThreadKey>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val targetId = serverId ?: _state.value.activeServerId ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active server")))
                return@launch
            }
            val result = runCatching { client.resumeThread(targetId, threadId) }
            result.onSuccess { key ->
                updateState { current ->
                    val existing = current.threads[key] ?: BridgeThreadState(key = key)
                    current.copy(
                        activeThreadKey = key,
                        threads = current.threads + (key to existing),
                    )
                }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun selectThread(threadKey: RustThreadKey) {
        updateState { it.copy(activeThreadKey = threadKey) }
    }

    fun listThreads(
        serverId: String? = null,
        onComplete: ((Result<List<RustThreadKey>>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val targetId = serverId ?: _state.value.activeServerId ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active server")))
                return@launch
            }
            val result = runCatching {
                val response = client.listThreads(targetId)
                response.threads.map { info ->
                    val key = RustThreadKey(serverId = targetId, threadId = info.id)
                    // Upsert thread state with info from listing
                    updateState { current ->
                        val existing = current.threads[key]
                        val thread = (existing ?: BridgeThreadState(key = key)).copy(title = info.title)
                        current.copy(threads = current.threads + (key to thread))
                    }
                    key
                }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun archiveThread(
        threadKey: RustThreadKey,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching { client.archiveThread(threadKey) }
            result.onSuccess {
                updateState { current ->
                    current.copy(
                        threads = current.threads - threadKey,
                        activeThreadKey = if (current.activeThreadKey == threadKey) null else current.activeThreadKey,
                    )
                }
            }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Messages — mirrors ServerManager.sendMessage / interrupt
    // -----------------------------------------------------------------------

    fun sendMessage(
        threadKey: RustThreadKey? = null,
        prompt: String,
        model: String? = null,
        reasoningEffort: String? = null,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val key = threadKey ?: _state.value.activeThreadKey ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active thread")))
                return@launch
            }
            val params = RustTurnStartParams(
                threadId = key.threadId,
                prompt = prompt,
                model = model ?: _state.value.selectedModelId,
                reasoningEffort = reasoningEffort ?: _state.value.selectedReasoningEffort,
            )
            val result = runCatching { client.sendMessage(key, params) }
            deliverOnMain(onComplete, result)
        }
    }

    fun interrupt(
        threadKey: RustThreadKey? = null,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val key = threadKey ?: _state.value.activeThreadKey ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active thread")))
                return@launch
            }
            val result = runCatching { client.interruptTurn(key) }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Approvals — mirrors ServerManager.respondToPendingApproval
    // -----------------------------------------------------------------------

    fun approve(requestId: Any?, onComplete: ((Result<Unit>) -> Unit)? = null) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching { client.approve(requestId) }
            result.onSuccess {
                updateState { it.copy(pendingApprovals = it.pendingApprovals - requestId) }
            }
            deliverOnMain(onComplete, result)
        }
    }

    fun deny(requestId: Any?, onComplete: ((Result<Unit>) -> Unit)? = null) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching { client.deny(requestId) }
            result.onSuccess {
                updateState { it.copy(pendingApprovals = it.pendingApprovals - requestId) }
            }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Model selection — mirrors ServerManager.updateModelSelection
    // -----------------------------------------------------------------------

    fun updateModelSelection(modelId: String? = null, reasoningEffort: String? = null) {
        updateState { current ->
            current.copy(
                selectedModelId = modelId ?: current.selectedModelId,
                selectedReasoningEffort = reasoningEffort ?: current.selectedReasoningEffort,
            )
        }
    }

    // -----------------------------------------------------------------------
    // Auth — mirrors ServerManager.loginWithApiKey / logoutAccount
    // -----------------------------------------------------------------------

    fun setApiKey(
        apiKey: String,
        serverId: String? = null,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        scope.launch(Dispatchers.IO) {
            val targetId = serverId ?: _state.value.activeServerId ?: run {
                deliverOnMain(onComplete, Result.failure(IllegalStateException("No active server")))
                return@launch
            }
            val result = runCatching { client.setApiKey(targetId, apiKey) }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Discovery — mirrors ServerManager scan
    // -----------------------------------------------------------------------

    fun scanServers(onComplete: ((Result<List<JSONObject>>) -> Unit)? = null) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching {
                client.scanServers().map { it.toJson() }
            }
            deliverOnMain(onComplete, result)
        }
    }

    // -----------------------------------------------------------------------
    // Event handling — maps RustUiEvent to BridgeState updates
    // -----------------------------------------------------------------------

    private fun handleEvent(event: RustUiEvent) {
        Log.d(TAG, "Event: ${event.method}")

        when (event) {
            // -- Thread lifecycle --
            is RustUiEvent.ThreadStarted -> {
                val threadId = event.threadId ?: return
                val serverId = event.rawParams.optString("serverId", _state.value.activeServerId ?: "")
                val key = RustThreadKey(serverId = serverId, threadId = threadId)
                updateState { current ->
                    val thread = current.threads[key] ?: BridgeThreadState(key = key)
                    current.copy(
                        threads = current.threads + (key to thread),
                        activeThreadKey = key,
                    )
                }
            }

            is RustUiEvent.ThreadStatusChanged -> {
                val threadId = event.threadId ?: return
                updateThreadByThreadId(threadId) { thread ->
                    val status = when (event.status) {
                        com.litter.android.core.bridge.RustThreadStatus.ACTIVE -> BridgeThreadStatus.THINKING
                        com.litter.android.core.bridge.RustThreadStatus.IDLE -> BridgeThreadStatus.IDLE
                        com.litter.android.core.bridge.RustThreadStatus.SYSTEM_ERROR -> BridgeThreadStatus.ERROR
                        else -> thread.status
                    }
                    thread.copy(status = status)
                }
            }

            is RustUiEvent.ThreadNameUpdated -> {
                val threadId = event.threadId ?: return
                updateThreadByThreadId(threadId) { it.copy(title = event.name) }
            }

            is RustUiEvent.ThreadArchived -> {
                val threadId = event.threadId ?: return
                updateState { current ->
                    val key = current.threads.keys.firstOrNull { it.threadId == threadId } ?: return@updateState current
                    current.copy(
                        threads = current.threads - key,
                        activeThreadKey = if (current.activeThreadKey == key) null else current.activeThreadKey,
                    )
                }
            }

            // -- Turn lifecycle --
            is RustUiEvent.TurnStarted -> {
                val threadId = event.threadId ?: return
                val turnId = event.turnId
                updateThreadByThreadId(threadId) { it.copy(status = BridgeThreadStatus.THINKING, activeTurnId = turnId) }
            }

            is RustUiEvent.TurnCompleted -> {
                val threadId = event.threadId ?: return
                updateThreadByThreadId(threadId) { thread ->
                    // Mark all incomplete messages as complete
                    val updated = thread.messages.map { msg ->
                        if (!msg.isComplete) msg.copy(isComplete = true) else msg
                    }
                    thread.copy(status = BridgeThreadStatus.IDLE, activeTurnId = null, messages = updated)
                }
            }

            // -- Item lifecycle --
            is RustUiEvent.ItemStarted -> {
                val threadId = event.threadId ?: return
                val itemId = event.itemId ?: return
                val role = event.rawParams.optString("role", "assistant")
                updateThreadByThreadId(threadId) { thread ->
                    val existing = thread.messages.firstOrNull { it.id == itemId }
                    if (existing != null) return@updateThreadByThreadId thread
                    val msg = BridgeChatMessage(id = itemId, role = role)
                    thread.copy(messages = thread.messages + msg)
                }
            }

            is RustUiEvent.ItemCompleted -> {
                val threadId = event.threadId ?: return
                val itemId = event.itemId ?: return
                updateThreadByThreadId(threadId) { thread ->
                    val updated = thread.messages.map { msg ->
                        if (msg.id == itemId) msg.copy(isComplete = true) else msg
                    }
                    thread.copy(messages = updated)
                }
            }

            // -- Streaming deltas --
            is RustUiEvent.AgentMessageDelta -> {
                val threadId = event.threadId ?: return
                val itemId = event.itemId ?: return
                val delta = event.delta ?: return
                appendToMessage(threadId, itemId, delta, isReasoning = false)
            }

            is RustUiEvent.ReasoningTextDelta -> {
                val threadId = event.threadId ?: return
                val itemId = event.itemId ?: return
                val text = event.text ?: return
                appendToMessage(threadId, itemId, text, isReasoning = true)
            }

            is RustUiEvent.ReasoningSummaryTextDelta -> {
                val threadId = event.threadId ?: return
                val itemId = event.itemId ?: return
                val text = event.text ?: return
                appendToMessage(threadId, itemId, text, isReasoning = true)
            }

            // -- Approvals --
            is RustUiEvent.ServerRequestResolved -> {
                val requestId = event.rawParams.opt("requestId")
                if (requestId != null) {
                    updateState { it.copy(pendingApprovals = it.pendingApprovals - requestId) }
                }
            }

            // -- Account --
            is RustUiEvent.AccountUpdated -> {
                updateState { it.copy(accountJson = event.rawParams) }
            }

            is RustUiEvent.AccountRateLimitsUpdated -> {
                updateState { it.copy(rateLimitsJson = event.rawParams) }
            }

            // -- Errors --
            is RustUiEvent.Error -> {
                Log.e(TAG, "Server error: ${event.errorMessage}")
                updateState { it.copy(connectionError = event.errorMessage) }
            }

            // -- Not yet handled --
            else -> {
                Log.d(TAG, "Unhandled event: ${event.method}")
            }
        }
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    private inline fun updateState(transform: (BridgeState) -> BridgeState) {
        _state.value = transform(_state.value)
    }

    private inline fun updateThreadByThreadId(
        threadId: String,
        crossinline transform: (BridgeThreadState) -> BridgeThreadState,
    ) {
        updateState { current ->
            val key = current.threads.keys.firstOrNull { it.threadId == threadId } ?: return@updateState current
            val thread = current.threads[key] ?: return@updateState current
            current.copy(threads = current.threads + (key to transform(thread)))
        }
    }

    private fun appendToMessage(threadId: String, itemId: String, text: String, isReasoning: Boolean) {
        updateThreadByThreadId(threadId) { thread ->
            val updated = thread.messages.map { msg ->
                if (msg.id == itemId) {
                    if (isReasoning) msg.reasoning.append(text) else msg.content.append(text)
                    msg
                } else {
                    msg
                }
            }
            thread.copy(messages = updated)
        }
    }

    private fun <T> deliverOnMain(callback: ((Result<T>) -> Unit)?, result: Result<T>) {
        if (callback == null) return
        mainHandler.post { callback(result) }
    }
}
