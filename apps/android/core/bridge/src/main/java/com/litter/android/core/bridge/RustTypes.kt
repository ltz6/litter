package com.litter.android.core.bridge

import org.json.JSONArray
import org.json.JSONObject

// ---------------------------------------------------------------------------
// Enums — mirror Rust `codex-mobile-client/src/types/enums.rs`
// All serialized as camelCase strings by serde.
// ---------------------------------------------------------------------------

enum class RustSandboxMode(val wire: String) {
    READ_ONLY("readOnly"),
    WORKSPACE_WRITE("workspaceWrite"),
    DANGER_FULL_ACCESS("dangerFullAccess"),
    ;

    companion object {
        fun from(value: String): RustSandboxMode =
            entries.firstOrNull { it.wire == value } ?: READ_ONLY
    }
}

enum class RustConnectionState(val wire: String) {
    DISCONNECTED("disconnected"),
    CONNECTING("connecting"),
    CONNECTED("connected"),
    RECONNECTING("reconnecting"),
    UNRESPONSIVE("unresponsive"),
    ;

    companion object {
        fun from(value: String): RustConnectionState =
            entries.firstOrNull { it.wire == value } ?: DISCONNECTED
    }
}

enum class RustThreadStatus(val wire: String) {
    NOT_LOADED("notLoaded"),
    IDLE("idle"),
    ACTIVE("active"),
    SYSTEM_ERROR("systemError"),
    ;

    companion object {
        fun from(value: String): RustThreadStatus =
            entries.firstOrNull { it.wire == value } ?: NOT_LOADED
    }
}

enum class RustMessageRole(val wire: String) {
    USER("user"),
    ASSISTANT("assistant"),
    SYSTEM("system"),
    ;

    companion object {
        fun from(value: String): RustMessageRole =
            entries.firstOrNull { it.wire == value } ?: USER
    }
}

enum class RustApprovalKind(val wire: String) {
    COMMAND("command"),
    FILE_CHANGE("fileChange"),
    PERMISSIONS("permissions"),
    MCP_ELICITATION("mcpElicitation"),
    ;

    companion object {
        fun from(value: String): RustApprovalKind =
            entries.firstOrNull { it.wire == value } ?: COMMAND
    }
}

enum class RustApprovalDecision(val wire: String) {
    APPROVE("approve"),
    DENY("deny"),
    ALWAYS_APPROVE("alwaysApprove"),
    ;

    companion object {
        fun from(value: String): RustApprovalDecision =
            entries.firstOrNull { it.wire == value } ?: DENY
    }
}

enum class RustTurnStatus(val wire: String) {
    RUNNING("running"),
    COMPLETED("completed"),
    FAILED("failed"),
    ;

    companion object {
        fun from(value: String): RustTurnStatus =
            entries.firstOrNull { it.wire == value } ?: RUNNING
    }
}

// ---------------------------------------------------------------------------
// Models — mirror Rust `codex-mobile-client/src/types/models.rs`
// ---------------------------------------------------------------------------

/**
 * Mirrors Rust `ThreadInfo`.
 *
 * A flattened, mobile-friendly view of a thread summary.
 * JSON fields use camelCase (matching `serde(rename_all = "camelCase")`).
 */
data class RustThreadInfo(
    val id: String,
    val title: String? = null,
    val model: String? = null,
    val status: RustThreadStatus = RustThreadStatus.NOT_LOADED,
    val preview: String? = null,
    val cwd: String? = null,
    val createdAt: Long? = null,
    val updatedAt: Long? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustThreadInfo =
            RustThreadInfo(
                id = obj.getString("id"),
                title = obj.optString("title", null),
                model = obj.optString("model", null),
                status = RustThreadStatus.from(obj.optString("status", "notLoaded")),
                preview = obj.optString("preview", null),
                cwd = obj.optString("cwd", null),
                createdAt = if (obj.has("createdAt") && !obj.isNull("createdAt")) obj.getLong("createdAt") else null,
                updatedAt = if (obj.has("updatedAt") && !obj.isNull("updatedAt")) obj.getLong("updatedAt") else null,
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("title", title ?: JSONObject.NULL)
        put("model", model ?: JSONObject.NULL)
        put("status", status.wire)
        put("preview", preview ?: JSONObject.NULL)
        put("cwd", cwd ?: JSONObject.NULL)
        put("createdAt", createdAt ?: JSONObject.NULL)
        put("updatedAt", updatedAt ?: JSONObject.NULL)
    }
}

