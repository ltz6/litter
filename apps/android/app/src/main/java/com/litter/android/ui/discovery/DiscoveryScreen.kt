package com.litter.android.ui.discovery

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.FfiDiscoveredServer

/**
 * Server discovery and connection screen.
 * Displays discovered + saved servers merged.
 */
@Composable
fun DiscoveryScreen(
    discoveredServers: List<FfiDiscoveredServer>,
    isScanning: Boolean,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showManualEntry by remember { mutableStateOf(false) }

    // Merge discovered with saved
    val saved = remember { SavedServerStore.load(context) }
    val merged = remember(discoveredServers, saved) {
        mergeServers(discoveredServers, saved)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        // Header
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = "Connect Server",
                color = LitterTheme.textPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            if (isScanning) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = LitterTheme.accent,
                )
                Spacer(Modifier.width(8.dp))
            }
            IconButton(onClick = onRefresh) {
                Icon(Icons.Default.Refresh, "Refresh", tint = LitterTheme.textSecondary)
            }
            IconButton(onClick = { showManualEntry = true }) {
                Icon(Icons.Default.Add, "Manual", tint = LitterTheme.textSecondary)
            }
        }

        Spacer(Modifier.height(12.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(merged, key = { it.id }) { entry ->
                ServerRow(
                    entry = entry,
                    connectedServer = connectedSnapshot(entry, snapshot?.servers ?: emptyList()),
                    onClick = {
                        scope.launch {
                            try {
                                when {
                                    entry.source == "local" -> {
                                        appModel.serverBridge.connectLocalServer(
                                            entry.id, entry.name, entry.hostname, entry.port.toUShort(),
                                        )
                                    }
                                    entry.websocketURL != null -> {
                                        appModel.serverBridge.connectRemoteUrlServer(
                                            entry.id, entry.name, entry.websocketURL!!,
                                        )
                                    }
                                    else -> {
                                        appModel.serverBridge.connectRemoteServer(
                                            entry.id, entry.name, entry.hostname, entry.port.toUShort(),
                                        )
                                    }
                                }
                                SavedServerStore.upsert(context, entry)
                                // Load threads for the newly connected server
                                try {
                                    appModel.rpc.threadList(
                                        entry.id,
                                        uniffi.codex_mobile_client.ThreadListParams(
                                        cursor = null, limit = null, sortKey = null,
                                        modelProviders = null, sourceKinds = null,
                                        archived = false, cwd = null, searchTerm = null,
                                    ),
                                    )
                                } catch (_: Exception) {}
                                appModel.refreshSnapshot()
                                onDismiss()
                            } catch (e: Exception) {
                                // TODO: show error
                            }
                        }
                    },
                )
            }

            if (merged.isEmpty()) {
                item {
                    if (isScanning) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(vertical = 16.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp),
                                strokeWidth = 2.dp,
                                color = LitterTheme.accent,
                            )
                            Text(
                                text = "Scanning\u2026",
                                color = LitterTheme.textMuted,
                                fontSize = 13.sp,
                            )
                        }
                    } else {
                        Text(
                            text = "No servers found. Try manual entry.",
                            color = LitterTheme.textMuted,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(vertical = 16.dp),
                        )
                    }
                }
            }
        }
    }

    // Manual entry dialog
    if (showManualEntry) {
        ManualEntryDialog(
            onDismiss = { showManualEntry = false },
            onConnect = { url ->
                showManualEntry = false
                scope.launch {
                    try {
                        val serverId = "manual-${System.currentTimeMillis()}"
                        appModel.serverBridge.connectRemoteUrlServer(serverId, url, url)
                        appModel.refreshSnapshot()
                        onDismiss()
                    } catch (_: Exception) { }
                }
            },
        )
    }
}

