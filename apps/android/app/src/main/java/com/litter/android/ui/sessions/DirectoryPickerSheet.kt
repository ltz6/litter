package com.litter.android.ui.sessions

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AbsolutePath
import uniffi.codex_mobile_client.CommandExecParams

/**
 * Directory picker for selecting working directory when creating a new session.
 * Uses RPC to list remote directories.
 */
@Composable
fun DirectoryPickerSheet(
    serverId: String,
    onSelect: (cwd: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val scope = rememberCoroutineScope()

    var currentPath by remember { mutableStateOf("~") }
    var entries by remember { mutableStateOf<List<String>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var searchQuery by remember { mutableStateOf("") }

    // Load directory contents
    fun loadDirectory(path: String) {
        isLoading = true
        scope.launch {
            try {
                val result = appModel.rpc.oneOffCommandExec(
                    serverId,
                    CommandExecParams(
                        command = listOf("ls", "-1p", path.replace("~", System.getenv("HOME") ?: "~")),
                        processId = null,
                        tty = false,
                        streamStdin = false,
                        streamStdoutStderr = false,
                        outputBytesCap = null,
                        disableOutputCap = false,
                        disableTimeout = false,
                        timeoutMs = null,
                        cwd = null,
                        env = null,
                        size = null,
                        sandboxPolicy = null,
                    ),
                )
                val output = result.stdout ?: ""
                entries = output.lines()
                    .filter { it.isNotBlank() && it.endsWith("/") }
                    .map { it.trimEnd('/') }
                    .sorted()
                currentPath = path
            } catch (_: Exception) {
                entries = emptyList()
            }
            isLoading = false
        }
    }

    // Initial load
    LaunchedEffect(serverId) {
        try {
            val result = appModel.rpc.oneOffCommandExec(
                serverId,
                CommandExecParams(
                        command = listOf("echo", System.getenv("HOME") ?: "~"),
                        processId = null, tty = false, streamStdin = false,
                        streamStdoutStderr = false, outputBytesCap = null,
                        disableOutputCap = false, disableTimeout = false,
                        timeoutMs = null, cwd = null, env = null, size = null,
                        sandboxPolicy = null,
                    ),
            )
            val home = result.stdout?.trim() ?: "~"
            loadDirectory(home)
        } catch (_: Exception) {
            loadDirectory("~")
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        Text(
            text = "Select Directory",
            color = LitterTheme.textPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(12.dp))

        // Breadcrumb navigation
        val pathParts = currentPath.split("/").filter { it.isNotEmpty() }
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            item {
                TextButton(onClick = { loadDirectory("/") }) {
                    Text("/", color = LitterTheme.accent, fontSize = 12.sp)
                }
            }
            items(pathParts.size) { i ->
                val partPath = "/" + pathParts.subList(0, i + 1).joinToString("/")
                TextButton(onClick = { loadDirectory(partPath) }) {
                    Text(
                        pathParts[i],
                        color = if (i == pathParts.size - 1) LitterTheme.textPrimary else LitterTheme.accent,
                        fontSize = 12.sp,
                    )
                }
                if (i < pathParts.size - 1) {
                    Text("/", color = LitterTheme.textMuted, fontSize = 12.sp)
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        // Search filter
        BasicTextField(
            value = searchQuery,
            onValueChange = { searchQuery = it },
            textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
            cursorBrush = SolidColor(LitterTheme.accent),
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp),
            decorationBox = { innerTextField ->
                if (searchQuery.isEmpty()) {
                    Text("Filter folders\u2026", color = LitterTheme.textMuted, fontSize = 13.sp)
                }
                innerTextField()
            },
        )

        Spacer(Modifier.height(8.dp))

        // Folder list
        val filtered = if (searchQuery.isBlank()) entries
        else entries.filter { it.contains(searchQuery, ignoreCase = true) }

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            // Up one level
            if (currentPath != "/" && currentPath != "~") {
                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                val parent = currentPath.substringBeforeLast("/")
                                loadDirectory(parent.ifEmpty { "/" })
                            }
                            .padding(vertical = 8.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = null,
                            tint = LitterTheme.textMuted,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                        Text("..", color = LitterTheme.textSecondary, fontSize = 13.sp)
                    }
                }
            }

            items(filtered) { folder ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { loadDirectory("$currentPath/$folder") }
                        .padding(vertical = 8.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Default.Folder,
                        contentDescription = null,
                        tint = LitterTheme.accent,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                    Text(folder, color = LitterTheme.textPrimary, fontSize = 13.sp)
                }
            }
        }

        Spacer(Modifier.height(12.dp))

        // Select button
        Button(
            onClick = { onSelect(currentPath) },
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(
                containerColor = LitterTheme.accent,
                contentColor = Color.Black,
            ),
        ) {
            Text("Select: $currentPath")
        }
    }
}