/**
 * Mirrors Rust `CodexModel`.
 *
 * Reasoning efforts are a flat list of strings (e.g. ["low", "medium", "high"])
 * rather than the structured `ReasoningEffortOption` used in the old Android types.
 */
data class RustCodexModel(
    val id: String,
    val name: String,
    val model: String? = null,
    val provider: String? = null,
    val description: String? = null,
    val reasoningEfforts: List<String> = emptyList(),
    val defaultReasoningEffort: String? = null,
    val isDefault: Boolean = false,
    val hidden: Boolean = false,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustCodexModel =
            RustCodexModel(
                id = obj.getString("id"),
                name = obj.optString("name", ""),
                model = obj.optString("model", null),
                provider = obj.optString("provider", null),
                description = obj.optString("description", null),
                reasoningEfforts = obj.optJSONArray("reasoningEfforts")?.toStringList() ?: emptyList(),
                defaultReasoningEffort = obj.optString("defaultReasoningEffort", null),
                isDefault = obj.optBoolean("isDefault", false),
                hidden = obj.optBoolean("hidden", false),
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("model", model ?: JSONObject.NULL)
        put("provider", provider ?: JSONObject.NULL)
        put("description", description ?: JSONObject.NULL)
        put("reasoningEfforts", JSONArray(reasoningEfforts))
        put("defaultReasoningEffort", defaultReasoningEffort ?: JSONObject.NULL)
        put("isDefault", isDefault)
        put("hidden", hidden)
    }
}

/**
 * Mirrors Rust `ThreadKey`.
 *
 * Composite key identifying a thread on a specific server.
 */
data class RustThreadKey(
    val serverId: String,
    val threadId: String,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustThreadKey =
            RustThreadKey(
                serverId = obj.getString("serverId"),
                threadId = obj.getString("threadId"),
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("serverId", serverId)
        put("threadId", threadId)
    }
}

/**
 * Mirrors Rust `Attachment`.
 */
data class RustAttachment(
    val mimeType: String,
    val data: String,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustAttachment =
            RustAttachment(
                mimeType = obj.getString("mimeType"),
                data = obj.getString("data"),
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("mimeType", mimeType)
        put("data", data)
    }
}

/**
 * Mirrors Rust `RateLimits`.
 */
data class RustRateLimits(
    val requestsRemaining: Long? = null,
    val tokensRemaining: Long? = null,
    val resetAt: String? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustRateLimits =
            RustRateLimits(
                requestsRemaining = if (obj.has("requestsRemaining") && !obj.isNull("requestsRemaining")) obj.getLong("requestsRemaining") else null,
                tokensRemaining = if (obj.has("tokensRemaining") && !obj.isNull("tokensRemaining")) obj.getLong("tokensRemaining") else null,
                resetAt = obj.optString("resetAt", null),
            )
    }
}

// ---------------------------------------------------------------------------
// Request params — mirror Rust `codex-mobile-client/src/types/requests.rs`
// ---------------------------------------------------------------------------

/**
 * Mirrors Rust `ThreadStartParams`.
 */
data class RustThreadStartParams(
    val model: String? = null,
    val modelProvider: String? = null,
    val cwd: String? = null,
    val instructions: String? = null,
    val approvalPolicy: String? = null,
    val sandbox: RustSandboxMode? = null,
    val config: JSONObject? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("model", model ?: JSONObject.NULL)
        put("modelProvider", modelProvider ?: JSONObject.NULL)
        put("cwd", cwd ?: JSONObject.NULL)
        put("instructions", instructions ?: JSONObject.NULL)
        put("approvalPolicy", approvalPolicy ?: JSONObject.NULL)
        put("sandbox", sandbox?.wire ?: JSONObject.NULL)
        if (config != null) put("config", config)
    }
}

