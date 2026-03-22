package com.litter.android.core.bridge

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

// ---------------------------------------------------------------------------
// Intermediate types matching the Rust `parse_tool_calls` JSON output.
// These are module-public so the app layer can map them to its own UI types.
// ---------------------------------------------------------------------------

enum class RustToolCallKind(val jsonName: String) {
    COMMAND_EXECUTION("commandExecution"),
    COMMAND_OUTPUT("commandOutput"),
    FILE_CHANGE("fileChange"),
    FILE_DIFF("fileDiff"),
    MCP_TOOL_CALL("mcpToolCall"),
    MCP_TOOL_PROGRESS("mcpToolProgress"),
    WEB_SEARCH("webSearch"),
    COLLABORATION("collaboration"),
    IMAGE_VIEW("imageView"),
    ;

    companion object {
        private val byJson = entries.associateBy { it.jsonName }
        fun fromJson(value: String): RustToolCallKind? = byJson[value]
    }
}

enum class RustToolCallStatus(val jsonName: String) {
    IN_PROGRESS("inProgress"),
    COMPLETED("completed"),
    FAILED("failed"),
    UNKNOWN("unknown"),
    ;

    companion object {
        private val byJson = entries.associateBy { it.jsonName }
        fun fromJson(value: String): RustToolCallStatus = byJson[value] ?: UNKNOWN
    }
}

data class RustToolCallKeyValue(
    val key: String,
    val value: String,
)

sealed interface RustToolCallSection {
    val label: String

    data class KeyValue(
        override val label: String,
        val entries: List<RustToolCallKeyValue>,
    ) : RustToolCallSection

    data class Code(
        override val label: String,
        val language: String,
        val content: String,
    ) : RustToolCallSection

    data class Json(
        override val label: String,
        val content: String,
    ) : RustToolCallSection

    data class Diff(
        override val label: String,
        val content: String,
    ) : RustToolCallSection

    data class Text(
        override val label: String,
        val content: String,
    ) : RustToolCallSection

    data class ListSection(
        override val label: String,
        val items: List<String>,
    ) : RustToolCallSection

    data class Progress(
        override val label: String,
        val items: List<String>,
    ) : RustToolCallSection
}

data class RustToolCallCardModel(
    val kind: RustToolCallKind,
    val title: String,
    val summary: String,
    val status: RustToolCallStatus,
    val duration: String?,
    val sections: List<RustToolCallSection>,
)

/**
 * Bridge to the Rust tool call parser via [RustMobileClient].
 *
 * Calls `parse_tool_calls` on the Rust side, deserializes the JSON response,
 * and returns [RustToolCallCardModel] instances that the app layer can map
 * to its own UI types.
 *
 * Returns `null` on any FFI or deserialization failure so the caller can
 * fall back to the existing Kotlin [ToolCallMessageParser][com.litter.android.ui.ToolCallMessageParser].
 */
object RustToolCallParser {

    /**
     * The [RustMobileClient] instance to use for FFI calls.
     * Must be set during app initialization before calling [parse].
     */
    var client: RustMobileClient? = null

    /**
     * Parse tool call text via the Rust FFI parser.
     *
     * @param text The raw system message text (e.g. starting with `### ...`).
     * @return A parsed [RustToolCallCardModel], or `null` if the Rust parser
     *         could not parse it (caller should fall back to Kotlin parser).
     */
    fun parse(text: String): RustToolCallCardModel? {
        val rustClient = client ?: return null
        if (!rustClient.isInitialized) return null

        return try {
            val result = runBlocking {
                withTimeoutOrNull(500L) {
                    rustClient.call(
                        method = "parse_tool_calls",
                        params = JSONObject().put("text", text),
                    )
                }
            } ?: return null

            // The MobileClient wraps the result array under "value"
            val cardsArray: JSONArray = result.optJSONArray("value") ?: return null
            if (cardsArray.length() == 0) return null

            // Tool call messages produce one card.
            val cardJson = cardsArray.optJSONObject(0) ?: return null
            mapRustCard(cardJson)
        } catch (_: Exception) {
            null
        }
    }

    // -----------------------------------------------------------------------
    // JSON → intermediate type mapping
    // -----------------------------------------------------------------------

