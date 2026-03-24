package com.litter.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent

/**
 * A group of conversation items belonging to the same turn.
 */
data class TranscriptTurn(
    val turnId: String?,
    val items: List<HydratedConversationItem>,
    val isActiveTurn: Boolean,
) {
    val userPrompt: String?
        get() = items.firstOrNull { it.content is HydratedConversationItemContent.User }
            ?.let { (it.content as HydratedConversationItemContent.User).v1.text }

    val assistantSnippet: String?
        get() = items.lastOrNull { it.content is HydratedConversationItemContent.Assistant }
            ?.let { (it.content as HydratedConversationItemContent.Assistant).v1.text }
            ?.take(120)

    val commandCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.CommandExecution }

    val fileChangeCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.FileChange }

    val totalDurationMs: Long
        get() = items.sumOf {
            when (val c = it.content) {
                is HydratedConversationItemContent.CommandExecution -> c.v1.durationMs ?: 0L
                else -> 0L
            }
        }
}

/**
 * Groups a flat list of hydrated items into turns by [sourceTurnId].
 */
fun groupIntoTurns(
    items: List<HydratedConversationItem>,
    activeTurnId: String?,
): List<TranscriptTurn> {
    if (items.isEmpty()) return emptyList()

    val turns = mutableListOf<TranscriptTurn>()
    var currentTurnId: String? = items.first().sourceTurnId
    var currentItems = mutableListOf<HydratedConversationItem>()

    for (item in items) {
        if (item.sourceTurnId != currentTurnId && currentItems.isNotEmpty()) {
            turns.add(TranscriptTurn(
                turnId = currentTurnId,
                items = currentItems.toList(),
                isActiveTurn = currentTurnId == activeTurnId,
            ))
            currentTurnId = item.sourceTurnId
            currentItems = mutableListOf()
        }
        currentItems.add(item)
    }
    if (currentItems.isNotEmpty()) {
        turns.add(TranscriptTurn(
            turnId = currentTurnId,
            items = currentItems.toList(),
            isActiveTurn = currentTurnId == activeTurnId,
        ))
    }

    return turns
}

/**
 * Renders a collapsed turn card with preview and metadata.
 * Tap to expand and show all items.
 */
@Composable
fun CollapsedTurnCard(
    turn: TranscriptTurn,
    onExpand: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onExpand)
            .padding(10.dp),
    ) {
        // User prompt preview
        turn.userPrompt?.let { prompt ->
            Text(
                text = prompt,
                color = LitterTheme.textPrimary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Assistant snippet
        turn.assistantSnippet?.let { snippet ->
            Text(
                text = snippet,
                color = LitterTheme.textSecondary,
                fontSize = 12.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }

        // Metadata footer
        Row(
            modifier = Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (turn.commandCount > 0) {
                MetadataBadge("${turn.commandCount} cmd", LitterTheme.toolCallCommand)
            }
            if (turn.fileChangeCount > 0) {
                MetadataBadge("${turn.fileChangeCount} files", LitterTheme.toolCallFileChange)
            }
            if (turn.totalDurationMs > 0) {
                val dur = if (turn.totalDurationMs < 1000) "${turn.totalDurationMs}ms"
                else "%.1fs".format(turn.totalDurationMs / 1000.0)
                MetadataBadge(dur, LitterTheme.textMuted)
            }
            Spacer(Modifier.weight(1f))
            Text("Tap to expand", color = LitterTheme.textMuted, fontSize = 10.sp)
        }
    }
}

@Composable
private fun MetadataBadge(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(
        text = text,
        color = color,
        fontSize = 10.sp,
        fontWeight = FontWeight.Medium,
    )
}

/**
 * Groups consecutive CommandExecution items with empty/null output
 * into a collapsed "Explored N locations" row.
 */
data class ExplorationGroup(
    val items: List<HydratedConversationItem>,
)

/**
 * Detects exploration groups in a list of items within a single turn.
 * Returns a mixed list of either individual items or exploration groups.
 */
sealed class TimelineEntry {
    data class Single(val item: HydratedConversationItem) : TimelineEntry()
    data class Exploration(val group: ExplorationGroup) : TimelineEntry()
}

fun buildTimelineEntries(items: List<HydratedConversationItem>): List<TimelineEntry> {
    val result = mutableListOf<TimelineEntry>()
    var explorationRun = mutableListOf<HydratedConversationItem>()

    fun flushExploration() {
        if (explorationRun.size >= 3) {
            result.add(TimelineEntry.Exploration(ExplorationGroup(explorationRun.toList())))
        } else {
            explorationRun.forEach { result.add(TimelineEntry.Single(it)) }
        }
        explorationRun = mutableListOf()
    }

    for (item in items) {
        val content = item.content
        if (content is HydratedConversationItemContent.CommandExecution &&
            content.v1.output.isNullOrBlank()
        ) {
            explorationRun.add(item)
        } else {
            flushExploration()
            result.add(TimelineEntry.Single(item))
        }
    }
    flushExploration()
    return result
}

/**
 * Renders an exploration group as a collapsible summary.
 */
@Composable
fun ExplorationGroupRow(group: ExplorationGroup) {
    var expanded by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .clickable { expanded = !expanded }
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (expanded) "▼" else "▶",
                color = LitterTheme.textMuted,
                fontSize = 12.sp,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = "Explored ${group.items.size} locations",
                color = LitterTheme.textSecondary,
                fontSize = 12.sp,
            )
        }

        if (expanded) {
            for (item in group.items) {
                val cmd = (item.content as HydratedConversationItemContent.CommandExecution).v1
                Text(
                    text = "$ ${cmd.command}",
                    color = LitterTheme.toolCallCommand,
                    fontSize = 11.sp,
                    fontFamily = com.litter.android.ui.LitterTheme.monoFont,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 24.dp, top = 2.dp),
                )
            }
        }
    }
}