/**
 * Mirrors Rust `TurnStartParams`.
 */
data class RustTurnStartParams(
    val threadId: String,
    val prompt: String,
    val model: String? = null,
    val reasoningEffort: String? = null,
    val attachments: List<RustAttachment> = emptyList(),
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("threadId", threadId)
        put("prompt", prompt)
        put("model", model ?: JSONObject.NULL)
        put("reasoningEffort", reasoningEffort ?: JSONObject.NULL)
        put("attachments", JSONArray().apply {
            attachments.forEach { put(it.toJson()) }
        })
    }
}

// ---------------------------------------------------------------------------
// Server requests — mirror Rust `codex-mobile-client/src/types/server_requests.rs`
// ---------------------------------------------------------------------------

/**
 * Mirrors Rust `PendingApproval`.
 *
 * The `id` field is kept as [Any?] (String or Int on the wire) matching
 * Rust's `serde_json::Value`. In practice we store the raw JSON value
 * and propagate it back when responding.
 */
data class RustPendingApproval(
    val id: Any?,
    val kind: RustApprovalKind,
    val threadId: String? = null,
    val turnId: String? = null,
    val itemId: String? = null,
    val command: String? = null,
    val path: String? = null,
    val cwd: String? = null,
    val reason: String? = null,
    val rawParams: JSONObject = JSONObject(),
) {
    companion object {
        fun fromJson(obj: JSONObject): RustPendingApproval =
            RustPendingApproval(
                id = obj.opt("id"),
                kind = RustApprovalKind.from(obj.optString("kind", "command")),
                threadId = obj.optString("threadId", null),
                turnId = obj.optString("turnId", null),
                itemId = obj.optString("itemId", null),
                command = obj.optString("command", null),
                path = obj.optString("path", null),
                cwd = obj.optString("cwd", null),
                reason = obj.optString("reason", null),
                rawParams = obj.optJSONObject("rawParams") ?: JSONObject(),
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id ?: JSONObject.NULL)
        put("kind", kind.wire)
        put("threadId", threadId ?: JSONObject.NULL)
        put("turnId", turnId ?: JSONObject.NULL)
        put("itemId", itemId ?: JSONObject.NULL)
        put("command", command ?: JSONObject.NULL)
        put("path", path ?: JSONObject.NULL)
        put("cwd", cwd ?: JSONObject.NULL)
        put("reason", reason ?: JSONObject.NULL)
        put("rawParams", rawParams)
    }
}

// ---------------------------------------------------------------------------
// Notifications — mirror Rust `codex-mobile-client/src/types/notifications.rs`
// Modeled as a sealed class for exhaustive `when` handling.
// ---------------------------------------------------------------------------

/**
 * Mirrors Rust `ServerNotificationType` + `ServerNotificationWrapper`.
 *
 * Each known notification method becomes a subclass carrying typed accessors
 * (`threadId`, `turnId`, etc.) extracted from [rawParams].
 * Unknown methods map to [Other].
 */
