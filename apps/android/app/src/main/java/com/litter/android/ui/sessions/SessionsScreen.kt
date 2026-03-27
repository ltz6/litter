package com.litter.android.ui.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppThreadLaunchConfig
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.home.HomeDashboardSupport
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadArchiveParams
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.ThreadSetNameParams

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(
    serverId: String?,
    title: String,
    onOpenConversation: (ThreadKey) -> Unit,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()

    var searchQuery by remember { mutableStateOf("") }
    var sortMode by remember { mutableStateOf(WorkspaceSortMode.RECENT) }
    var collapsedGroups by remember { mutableStateOf(setOf<String>()) }
    var forkOnly by remember { mutableStateOf(false) }
    var showDirectoryPicker by remember { mutableStateOf(false) }
    var isCreating by remember { mutableStateOf(false) }

    val derived = remember(snapshot, searchQuery, serverId, sortMode, forkOnly) {
        val summaries = snapshot?.sessionSummaries ?: emptyList()
        SessionsDerivation.derive(
            summaries = summaries,
            serverFilter = serverId,
            searchQuery = searchQuery,
            sortMode = sortMode,
            forkOnly = forkOnly,
        )
    }

    val listState = rememberLazyListState()

    // C3: Auto-scroll to active session
    LaunchedEffect(Unit) {
        val activeKey = snapshot?.activeThread ?: return@LaunchedEffect
        var flatIndex = 0
        for (group in derived.groups) {
            flatIndex++ // group header
            val flatNodes = flattenNodes(group.nodes)
            val matchIndex = flatNodes.indexOfFirst {
                it.summary.key.serverId == activeKey.serverId &&
                    it.summary.key.threadId == activeKey.threadId
            }
            if (matchIndex >= 0) {
                listState.scrollToItem(flatIndex + matchIndex)
                break
            }
            flatIndex += flatNodes.size
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Top bar
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                )
            }
            Text(
                text = title,
                color = LitterTheme.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = "${derived.filteredCount}/${derived.totalCount}",
                color = LitterTheme.textMuted,
                fontSize = 12.sp,
            )
            if (onInfo != null) {
                IconButton(onClick = onInfo, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Outlined.Info,
                        contentDescription = "Server Info",
                        tint = LitterTheme.accent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        if (serverId != null) {
            Button(
                onClick = { showDirectoryPicker = true },
                enabled = !isCreating,
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.accent,
                    contentColor = Color.Black,
                    disabledContainerColor = LitterTheme.accent.copy(alpha = 0.55f),
                    disabledContentColor = Color.Black,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
            ) {
                if (isCreating) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = Color.Black,
                    )
                } else {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(6.dp))
                Text("New Session")
            }
        }

        // Search bar + filter chips
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                if (searchQuery.isEmpty()) {
                    Text("Search sessions\u2026", color = LitterTheme.textMuted, fontSize = 13.sp)
                }
                BasicTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            FilterChip(
                selected = forkOnly,
                onClick = { forkOnly = !forkOnly },
                label = { Text("Forks", fontSize = 11.sp) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = LitterTheme.accent,
                    selectedLabelColor = Color.Black,
                ),
            )
        }

        // Session list
        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp),
        ) {
            for (group in derived.groups) {
                val groupKey = "${group.serverId}|${group.cwd}"
                val isCollapsed = groupKey in collapsedGroups

                // Group header
                item(key = "header-$groupKey") {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                collapsedGroups = if (isCollapsed) {
                                    collapsedGroups - groupKey
                                } else {
                                    collapsedGroups + groupKey
                                }
                            }
                            .padding(vertical = 8.dp),
                    ) {
                        Icon(
                            if (isCollapsed) Icons.Default.ChevronRight else Icons.Default.ExpandMore,
                            contentDescription = null,
                            tint = LitterTheme.textMuted,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = group.workspaceLabel,
                            color = LitterTheme.textSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = "${group.nodes.size}",
                            color = LitterTheme.textMuted,
                            fontSize = 11.sp,
                        )
                    }
                }

                // Session nodes (if expanded)
                if (!isCollapsed) {
                    items(
                        items = flattenNodes(group.nodes),
                        key = { "${it.summary.key.serverId}/${it.summary.key.threadId}" },
                    ) { node ->
                        SessionNodeRow(
                            node = node,
                            onClick = { onOpenConversation(node.summary.key) },
                        )
                    }
                }
            }

            item { Spacer(Modifier.height(32.dp)) }
        }
    }

    if (showDirectoryPicker && serverId != null) {
        ModalBottomSheet(
            onDismissRequest = { showDirectoryPicker = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            DirectoryPickerSheet(
                serverId = serverId,
                onSelect = { cwd ->
                    showDirectoryPicker = false
                    scope.launch {
                        isCreating = true
                        try {
                            val config = AppThreadLaunchConfig()
                            val resp = appModel.rpc.threadStart(
                                serverId,
                                config.toThreadStartParams(cwd),
                            )
                            val key = ThreadKey(
                                serverId = serverId,
                                threadId = resp.thread.id,
                            )
                            appModel.store.setActiveThread(key)
                            appModel.refreshSnapshot()
                            onOpenConversation(key)
                        } catch (_: Exception) {
                        } finally {
                            isCreating = false
                        }
                    }
                },
                onDismiss = { showDirectoryPicker = false },
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionNodeRow(
    node: SessionTreeNode,
    onClick: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val scope = rememberCoroutineScope()
    val summary = node.summary
    var showMenu by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var showArchiveDialog by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = (node.depth * 16).dp)
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Active turn indicator
            if (summary.hasActiveTurn) {
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(LitterTheme.accent),
                )
                Spacer(Modifier.width(6.dp))
            }

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = summary.title ?: summary.preview ?: "Untitled",
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    summary.model?.let { model ->
                        Text(
                            text = model.substringAfterLast('/'),
                            color = LitterTheme.textMuted,
                            fontSize = 10.sp,
                        )
                    }
                    summary.agentDisplayLabel?.let { label ->
                        Text(
                            text = label,
                            color = LitterTheme.accent,
                            fontSize = 10.sp,
                        )
                    }
                }
            }

            Text(
                text = HomeDashboardSupport.relativeTime(summary.updatedAt),
                color = LitterTheme.textMuted,
                fontSize = 10.sp,
            )
        }

        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text("Rename") },
                onClick = { showMenu = false; showRenameDialog = true },
            )
            DropdownMenuItem(
                text = { Text("Archive") },
                onClick = { showMenu = false; showArchiveDialog = true },
            )
        }
    }

    // Rename dialog
    if (showRenameDialog) {
        var newName by remember { mutableStateOf(summary.title ?: "") }
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            title = { Text("Rename Session") },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    label = { Text("Name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showRenameDialog = false
                    scope.launch {
                        try {
                            appModel.rpc.threadSetName(
                                summary.key.serverId,
                                ThreadSetNameParams(
                                    threadId = summary.key.threadId,
                                    name = newName,
                                ),
                            )
                            appModel.refreshSnapshot()
                        } catch (_: Exception) {}
                    }
                }) { Text("Rename") }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false }) { Text("Cancel") }
            },
        )
    }

    // Archive confirmation dialog
    if (showArchiveDialog) {
        AlertDialog(
            onDismissRequest = { showArchiveDialog = false },
            title = { Text("Archive Session") },
            text = { Text("Are you sure you want to archive this session?") },
            confirmButton = {
                TextButton(onClick = {
                    showArchiveDialog = false
                    scope.launch {
                        try {
                            appModel.rpc.threadArchive(
                                summary.key.serverId,
                                ThreadArchiveParams(threadId = summary.key.threadId),
                            )
                            appModel.refreshSnapshot()
                        } catch (_: Exception) {}
                    }
                }) { Text("Archive", color = LitterTheme.danger) }
            },
            dismissButton = {
                TextButton(onClick = { showArchiveDialog = false }) { Text("Cancel") }
            },
        )
    }

    Spacer(Modifier.height(4.dp))
}

/** Flatten tree nodes to a list for LazyColumn rendering. */
private fun flattenNodes(nodes: List<SessionTreeNode>): List<SessionTreeNode> {
    val result = mutableListOf<SessionTreeNode>()
    fun walk(node: SessionTreeNode) {
        result.add(node)
        node.children.forEach { walk(it) }
    }
    nodes.forEach { walk(it) }
    return result
}