@Composable
private fun ServerRow(
    entry: SavedServer,
    connectedServer: AppServerSnapshot?,
    onClick: () -> Unit,
) {
    val displayHost = connectedServer?.host ?: entry.hostname
    val displayPort = connectedServer?.port?.toInt() ?: entry.port
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (entry.hasCodexServer) LitterTheme.accent else LitterTheme.textMuted),
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(entry.name.ifBlank { entry.hostname }, color = LitterTheme.textPrimary, fontSize = 14.sp)
            Text("$displayHost:$displayPort", color = LitterTheme.textSecondary, fontSize = 11.sp)
        }
        val (sourceColor, sourceLabel) = when (entry.source) {
            "bonjour" -> LitterTheme.info to "Bonjour"
            "tailscale" -> Color(0xFFC797D8) to "Tailscale"
            "lanProbe" -> LitterTheme.accent to "LAN"
            "arpScan" -> LitterTheme.textSecondary to "ARP"
            "ssh" -> Color(0xFFFF9500) to "SSH"
            "local" -> LitterTheme.accent to "Local"
            else -> LitterTheme.textMuted to "Manual"
        }
        Text(
            text = sourceLabel,
            color = sourceColor,
            fontSize = 10.sp,
            modifier = Modifier
                .background(sourceColor.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun ManualEntryDialog(onDismiss: () -> Unit, onConnect: (String) -> Unit) {
    var url by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Manual Connection") },
        text = {
            OutlinedTextField(
                value = url,
                onValueChange = { url = it },
                label = { Text("Server URL") },
                placeholder = { Text("ws://host:port or codex://host:port") },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(onClick = { if (url.isNotBlank()) onConnect(url.trim()) }) {
                Text("Connect")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

private fun connectedSnapshot(
    entry: SavedServer,
    servers: List<AppServerSnapshot>,
): AppServerSnapshot? = servers.firstOrNull { it.serverId == entry.id }
    ?: servers.firstOrNull { it.host.lowercase().trim().trimStart('[').trimEnd(']') == entry.deduplicationKey }

private fun mergeServers(
    discovered: List<FfiDiscoveredServer>,
    saved: List<SavedServer>,
): List<SavedServer> {
    val merged = linkedMapOf<String, SavedServer>()

    fun sourceRank(source: String): Int = when (source) {
        "bonjour" -> 0
        "tailscale" -> 1
        "lanProbe" -> 2
        "arpScan" -> 3
        "ssh" -> 4
        "manual" -> 5
        "local" -> 6
        else -> 7
    }

    fun mergeCandidate(existing: SavedServer, candidate: SavedServer): SavedServer {
        val betterSource = sourceRank(candidate.source) < sourceRank(existing.source)
        val hasCodexUpgrade = candidate.hasCodexServer && !existing.hasCodexServer
        val betterCodexPort = candidate.hasCodexServer && existing.hasCodexServer && candidate.port != existing.port
        val betterName = existing.name == existing.hostname && candidate.name != candidate.hostname
        val preferCandidate = betterSource || hasCodexUpgrade || betterCodexPort || betterName

        return if (preferCandidate) {
            candidate.copy(
                id = existing.id,
                wakeMAC = candidate.wakeMAC ?: existing.wakeMAC,
                sshPortForwardingEnabled = candidate.sshPortForwardingEnabled || existing.sshPortForwardingEnabled,
                websocketURL = candidate.websocketURL ?: existing.websocketURL,
            )
        } else {
            existing.copy(
                sshPort = existing.sshPort ?: candidate.sshPort,
                wakeMAC = existing.wakeMAC ?: candidate.wakeMAC,
                sshPortForwardingEnabled = existing.sshPortForwardingEnabled || candidate.sshPortForwardingEnabled,
                websocketURL = existing.websocketURL ?: candidate.websocketURL,
            )
        }
    }

    for (server in saved) {
        merged[server.deduplicationKey] = server
    }

    for (server in discovered.map(SavedServer::from)) {
        val key = server.deduplicationKey
        merged[key] = merged[key]?.let { existing -> mergeCandidate(existing, server) } ?: server
    }

    return merged.values.sortedWith(
        compareBy<SavedServer> { sourceRank(it.source) }.thenBy { it.name.lowercase() }
    )
}