sealed class RustUiEvent(
    val method: String,
    val rawParams: JSONObject,
) {
    // Convenience accessors matching Rust wrapper helpers.
    open val threadId: String? get() = rawParams.optString("threadId", null)
    open val turnId: String? get() = rawParams.optString("turnId", null)
    open val itemId: String? get() = rawParams.optString("itemId", null)

    // --- Thread lifecycle ---
    class ThreadStarted(params: JSONObject) : RustUiEvent("thread/started", params)
    class ThreadStatusChanged(params: JSONObject) : RustUiEvent("thread/status/changed", params) {
        val status: RustThreadStatus get() = RustThreadStatus.from(rawParams.optString("status", ""))
    }
    class ThreadArchived(params: JSONObject) : RustUiEvent("thread/archived", params)
    class ThreadUnarchived(params: JSONObject) : RustUiEvent("thread/unarchived", params)
    class ThreadClosed(params: JSONObject) : RustUiEvent("thread/closed", params)
    class ThreadNameUpdated(params: JSONObject) : RustUiEvent("thread/name/updated", params) {
        val name: String? get() = rawParams.optString("name", null)
    }
    class ThreadTokenUsageUpdated(params: JSONObject) : RustUiEvent("thread/tokenUsage/updated", params)

    // --- Turn lifecycle ---
    class TurnStarted(params: JSONObject) : RustUiEvent("turn/started", params)
    class TurnCompleted(params: JSONObject) : RustUiEvent("turn/completed", params) {
        val status: RustTurnStatus get() = RustTurnStatus.from(rawParams.optString("status", ""))
    }
    class TurnDiffUpdated(params: JSONObject) : RustUiEvent("turn/diff/updated", params)
    class TurnPlanUpdated(params: JSONObject) : RustUiEvent("turn/plan/updated", params)

    // --- Item lifecycle ---
    class ItemStarted(params: JSONObject) : RustUiEvent("item/started", params)
    class ItemCompleted(params: JSONObject) : RustUiEvent("item/completed", params)

    // --- Streaming deltas ---
    class AgentMessageDelta(params: JSONObject) : RustUiEvent("item/agentMessage/delta", params) {
        val delta: String? get() = rawParams.optString("delta", null)
    }
    class ReasoningTextDelta(params: JSONObject) : RustUiEvent("item/reasoning/textDelta", params) {
        val text: String? get() = rawParams.optString("text", null) ?: rawParams.optString("delta", null)
    }
    class ReasoningSummaryTextDelta(params: JSONObject) : RustUiEvent("item/reasoning/summaryTextDelta", params) {
        val text: String? get() = rawParams.optString("text", null) ?: rawParams.optString("delta", null)
    }
    class ReasoningSummaryPartAdded(params: JSONObject) : RustUiEvent("item/reasoning/summaryPartAdded", params)
    class PlanDelta(params: JSONObject) : RustUiEvent("item/plan/delta", params)
    class CommandExecOutputDelta(params: JSONObject) : RustUiEvent("command/exec/outputDelta", params)
    class CommandExecutionOutputDelta(params: JSONObject) : RustUiEvent("item/commandExecution/outputDelta", params)
    class FileChangeOutputDelta(params: JSONObject) : RustUiEvent("item/fileChange/outputDelta", params)

    // --- Realtime / voice ---
    class RealtimeStarted(params: JSONObject) : RustUiEvent("thread/realtime/started", params)
    class RealtimeItemAdded(params: JSONObject) : RustUiEvent("thread/realtime/itemAdded", params)
    class RealtimeAudioDelta(params: JSONObject) : RustUiEvent("thread/realtime/outputAudio/delta", params)
    class RealtimeError(params: JSONObject) : RustUiEvent("thread/realtime/error", params) {
        val errorMessage: String? get() = rawParams.optString("message", null)
    }
    class RealtimeClosed(params: JSONObject) : RustUiEvent("thread/realtime/closed", params)

    // --- Account / system ---
    class AccountUpdated(params: JSONObject) : RustUiEvent("account/updated", params)
    class AccountRateLimitsUpdated(params: JSONObject) : RustUiEvent("account/rateLimits/updated", params)
    class AccountLoginCompleted(params: JSONObject) : RustUiEvent("account/login/completed", params)

    // --- Errors ---
    class Error(params: JSONObject) : RustUiEvent("error", params) {
        val errorMessage: String?
            get() = rawParams.optString("message", null)
                ?: rawParams.optJSONObject("error")?.optString("message", null)
    }

    // --- Hooks ---
    class HookStarted(params: JSONObject) : RustUiEvent("hook/started", params)
    class HookCompleted(params: JSONObject) : RustUiEvent("hook/completed", params)

    // --- Other ---
    class ContextCompacted(params: JSONObject) : RustUiEvent("thread/compacted", params)
    class ModelRerouted(params: JSONObject) : RustUiEvent("model/rerouted", params)
    class DeprecationNotice(params: JSONObject) : RustUiEvent("deprecationNotice", params)
    class ConfigWarning(params: JSONObject) : RustUiEvent("configWarning", params)
    class SkillsChanged(params: JSONObject) : RustUiEvent("skills/changed", params)
    class McpToolCallProgress(params: JSONObject) : RustUiEvent("item/mcpToolCall/progress", params)
    class McpServerOauthLoginCompleted(params: JSONObject) : RustUiEvent("mcpServer/oauthLogin/completed", params)
    class ServerRequestResolved(params: JSONObject) : RustUiEvent("serverRequest/resolved", params)

    /** Unknown / future notification type. */
    class Other(method: String, params: JSONObject) : RustUiEvent(method, params)

    companion object {
        /**
         * Parse a notification from its wire method string and raw params JSON.
         * Returns the appropriate typed [RustUiEvent] subclass.
         */
        fun fromNotification(method: String, params: JSONObject): RustUiEvent =
            when (method) {
                "thread/started" -> ThreadStarted(params)
                "thread/status/changed" -> ThreadStatusChanged(params)
                "thread/archived" -> ThreadArchived(params)
                "thread/unarchived" -> ThreadUnarchived(params)
                "thread/closed" -> ThreadClosed(params)
                "thread/name/updated" -> ThreadNameUpdated(params)
                "thread/tokenUsage/updated" -> ThreadTokenUsageUpdated(params)
                "turn/started" -> TurnStarted(params)
                "turn/completed" -> TurnCompleted(params)
                "turn/diff/updated" -> TurnDiffUpdated(params)
                "turn/plan/updated" -> TurnPlanUpdated(params)
                "item/started" -> ItemStarted(params)
                "item/completed" -> ItemCompleted(params)
                "item/agentMessage/delta" -> AgentMessageDelta(params)
                "item/reasoning/textDelta" -> ReasoningTextDelta(params)
                "item/reasoning/summaryTextDelta" -> ReasoningSummaryTextDelta(params)
                "item/reasoning/summaryPartAdded" -> ReasoningSummaryPartAdded(params)
                "item/plan/delta" -> PlanDelta(params)
                "command/exec/outputDelta" -> CommandExecOutputDelta(params)
                "item/commandExecution/outputDelta" -> CommandExecutionOutputDelta(params)
                "item/fileChange/outputDelta" -> FileChangeOutputDelta(params)
                "thread/realtime/started" -> RealtimeStarted(params)
                "thread/realtime/itemAdded" -> RealtimeItemAdded(params)
                "thread/realtime/outputAudio/delta" -> RealtimeAudioDelta(params)
                "thread/realtime/error" -> RealtimeError(params)
                "thread/realtime/closed" -> RealtimeClosed(params)
                "account/updated" -> AccountUpdated(params)
                "account/rateLimits/updated" -> AccountRateLimitsUpdated(params)
                "account/login/completed" -> AccountLoginCompleted(params)
                "error" -> Error(params)
                "hook/started" -> HookStarted(params)
                "hook/completed" -> HookCompleted(params)
                "thread/compacted" -> ContextCompacted(params)
                "model/rerouted" -> ModelRerouted(params)
                "deprecationNotice" -> DeprecationNotice(params)
                "configWarning" -> ConfigWarning(params)
                "skills/changed" -> SkillsChanged(params)
                "item/mcpToolCall/progress" -> McpToolCallProgress(params)
                "mcpServer/oauthLogin/completed" -> McpServerOauthLoginCompleted(params)
                "serverRequest/resolved" -> ServerRequestResolved(params)
                else -> Other(method, params)
            }
    }
}

