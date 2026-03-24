package com.litter.android.ui.conversation

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedMultiAgentActionData
import uniffi.codex_mobile_client.ThreadKey

/**
 * Expandable card for multi-agent actions.
 * Uses Rust-provided [HydratedMultiAgentActionData] directly — no type duplication.
 */
@Composable
fun SubagentCard(
    data: HydratedMultiAgentActionData,
    onOpenThread: ((ThreadKey) -> Unit)? = null,
) {
    var expanded by remember { mutableStateOf(false) }
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()

    val actionLabel = when (data.tool) {
        "spawn" -> "Spawning agents"
        "send_input" -> "Sending input"
        "resume" -> "Resuming agents"
        "wait" -> "Waiting for agents"
        "close" -> "Closing agents"
        else -> data.tool
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .animateContentSize()
            .padding(8.dp),
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded },
        ) {
            StatusIcon(data.status)
            Spacer(Modifier.width(6.dp))
            Text(
                text = actionLabel,
                color = LitterTheme.toolCallCollaboration,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = "${data.targets.size} agents",
                color = LitterTheme.textMuted,
                fontSize = 10.sp,
            )
            Spacer(Modifier.width(4.dp))
            Icon(
                if (expanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                contentDescription = null,
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(16.dp),
            )
        }

        // Expanded agent list
        if (expanded) {
            // Show prompt if present
            data.prompt?.takeIf { it.isNotBlank() }?.let { prompt ->
                Text(
                    text = prompt,
                    color = LitterTheme.textMuted,
                    fontSize = 10.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp, start = 20.dp),
                )
            }

            for ((index, targetId) in data.targets.withIndex()) {
                val stateData = data.agentStates.find { it.targetId == targetId }
                val receiverThreadId = data.receiverThreadIds.getOrNull(index)

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp, start = 20.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = targetId,
                            color = LitterTheme.textPrimary,
                            fontSize = LitterTextStyle.caption.scaled,
                        )
                        stateData?.let { state ->
                            val statusStr = state.status.name.lowercase()
                            val statusColor = when {
                                statusStr.contains("running") -> LitterTheme.accent
                                statusStr.contains("completed") -> LitterTheme.success
                                statusStr.contains("error") -> LitterTheme.danger
                                else -> LitterTheme.textMuted
                            }
                            Text(
                                text = statusStr,
                                color = statusColor,
                                fontSize = 10.sp,
                            )
                        }
                    }

                    if (receiverThreadId != null && onOpenThread != null) {
                        val threadKey = snapshot?.threads?.find {
                            it.key.threadId == receiverThreadId
                        }?.key
                        if (threadKey != null) {
                            IconButton(
                                onClick = { onOpenThread(threadKey) },
                                modifier = Modifier.size(28.dp),
                            ) {
                                Icon(
                                    Icons.Default.OpenInNew,
                                    contentDescription = "Open",
                                    tint = LitterTheme.accent,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