    private fun mapRustCard(json: JSONObject): RustToolCallCardModel? {
        val kind = mapKind(json) ?: return null
        val title = json.optString("title", "").ifBlank { return null }
        val status = RustToolCallStatus.fromJson(json.optString("status", "unknown"))
        val summary = json.optString("summary", title).ifBlank { title }

        val durationMs = if (json.has("duration") && !json.isNull("duration")) {
            json.optLong("duration", -1L).takeIf { it >= 0 }
        } else {
            null
        }
        val durationString = durationMs?.let { formatDuration(it) }

        val sectionsArray = json.optJSONArray("sections") ?: JSONArray()
        val sections = buildList {
            for (i in 0 until sectionsArray.length()) {
                val sectionJson = sectionsArray.optJSONObject(i) ?: continue
                val section = mapSection(sectionJson)
                if (section != null) add(section)
            }
        }

        return RustToolCallCardModel(
            kind = kind,
            title = title,
            summary = summary,
            status = status,
            duration = durationString,
            sections = sections,
        )
    }

    private fun mapKind(json: JSONObject): RustToolCallKind? {
        val raw = json.opt("kind") ?: return null
        return when (raw) {
            is String -> RustToolCallKind.fromJson(raw)
            else -> null // Unknown kind or object form → not supported
        }
    }

    private fun mapSection(json: JSONObject): RustToolCallSection? {
        val name = json.optString("name", "").ifBlank { return null }
        val content = json.optJSONObject("content") ?: return null
        val type = content.optString("type", "")

        return when (type) {
            "keyValue" -> {
                val items = findArrayInContent(content) ?: return null
                val entries = buildList {
                    for (i in 0 until items.length()) {
                        val pair = items.optJSONArray(i) ?: continue
                        if (pair.length() >= 2) {
                            add(RustToolCallKeyValue(
                                key = pair.optString(0, ""),
                                value = pair.optString(1, ""),
                            ))
                        }
                    }
                }
                RustToolCallSection.KeyValue(label = name, entries = entries)
            }

            "code" -> RustToolCallSection.Code(
                label = name,
                language = content.optString("language", ""),
                content = content.optString("code", ""),
            )

            "json" -> {
                val value = findNonTypeValue(content)
                RustToolCallSection.Json(label = name, content = value?.toString() ?: "{}")
            }

            "diff" -> RustToolCallSection.Diff(
                label = name,
                content = findNonTypeString(content),
            )

            "text" -> RustToolCallSection.Text(
                label = name,
                content = findNonTypeString(content),
            )

            "list" -> {
                val items = findArrayInContent(content) ?: return null
                val list = buildList {
                    for (i in 0 until items.length()) {
                        add(items.optString(i, ""))
                    }
                }
                RustToolCallSection.ListSection(label = name, items = list)
            }

            "progress" -> {
                val current = content.optLong("current", 0)
                val total = content.optLong("total", 0)
                val label = content.optString("label", null)
                val prefix = if (label != null) "$label: " else ""
                RustToolCallSection.Progress(
                    label = name,
                    items = listOf("$prefix$current/$total"),
                )
            }

            else -> null
        }
    }

    // -----------------------------------------------------------------------
    // JSON helpers
    // -----------------------------------------------------------------------

    /**
     * Find the first JSONArray value whose key is not "type".
     * Serde's tagged enum puts the data under the variant name key.
     */
    private fun findArrayInContent(content: JSONObject): JSONArray? {
        val keys = content.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (key == "type") continue
            val arr = content.optJSONArray(key)
            if (arr != null) return arr
        }
        return null
    }

    private fun findNonTypeString(content: JSONObject): String {
        val keys = content.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (key == "type") continue
            val str = content.optString(key, null)
            if (str != null) return str
        }
        return ""
    }

    private fun findNonTypeValue(content: JSONObject): Any? {
        val keys = content.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (key == "type") continue
            return content.opt(key)
        }
        return null
    }

    private fun formatDuration(ms: Long): String {
        val seconds = ms / 1000.0
        return when {
            seconds < 1.0 -> "${ms}ms"
            seconds < 60.0 -> String.format("%.1fs", seconds)
            else -> {
                val minutes = (seconds / 60).toInt()
                val remainingSecs = (seconds % 60).toInt()
                "${minutes}m ${remainingSecs}s"
            }
        }
    }
}