// ---------------------------------------------------------------------------
// Tool call card — convenience type for rendering approval UI.
// ---------------------------------------------------------------------------

/**
 * Convenience type for rendering a tool-call approval card in the UI.
 *
 * This doesn't directly mirror a single Rust struct but aggregates fields
 * from [RustPendingApproval] into a presentation-ready form.
 */
data class RustToolCallCard(
    val approvalId: Any?,
    val kind: RustApprovalKind,
    val title: String,
    val subtitle: String? = null,
    val command: String? = null,
    val path: String? = null,
    val cwd: String? = null,
) {
    companion object {
        fun fromApproval(approval: RustPendingApproval): RustToolCallCard {
            val title = when (approval.kind) {
                RustApprovalKind.COMMAND -> "Run command"
                RustApprovalKind.FILE_CHANGE -> "Apply file change"
                RustApprovalKind.PERMISSIONS -> "Grant permissions"
                RustApprovalKind.MCP_ELICITATION -> "MCP elicitation"
            }
            return RustToolCallCard(
                approvalId = approval.id,
                kind = approval.kind,
                title = title,
                subtitle = approval.reason,
                command = approval.command,
                path = approval.path,
                cwd = approval.cwd,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Discovered server — bridge type for servers surfaced through FFI.
// ---------------------------------------------------------------------------

/**
 * A server discovered via FFI (e.g. mDNS, Tailscale, manual entry).
 *
 * This is a thin bridge type; the full `ServerConfig` in StateModels.kt
 * carries additional fields for saved state.
 */
data class RustDiscoveredServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: String,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustDiscoveredServer =
            RustDiscoveredServer(
                id = obj.getString("id"),
                name = obj.optString("name", ""),
                host = obj.getString("host"),
                port = obj.getInt("port"),
                source = obj.optString("source", "manual"),
            )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("host", host)
        put("port", port)
        put("source", source)
    }
}

// ---------------------------------------------------------------------------
// Response types — mirror Rust `codex-mobile-client/src/types/responses.rs`
// ---------------------------------------------------------------------------

data class RustThreadStartResponse(
    val thread: RustThreadInfo,
    val model: String? = null,
    val modelProvider: String? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustThreadStartResponse =
            RustThreadStartResponse(
                thread = RustThreadInfo.fromJson(obj.getJSONObject("thread")),
                model = obj.optString("model", null),
                modelProvider = obj.optString("modelProvider", null),
            )
    }
}

data class RustThreadResumeResponse(
    val thread: RustThreadInfo,
    val model: String? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustThreadResumeResponse =
            RustThreadResumeResponse(
                thread = RustThreadInfo.fromJson(obj.getJSONObject("thread")),
                model = obj.optString("model", null),
            )
    }
}

