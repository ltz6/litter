package com.litter.android.ui.conversation

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import android.graphics.BitmapFactory
import android.text.method.LinkMovementMethod
import android.util.Base64
import android.widget.TextView
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedPlanStepStatus

/**
 * Renders a single [HydratedConversationItem] by matching on its content type.
 * Uses Rust-provided types directly — no intermediate model conversion.
 */
@Composable
fun ConversationTimelineItem(
    item: HydratedConversationItem,
    isLiveTurn: Boolean = false,
    onEditMessage: ((UInt) -> Unit)? = null,
    onForkFromMessage: ((UInt) -> Unit)? = null,
) {
    when (val content = item.content) {
        is HydratedConversationItemContent.User -> UserMessageRow(
            data = content.v1,
            turnIndex = item.sourceTurnIndex ?: 0u,
            onEdit = onEditMessage,
            onFork = onForkFromMessage,
        )

        is HydratedConversationItemContent.Assistant -> AssistantMessageRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Reasoning -> ReasoningRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.CommandExecution -> CommandExecutionRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.FileChange -> FileChangeRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TurnDiff -> TurnDiffRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TodoList -> TodoListRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.ProposedPlan -> ProposedPlanRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.McpToolCall -> McpToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.DynamicToolCall -> DynamicToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.MultiAgentAction -> {
            SubagentCard(data = content.v1)
        }

        is HydratedConversationItemContent.WebSearch -> WebSearchRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Divider -> DividerRow(
            data = content.v1,
            isLiveTurn = isLiveTurn,
        )

        is HydratedConversationItemContent.Error -> ErrorRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Note -> NoteRow(
            data = content.v1,
        )
    }
}

// ── User Message ─────────────────────────────────────────────────────────────

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun UserMessageRow(
    data: uniffi.codex_mobile_client.HydratedUserMessageData,
    turnIndex: UInt,
    onEdit: ((UInt) -> Unit)?,
    onFork: ((UInt) -> Unit)?,
) {
    var showMenu by remember { mutableStateOf(false) }

    Box {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                .then(
                    if (onEdit != null || onFork != null) {
                        Modifier.combinedClickable(
                            onClick = {},
                            onLongClick = { showMenu = true },
                        )
                    } else {
                        Modifier
                    }
                )
                .padding(10.dp),
        ) {
            Text(
                text = data.text,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.callout.scaled,
            )
        // Inline images from data URIs
        for (uri in data.imageDataUris) {
            val bitmap = remember(uri) {
                try {
                    val base64Part = uri.substringAfter("base64,", "")
                    if (base64Part.isNotEmpty()) {
                        val bytes = Base64.decode(base64Part, Base64.DEFAULT)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    } else null
                } catch (_: Exception) { null }
            }
            bitmap?.let {
                Image(
                    bitmap = it.asImageBitmap(),
                    contentDescription = "Attached image",
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .heightIn(max = 200.dp)
                        .clip(RoundedCornerShape(8.dp)),
                )
            }
        }
        }

        // Long-press context menu
        androidx.compose.material3.DropdownMenu(
            expanded = showMenu,
            onDismissRequest = { showMenu = false },
        ) {
            if (onEdit != null) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("Edit Message") },
                    onClick = { showMenu = false; onEdit(turnIndex) },
                )
            }
            if (onFork != null) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("Fork From Here") },
                    onClick = { showMenu = false; onFork(turnIndex) },
                )
            }
        }
    }
}

// ── Assistant Message ────────────────────────────────────────────────────────

@Composable
private fun AssistantMessageRow(
    data: uniffi.codex_mobile_client.HydratedAssistantMessageData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        // Agent badge
        if (data.agentNickname != null || data.agentRole != null) {
            val label = buildString {
                data.agentNickname?.let { append(it) }
                data.agentRole?.let {
                    if (isNotEmpty()) append(" ")
                    append("[$it]")
                }
            }
            Text(
                text = label,
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(2.dp))
        }

        MarkdownText(text = data.text)
    }
}

