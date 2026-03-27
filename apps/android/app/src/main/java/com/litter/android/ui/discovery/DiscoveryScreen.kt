package com.litter.android.ui.discovery

import android.util.Log
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.DeveloperBoard
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedSshCredential
import com.litter.android.state.SshAuthMethod
import com.litter.android.state.SshCredentialStore
import com.litter.android.state.connectionProgressDetail
import com.litter.android.state.isIpcConnected
import com.litter.android.state.isConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
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
    scanProgress: Float = 0f,
    scanProgressLabel: String? = null,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val logTag = "DiscoveryScreen"
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sshCredentialStore = remember(context) { SshCredentialStore(context.applicationContext) }
    var showManualEntry by remember { mutableStateOf(false) }
    var sshServer by remember { mutableStateOf<SavedServer?>(null) }
    var connectionChoiceServer by remember { mutableStateOf<SavedServer?>(null) }
    var pendingAutoNavigateServerId by remember { mutableStateOf<String?>(null) }
    var pendingAutoNavigateServer by remember { mutableStateOf<SavedServer?>(null) }
    var connectError by remember { mutableStateOf<String?>(null) }

    var savedServers by remember { mutableStateOf(SavedServerStore.load(context)) }
    LaunchedEffect(Unit) {
        savedServers = SavedServerStore.load(context)
    }

    LaunchedEffect(snapshot, pendingAutoNavigateServerId) {
        val pendingServerId = pendingAutoNavigateServerId ?: return@LaunchedEffect
        val serverSnapshot = snapshot?.servers?.firstOrNull { it.serverId == pendingServerId } ?: return@LaunchedEffect
        if (serverSnapshot.isConnected) {
            pendingAutoNavigateServerId = null
            pendingAutoNavigateServer = null
            onDismiss()
        } else if (serverSnapshot.health == uniffi.codex_mobile_client.AppServerHealth.DISCONNECTED) {
            serverSnapshot.connectionProgress?.terminalMessage?.let { message ->
                pendingAutoNavigateServerId = null
                pendingAutoNavigateServer = null
                connectError = message
            }
        }
    }

    // Merge discovered with saved
    val merged = remember(discoveredServers, savedServers) {
        mergeServers(discoveredServers, savedServers)
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

        if (isScanning) {
            if (scanProgressLabel != null) {
                Spacer(Modifier.height(4.dp))
                Row(modifier = Modifier.fillMaxWidth()) {
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = scanProgressLabel,
                        color = LitterTheme.textMuted,
                        fontSize = 10.sp,
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
            val animatedProgress by animateFloatAsState(
                targetValue = scanProgress,
                animationSpec = tween(durationMillis = 250),
                label = "scanProgress",
            )
            LinearProgressIndicator(
                progress = { animatedProgress },
                modifier = Modifier.fillMaxWidth().height(3.dp),
                color = LitterTheme.accent,
                trackColor = LitterTheme.surface,
            )
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
                                val connected = connectedSnapshot(entry, snapshot?.servers ?: emptyList())
                                if (connected?.isConnected == true) {
                                    Log.d(logTag, "server already connected: ${entry.id}")
                                    onDismiss()
                                    return@launch
                                }
                                when {
                                    entry.source == "local" -> {
                                        appModel.serverBridge.connectLocalServer(
                                            entry.id, entry.name, entry.hostname, entry.port.toUShort(),
                                        )
                                        SavedServerStore.upsert(context, entry.normalizedForPersistence())
                                    }
                                    entry.websocketURL != null -> {
                                        appModel.serverBridge.connectRemoteUrlServer(
                                            entry.id, entry.name, entry.websocketURL!!,
                                        )
                                        SavedServerStore.upsert(context, entry.normalizedForPersistence())
                                    }
                                    entry.requiresConnectionChoice -> {
                                        connectionChoiceServer = entry
                                        return@launch
                                    }
                                    entry.prefersSshConnection || (!entry.hasCodexServer && entry.canConnectViaSsh) -> {
                                        sshServer = entry.withPreferredConnection("ssh")
                                        return@launch
                                    }
                                    entry.directCodexPort != null -> {
                                        appModel.serverBridge.connectRemoteServer(
                                            entry.id,
                                            entry.name,
                                            entry.hostname,
                                            entry.directCodexPort!!.toUShort(),
                                        )
                                        SavedServerStore.upsert(
                                            context,
                                            entry.withPreferredConnection("directCodex", entry.directCodexPort),
                                        )
                                    }
                                    else -> {
                                        connectError = "No Codex server port was discovered for ${entry.hostname}."
                                        return@launch
                                    }
                                }
                                savedServers = SavedServerStore.load(context)
                                appModel.refreshSnapshot()
                                onDismiss()
                            } catch (e: Exception) {
                                Log.e(logTag, "server connect failed for ${entry.id}", e)
                                connectError = e.message ?: "Unable to connect."
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
                    } catch (e: Exception) {
                        connectError = e.message ?: "Unable to connect."
                    }
                }
            },
        )
    }

    connectionChoiceServer?.let { server ->
        AlertDialog(
            onDismissRequest = { connectionChoiceServer = null },
            title = { Text("Connect ${server.name.ifBlank { server.hostname }}") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "Choose how to connect.",
                        color = LitterTheme.textSecondary,
                    )
                    server.availableDirectCodexPorts.forEach { port ->
                        TextButton(
                            onClick = {
                                connectionChoiceServer = null
                                scope.launch {
                                    try {
                                        appModel.serverBridge.connectRemoteServer(
                                            server.id,
                                            server.name,
                                            server.hostname,
                                            port.toUShort(),
                                        )
                                        SavedServerStore.upsert(
                                            context,
                                            server.withPreferredConnection("directCodex", port),
                                        )
                                        savedServers = SavedServerStore.load(context)
                                        appModel.refreshSnapshot()
                                        onDismiss()
                                    } catch (e: Exception) {
                                        Log.e(logTag, "direct codex connect failed for ${server.id}", e)
                                        connectError = e.message ?: "Unable to connect."
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Use Codex ($port)")
                        }
                    }
                    if (server.canConnectViaSsh) {
                        TextButton(
                            onClick = {
                                SavedServerStore.upsert(
                                    context,
                                    server.withPreferredConnection("ssh"),
                                )
                                savedServers = SavedServerStore.load(context)
                                sshServer = server.withPreferredConnection("ssh")
                                connectionChoiceServer = null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Connect via SSH", color = LitterTheme.accent)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { connectionChoiceServer = null }) {
                    Text("Cancel")
                }
            },
            dismissButton = {},
        )
    }

    sshServer?.let { server ->
        SSHLoginDialog(
            server = server,
            initialCredential = sshCredentialStore.load(server.hostname, server.resolvedSshPort),
            onDismiss = { sshServer = null },
            onConnect = { credential, rememberCredentials ->
                try {
                    Log.d(logTag, "starting SSH connect for ${server.id} host=${server.hostname}:${server.resolvedSshPort}")
                    when (credential.method) {
                        SshAuthMethod.PASSWORD -> {
                            appModel.ssh.sshStartRemoteServerConnect(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.resolvedSshPort.toUShort(),
                                username = credential.username,
                                password = credential.password,
                                privateKeyPem = null,
                                passphrase = null,
                                acceptUnknownHost = true,
                                workingDir = null,
                                ipcSocketPathOverride = null,
                            )
                        }
                        SshAuthMethod.KEY -> {
                            appModel.ssh.sshStartRemoteServerConnect(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.resolvedSshPort.toUShort(),
                                username = credential.username,
                                password = null,
                                privateKeyPem = credential.privateKey,
                                passphrase = credential.passphrase,
                                acceptUnknownHost = true,
                                workingDir = null,
                                ipcSocketPathOverride = null,
                            )
                        }
                    }
                    if (rememberCredentials) {
                        sshCredentialStore.save(server.hostname, server.resolvedSshPort, credential)
                    } else {
                        sshCredentialStore.delete(server.hostname, server.resolvedSshPort)
                    }
                    SavedServerStore.upsert(
                        context,
                        server.withPreferredConnection("ssh"),
                    )
                    savedServers = SavedServerStore.load(context)
                    appModel.refreshSnapshot()
                    pendingAutoNavigateServerId = server.id
                    pendingAutoNavigateServer = server
                    Log.d(logTag, "SSH bootstrap started for ${server.id}")
                    sshServer = null
                    null
                } catch (e: Exception) {
                    Log.e(logTag, "SSH connect failed for ${server.id}", e)
                    e.message ?: "Unable to connect over SSH."
                }
            },
        )
    }

    snapshot?.servers?.firstOrNull { it.connectionProgress?.pendingInstall == true }?.let { serverSnapshot ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Install Codex?") },
            text = {
                Text(
                    serverSnapshot.connectionProgressDetail
                        ?: "Codex was not found on the remote host. Install the latest stable release into ~/.litter?",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            appModel.ssh.sshRespondToInstallPrompt(serverSnapshot.serverId, true)
                        }
                    },
                ) {
                    Text("Install")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            appModel.ssh.sshRespondToInstallPrompt(serverSnapshot.serverId, false)
                        }
                    },
                ) {
                    Text("Cancel")
                }
            },
        )
    }

    connectError?.let { message ->
        AlertDialog(
            onDismissRequest = { connectError = null },
            title = { Text("Connection Failed") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { connectError = null }) {
                    Text("OK")
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
    val subtitle = connectedServer?.connectionProgressDetail
        ?: buildString {
            append(displayHost)
            if (entry.os != null) {
                append(" - ")
                append(entry.os)
            }
            if (entry.availableDirectCodexPorts.isNotEmpty()) {
                append(" - codex ")
                append(entry.availableDirectCodexPorts.joinToString(", "))
            }
            if (entry.canConnectViaSsh) {
                append(" - ssh ")
                append(entry.resolvedSshPort)
            }
        }
    val serverIcon = serverIconForEntry(entry)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = serverIcon,
            contentDescription = entry.os ?: entry.source,
            tint = if (entry.hasCodexServer) LitterTheme.accent else LitterTheme.textMuted,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(entry.name.ifBlank { entry.hostname }, color = LitterTheme.textPrimary, fontSize = 14.sp)
            Text(subtitle, color = LitterTheme.textSecondary, fontSize = 11.sp)
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
        if (connectedServer != null && connectedServer.health != uniffi.codex_mobile_client.AppServerHealth.DISCONNECTED) {
            Spacer(Modifier.width(6.dp))
            Text(
                text = connectedServer.statusLabel,
                color = connectedServer.statusColor,
                fontSize = 10.sp,
                modifier = Modifier
                    .background(connectedServer.statusColor.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        if (connectedServer?.isIpcConnected == true) {
            Spacer(Modifier.width(6.dp))
            Text(
                text = "IPC",
                color = LitterTheme.accentStrong,
                fontSize = 10.sp,
                modifier = Modifier
                    .background(LitterTheme.accentStrong.copy(alpha = 0.14f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
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

@Composable
private fun SSHLoginDialog(
    server: SavedServer,
    initialCredential: SavedSshCredential?,
    onDismiss: () -> Unit,
    onConnect: suspend (SavedSshCredential, Boolean) -> String?,
) {
    val scope = rememberCoroutineScope()
    var username by remember(server.id) { mutableStateOf(initialCredential?.username ?: "") }
    var authMethod by remember(server.id) { mutableStateOf(initialCredential?.method ?: SshAuthMethod.PASSWORD) }
    var password by remember(server.id) { mutableStateOf(initialCredential?.password ?: "") }
    var privateKey by remember(server.id) { mutableStateOf(initialCredential?.privateKey ?: "") }
    var passphrase by remember(server.id) { mutableStateOf(initialCredential?.passphrase ?: "") }
    var rememberCredentials by remember(server.id) { mutableStateOf(initialCredential != null) }
    var isConnecting by remember(server.id) { mutableStateOf(false) }
    var errorMessage by remember(server.id) { mutableStateOf<String?>(null) }
    val hostDisplay = if (server.resolvedSshPort == 22) {
        server.hostname
    } else {
        "${server.hostname}:${server.resolvedSshPort}"
    }

    AlertDialog(
        onDismissRequest = { if (!isConnecting) onDismiss() },
        title = { Text("SSH Login") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = "${server.name.ifBlank { server.hostname }}\n$hostDisplay",
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                )
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username") },
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = { authMethod = SshAuthMethod.PASSWORD },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.PASSWORD) "Password *" else "Password")
                    }
                    TextButton(
                        onClick = { authMethod = SshAuthMethod.KEY },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.KEY) "SSH Key *" else "SSH Key")
                    }
                }
                if (authMethod == SshAuthMethod.PASSWORD) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Password") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                } else {
                    OutlinedTextField(
                        value = privateKey,
                        onValueChange = { privateKey = it },
                        label = { Text("Private Key") },
                        minLines = 5,
                    )
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passphrase (optional)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Switch(
                        checked = rememberCredentials,
                        onCheckedChange = { rememberCredentials = it },
                        enabled = !isConnecting,
                    )
                    Text(
                        text = "Remember credentials on this device",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                    )
                }
                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = Color(0xFFFF6B6B),
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isConnecting && username.isNotBlank() && when (authMethod) {
                    SshAuthMethod.PASSWORD -> password.isNotBlank()
                    SshAuthMethod.KEY -> privateKey.isNotBlank()
                },
                onClick = {
                    val credential = when (authMethod) {
                        SshAuthMethod.PASSWORD -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.PASSWORD,
                            password = password,
                        )
                        SshAuthMethod.KEY -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.KEY,
                            privateKey = privateKey,
                            passphrase = passphrase.ifBlank { null },
                        )
                    }
                    scope.launch {
                        isConnecting = true
                        errorMessage = onConnect(credential, rememberCredentials)
                        isConnecting = false
                    }
                },
            ) {
                if (isConnecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Text("Connect")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isConnecting) {
                Text("Cancel")
            }
        },
    )
}