data class RustThreadListResponse(
    val threads: List<RustThreadInfo>,
    val cursor: String? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustThreadListResponse =
            RustThreadListResponse(
                threads = obj.getJSONArray("threads").toList { RustThreadInfo.fromJson(it) },
                cursor = obj.optString("cursor", null),
            )
    }
}

data class RustModelListResponse(
    val models: List<RustCodexModel>,
    val cursor: String? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): RustModelListResponse =
            RustModelListResponse(
                models = obj.getJSONArray("models").toList { RustCodexModel.fromJson(it) },
                cursor = obj.optString("cursor", null),
            )
    }
}

data class RustInitializeResponse(
    val serverVersion: String? = null,
    val platformFamily: String? = null,
    val platformOs: String? = null,
    val capabilities: JSONObject = JSONObject(),
) {
    companion object {
        fun fromJson(obj: JSONObject): RustInitializeResponse =
            RustInitializeResponse(
                serverVersion = obj.optString("serverVersion", null),
                platformFamily = obj.optString("platformFamily", null),
                platformOs = obj.optString("platformOs", null),
                capabilities = obj.optJSONObject("capabilities") ?: JSONObject(),
            )
    }
}

data class RustTurnStartResponse(
    val raw: JSONObject = JSONObject(),
) {
    companion object {
        fun fromJson(obj: JSONObject): RustTurnStartResponse =
            RustTurnStartResponse(raw = obj)
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/** Convert a [JSONArray] of strings to a [List]. */
internal fun JSONArray.toStringList(): List<String> {
    val result = ArrayList<String>(length())
    for (i in 0 until length()) {
        result.add(optString(i, ""))
    }
    return result
}

/** Convert a [JSONArray] of JSONObjects using the given mapper. */
internal fun <T> JSONArray.toList(mapper: (JSONObject) -> T): List<T> {
    val result = ArrayList<T>(length())
    for (i in 0 until length()) {
        result.add(mapper(getJSONObject(i)))
    }
    return result
}