// ── Reasoning ────────────────────────────────────────────────────────────────

@Composable
private fun ReasoningRow(
    data: uniffi.codex_mobile_client.HydratedReasoningData,
) {
    var expanded by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded }
            .padding(vertical = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = if (expanded) "▼ " else "▶ ",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
            )
            Text(
                text = "Reasoning",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
                fontStyle = FontStyle.Italic,
            )
            if (!expanded && data.summary.isNotEmpty()) {
                Spacer(Modifier.width(6.dp))
                Text(
                    text = data.summary.joinToString(" "),
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption2.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
        }

        if (expanded) {
            Text(
                text = data.content.joinToString("\n"),
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontStyle = FontStyle.Italic,
                modifier = Modifier
                    .padding(top = 4.dp)
                    .animateContentSize(),
            )
        }
    }
}

// ── Command Execution ────────────────────────────────────────────────────────

@Composable
private fun CommandExecutionRow(
    data: uniffi.codex_mobile_client.HydratedCommandExecutionData,
) {
    var expanded by remember { mutableStateOf(true) }
    val outputText =
        data.output
            ?.trim('\n')
            ?.takeIf { it.isNotBlank() }
            ?: if (data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS) {
                "Waiting for output…"
            } else {
                null
            }
    val metadata = mutableListOf<Pair<String, String>>()
    if (data.cwd.isNotBlank()) {
        metadata.add("Directory" to data.cwd)
    }
    data.processId?.takeIf { it.isNotBlank() }?.let { processId ->
        metadata.add("Process ID" to processId)
    }
    data.exitCode?.let { exitCode ->
        metadata.add("Exit Code" to exitCode.toString())
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .clickable { expanded = !expanded }
            .padding(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(data.status)
            Spacer(Modifier.width(6.dp))
            Text(
                text = data.command,
                color = LitterTheme.toolCallCommand,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption.scaled,
                maxLines = if (expanded) Int.MAX_VALUE else 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            data.durationMs?.let { ms ->
                Spacer(Modifier.width(6.dp))
                Text(
                    text = formatDuration(ms),
                    color = LitterTheme.textMuted,
                    fontSize = 10.sp,
                )
            }
        }

        if (expanded) {
            if (metadata.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                SectionLabel("Metadata")
                Column(
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(6.dp))
                        .padding(8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    metadata.forEach { entry ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = "${entry.first}:",
                                color = LitterTheme.textSecondary,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = entry.second,
                                color = LitterTheme.textPrimary,
                                fontSize = 10.sp,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            outputText?.let { output ->
                Spacer(Modifier.height(8.dp))
                SectionLabel("Output")
                Text(
                    text = output,
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = LitterTextStyle.caption2.scaled,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .fillMaxWidth()
                        .heightIn(max = 200.dp)
                        .verticalScroll(rememberScrollState())
                        .background(LitterTheme.codeBackground, RoundedCornerShape(6.dp))
                        .padding(8.dp),
                )
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = LitterTheme.textSecondary,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
    )
}

// ── File Change ──────────────────────────────────────────────────────────────

@Composable
private fun FileChangeRow(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(data.status)
            Spacer(Modifier.width(6.dp))
            Text(
                text = "File changes",
                color = LitterTheme.toolCallFileChange,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.Medium,
            )
        }

        for (change in data.changes) {
            Spacer(Modifier.height(4.dp))
            Text(
                text = "${change.kind}: ${change.path}",
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption2.scaled,
            )
            change.diff?.let { diff ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 200.dp)
                        .verticalScroll(rememberScrollState())
                        .background(LitterTheme.codeBackground, RoundedCornerShape(4.dp))
                        .padding(4.dp),
                ) {
                    Column {
                        for (line in diff.lines()) {
                            val color = when {
                                line.startsWith("+") -> Color(0xFF4EC990)
                                line.startsWith("-") -> Color(0xFFE06C75)
                                else -> LitterTheme.textMuted
                            }
                            Text(
                                text = line,
                                color = color,
                                fontFamily = LitterTheme.monoFont,
                                fontSize = 10.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Todo List ────────────────────────────────────────────────────────────────

@Composable
private fun TodoListRow(
    data: uniffi.codex_mobile_client.HydratedTodoListData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        for (step in data.steps) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(vertical = 1.dp),
            ) {
                val icon = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> "✓"
                    HydratedPlanStepStatus.IN_PROGRESS -> "●"
                    HydratedPlanStepStatus.PENDING -> "○"
                }
                val color = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> LitterTheme.success
                    HydratedPlanStepStatus.IN_PROGRESS -> LitterTheme.accent
                    HydratedPlanStepStatus.PENDING -> LitterTheme.textMuted
                }
                Text(text = icon, color = color, fontSize = LitterTextStyle.footnote.scaled)
                Spacer(Modifier.width(6.dp))
                Text(
                    text = step.step,
                    color = LitterTheme.textBody,
                    fontSize = LitterTextStyle.footnote.scaled,
                )
            }
        }
    }
}

// ── Proposed Plan ────────────────────────────────────────────────────────────

@Composable
private fun ProposedPlanRow(
    data: uniffi.codex_mobile_client.HydratedProposedPlanData,
) {
    Text(
        text = data.content,
        color = LitterTheme.textBody,
        fontSize = LitterTextStyle.footnote.scaled,
        modifier = Modifier.padding(vertical = 4.dp),
    )
}

// ── MCP Tool Call ────────────────────────────────────────────────────────────

@Composable
private fun McpToolCallRow(
    data: uniffi.codex_mobile_client.HydratedMcpToolCallData,
) {
    var expanded by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .clickable { expanded = !expanded }
            .padding(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(data.status)
            Spacer(Modifier.width(6.dp))
            Text(
                text = "${data.server}: ${data.tool}",
                color = LitterTheme.toolCallMcpCall,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (expanded) {
            data.argumentsJson?.let { args ->
                Text(
                    text = args,
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 10.sp,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .background(LitterTheme.codeBackground, RoundedCornerShape(4.dp))
                        .padding(4.dp),
                )
            }
            data.contentSummary?.let { summary ->
                Text(
                    text = summary,
                    color = LitterTheme.textBody,
                    fontSize = LitterTextStyle.caption.scaled,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            data.errorMessage?.let { err ->
                Text(
                    text = err,
                    color = LitterTheme.danger,
                    fontSize = LitterTextStyle.caption.scaled,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

// ── Dynamic Tool Call ────────────────────────────────────────────────────────

@Composable
private fun DynamicToolCallRow(
    data: uniffi.codex_mobile_client.HydratedDynamicToolCallData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(data.status)
            Spacer(Modifier.width(6.dp))
            Text(
                text = data.tool,
                color = LitterTheme.toolCallMcpCall,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.Medium,
            )
        }
        data.contentSummary?.let { summary ->
            Text(
                text = summary,
                color = LitterTheme.textBody,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

// ── Web Search ───────────────────────────────────────────────────────────────

@Composable
private fun WebSearchRow(
    data: uniffi.codex_mobile_client.HydratedWebSearchData,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (data.isInProgress) {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = LitterTheme.toolCallWebSearch,
            )
        } else {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = null,
                tint = LitterTheme.toolCallWebSearch,
                modifier = Modifier.size(14.dp),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(
            text = "Web search: ${data.query}",
            color = LitterTheme.toolCallWebSearch,
            fontSize = LitterTextStyle.caption.scaled,
        )
    }
}

// ── Divider ──────────────────────────────────────────────────────────────────

@Composable
private fun TurnDiffRow(
    data: uniffi.codex_mobile_client.HydratedTurnDiffData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = "Turn Diff",
            color = LitterTheme.toolCallFileChange,
            fontSize = LitterTextStyle.caption.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = data.diff,
            color = LitterTheme.textSecondary,
            fontFamily = LitterTheme.monoFont,
            fontSize = LitterTextStyle.caption2.scaled,
            modifier = Modifier
                .padding(top = 4.dp)
                .fillMaxWidth()
                .heightIn(max = 220.dp)
                .verticalScroll(rememberScrollState())
                .background(LitterTheme.codeBackground, RoundedCornerShape(6.dp))
                .padding(8.dp),
        )
    }
}

@Composable
private fun DividerRow(
    data: uniffi.codex_mobile_client.HydratedDividerData,
    isLiveTurn: Boolean,
) {
    val label = when (data) {
        is uniffi.codex_mobile_client.HydratedDividerData.ContextCompaction ->
            if (data.isComplete && !isLiveTurn) "Context compacted" else "Compacting context\u2026"
        is uniffi.codex_mobile_client.HydratedDividerData.ModelRerouted -> {
            val route = data.fromModel?.takeIf { it.isNotBlank() }?.let { "$it -> ${data.toModel}" }
                ?: "Routed to ${data.toModel}"
            val reason = data.reason?.takeIf { it.isNotBlank() }
            if (reason != null) "$route | $reason" else route
        }
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewEntered -> "Review started"
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewExited -> "Review ended"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
        Text(
            text = "  $label  ",
            color = LitterTheme.textMuted,
            fontSize = 10.sp,
        )
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
    }
}

// ── Note ─────────────────────────────────────────────────────────────────────

@Composable
private fun NoteRow(
    data: uniffi.codex_mobile_client.HydratedNoteData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = data.title,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        if (data.body.isNotBlank()) {
            Text(
                text = data.body,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun ErrorRow(
    data: uniffi.codex_mobile_client.HydratedErrorData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = data.title.ifBlank { "Error" },
            color = LitterTheme.danger,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        Text(
            text = data.message,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.caption.scaled,
            modifier = Modifier.padding(top = 2.dp),
        )
        data.details?.takeIf { it.isNotBlank() }?.let { details ->
            Text(
                text = details,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

// ── Markdown Rendering ───────────────────────────────────────────────────

@Composable
private fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val textScale = LocalTextScale.current
    val markwon = remember(context) {
        try {
            val prism4j = Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
            Markwon.builder(context)
                .usePlugin(SyntaxHighlightPlugin.create(prism4j, io.noties.markwon.syntax.Prism4jThemeDarkula.create()))
                .build()
        } catch (_: Exception) {
            Markwon.create(context)
        }
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(LitterTheme.textBody.hashCode())
                textSize = LitterTextStyle.body * textScale
                movementMethod = LinkMovementMethod.getInstance()
                setLinkTextColor(LitterTheme.accent.hashCode())
            }
        },
        update = { tv ->
            markwon.setMarkdown(tv, text)
            tv.setTextColor(android.graphics.Color.parseColor("#E0E0E0"))
        },
        modifier = modifier.fillMaxWidth(),
    )
}

// ── Shared Helpers ───────────────────────────────────────────────────────────

@Composable
internal fun StatusIcon(status: AppOperationStatus) {
    when (status) {
        AppOperationStatus.IN_PROGRESS -> {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = LitterTheme.accent,
            )
        }
        AppOperationStatus.COMPLETED -> {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Completed",
                tint = LitterTheme.success,
                modifier = Modifier.size(14.dp),
            )
        }
        AppOperationStatus.FAILED -> {
            Icon(
                Icons.Default.Error,
                contentDescription = "Failed",
                tint = LitterTheme.danger,
                modifier = Modifier.size(14.dp),
            )
        }
        else -> {
            Icon(
                Icons.Default.HourglassEmpty,
                contentDescription = "Unknown",
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private fun formatDuration(ms: Long): String {
    return when {
        ms < 1000 -> "${ms}ms"
        ms < 60_000 -> "%.1fs".format(ms / 1000.0)
        else -> "${ms / 60_000}m ${(ms % 60_000) / 1000}s"
    }
}