private fun serverIconForEntry(entry: SavedServer): androidx.compose.ui.graphics.vector.ImageVector {
    if (entry.source == "local") return Icons.Outlined.PhoneAndroid
    val os = entry.os?.lowercase()
    if (os != null) {
        if (os.contains("windows")) return Icons.Outlined.DesktopWindows
        if (os.contains("raspbian")) return Icons.Outlined.DeveloperBoard
        if (os.contains("ubuntu") || os.contains("debian") ||
            os.contains("fedora") || os.contains("red hat") ||
            os.contains("freebsd") || os.contains("linux")
        ) return Icons.Outlined.Dns
    }
    return when (entry.source) {
        "bonjour" -> Icons.Outlined.Laptop
        "tailscale" -> Icons.Outlined.Lan
        "ssh" -> Icons.Outlined.Terminal
        else -> Icons.Outlined.Dns
    }
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
        val betterCodexPort = candidate.availableDirectCodexPorts.any { it !in existing.availableDirectCodexPorts }
        val betterName = existing.name == existing.hostname && candidate.name != candidate.hostname
        val preferCandidate = betterSource || hasCodexUpgrade || betterCodexPort || betterName

        val mergedCodexPorts =
            buildList {
                addAll(existing.availableDirectCodexPorts)
                addAll(candidate.availableDirectCodexPorts)
            }.distinct()

        val mergedOs = if (candidate.sshBanner != null) candidate.os else (candidate.os ?: existing.os)
        val mergedBanner = candidate.sshBanner ?: existing.sshBanner

        val merged = if (preferCandidate) {
            candidate.copy(
                id = existing.id,
                codexPorts = mergedCodexPorts,
                wakeMAC = candidate.wakeMAC ?: existing.wakeMAC,
                preferredConnectionMode = existing.resolvedPreferredConnectionMode ?: candidate.resolvedPreferredConnectionMode,
                preferredCodexPort = existing.resolvedPreferredCodexPort ?: candidate.resolvedPreferredCodexPort,
                sshPortForwardingEnabled = null,
                websocketURL = candidate.websocketURL ?: existing.websocketURL,
                os = mergedOs,
                sshBanner = mergedBanner,
            )
        } else {
            existing.copy(
                codexPorts = mergedCodexPorts,
                sshPort = existing.sshPort ?: candidate.sshPort,
                wakeMAC = existing.wakeMAC ?: candidate.wakeMAC,
                preferredConnectionMode = existing.resolvedPreferredConnectionMode ?: candidate.resolvedPreferredConnectionMode,
                preferredCodexPort = existing.resolvedPreferredCodexPort ?: candidate.resolvedPreferredCodexPort,
                sshPortForwardingEnabled = null,
                websocketURL = existing.websocketURL ?: candidate.websocketURL,
                os = mergedOs,
                sshBanner = mergedBanner,
            )
        }

        return merged.normalizedForPersistence()
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
