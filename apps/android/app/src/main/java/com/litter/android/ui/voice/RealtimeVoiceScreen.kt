package com.litter.android.ui.voice

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.litter.android.state.VoiceRuntimeController
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppVoiceSessionPhase
import uniffi.codex_mobile_client.ThreadKey

/**
 * Full-screen realtime voice UI with edge glow, transcript, and controls.
 */
@Composable
fun RealtimeVoiceScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val voiceController = remember { VoiceRuntimeController.shared }
    val session by voiceController.activeVoiceSession.collectAsState()
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val voiceSession = snapshot?.voiceSession
    val phase = voiceSession?.phase ?: AppVoiceSessionPhase.CONNECTING
    val inputLevel = session?.inputLevel ?: 0f
    val outputLevel = session?.outputLevel ?: 0f
    val transcript = voiceSession?.transcriptEntries ?: emptyList()

    // Auth check — runs on screen appear, then starts realtime if API key exists
    var hasCheckedAuth by remember { mutableStateOf(false) }
    var hasStartedRealtime by remember { mutableStateOf(false) }
    var hasMicPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED,
        )
    }
    val micPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hasMicPermission = granted
    }

    LaunchedEffect(threadKey) {
        try {
            appModel.rpc.getAccount(threadKey.serverId, uniffi.codex_mobile_client.GetAccountParams(refreshToken = false))
            appModel.refreshSnapshot()
        } catch (_: Exception) {}
        hasCheckedAuth = true
    }

    LaunchedEffect(Unit) {
        if (!hasMicPermission) {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    val server = remember(snapshot, threadKey) {
        snapshot?.servers?.firstOrNull { it.serverId == threadKey.serverId }
    }
    val hasApiKey = server?.account is uniffi.codex_mobile_client.Account.ApiKey
    val needsApiKey = hasCheckedAuth && server?.isLocal == true && !hasApiKey

    // Auto-start realtime once we have an API key
    LaunchedEffect(hasApiKey, hasCheckedAuth, hasMicPermission) {
        if (hasCheckedAuth && hasApiKey && hasMicPermission && !hasStartedRealtime) {
            hasStartedRealtime = true
            android.util.Log.i("VoiceScreen", "API key confirmed, starting realtime...")
            voiceController.startVoiceOnThread(appModel, threadKey)
        }
    }

    var apiKey by remember { mutableStateOf("") }
    var isSavingKey by remember { mutableStateOf(false) }
    var isSpeakerOn by remember { mutableStateOf(true) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        // Edge glow effect
        EdgeGlow(inputLevel = inputLevel, outputLevel = outputLevel, phase = phase)

        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(80.dp))

            // Phase indicator
            val phaseLabel = when (phase) {
                AppVoiceSessionPhase.CONNECTING -> "CONNECTING"
                AppVoiceSessionPhase.LISTENING -> "LISTENING"
                AppVoiceSessionPhase.SPEAKING -> "SPEAKING"
                AppVoiceSessionPhase.THINKING -> "THINKING"
                AppVoiceSessionPhase.HANDOFF -> "HANDOFF"
                AppVoiceSessionPhase.ERROR -> "ERROR"
            }
            val phaseColor = when (phase) {
                AppVoiceSessionPhase.LISTENING -> LitterTheme.accent
                AppVoiceSessionPhase.SPEAKING -> Color(0xFF4A9EFF)
                AppVoiceSessionPhase.THINKING -> Color(0xFFFFB74D)
                AppVoiceSessionPhase.HANDOFF -> Color(0xFFC797D8)
                AppVoiceSessionPhase.ERROR -> LitterTheme.danger
                AppVoiceSessionPhase.CONNECTING -> LitterTheme.textMuted
            }
            Text(
                text = phaseLabel,
                color = phaseColor,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 4.sp,
            )

            Spacer(Modifier.height(24.dp))

            // Transcript
            val listState = rememberLazyListState()
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 24.dp),
            ) {
                items(transcript) { entry ->
                    val color = when (entry.speaker) {
                        uniffi.codex_mobile_client.AppVoiceSpeaker.USER -> LitterTheme.textPrimary
                        uniffi.codex_mobile_client.AppVoiceSpeaker.ASSISTANT -> LitterTheme.accent
                    }
                    val align = when (entry.speaker) {
                        uniffi.codex_mobile_client.AppVoiceSpeaker.USER -> TextAlign.End
                        uniffi.codex_mobile_client.AppVoiceSpeaker.ASSISTANT -> TextAlign.Start
                    }
                    Text(
                        text = entry.text,
                        color = color,
                        fontSize = 14.sp,
                        textAlign = align,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                    )
                }
            }

            // Inline handoff view
            voiceSession?.handoffThreadKey?.let { handoffKey ->
                InlineHandoffView(
                    threadKey = handoffKey,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp)
                        .padding(horizontal = 16.dp),
                )
            }

            // Error display
            voiceSession?.lastError?.let { error ->
                Text(
                    text = error,
                    color = LitterTheme.danger,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 24.dp),
                )
            }

            if (!hasMicPermission) {
                Text(
                    text = "Microphone permission required",
                    color = LitterTheme.danger,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 24.dp),
                )
            }

            // API key prompt is shown as a dialog overlay (see below)

            Spacer(Modifier.height(16.dp))

            // Bottom controls
            Row(
                horizontalArrangement = Arrangement.spacedBy(24.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(bottom = 48.dp),
            ) {
                // Speaker button
                IconButton(
                    onClick = {
                        isSpeakerOn = !isSpeakerOn
                        voiceController.setSpeakerEnabled(isSpeakerOn)
                    },
                    modifier = Modifier
                        .size(48.dp)
                        .background(LitterTheme.surface, CircleShape),
                ) {
                    Icon(
                        Icons.Default.VolumeUp,
                        contentDescription = "Speaker",
                        tint = if (isSpeakerOn) LitterTheme.accent else LitterTheme.textMuted,
                    )
                }

                // End call button
                FloatingActionButton(
                    onClick = {
                        scope.launch {
                            voiceController.stopActiveVoiceSession(appModel)
                            onBack()
                        }
                    },
                    containerColor = LitterTheme.danger,
                    contentColor = Color.White,
                    modifier = Modifier.size(64.dp),
                ) {
                    Icon(Icons.Default.CallEnd, contentDescription = "End call")
                }

                // Mic button
                var isMicOn by remember { mutableStateOf(true) }
                IconButton(
                    onClick = {
                        if (!hasMicPermission) {
                            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        } else {
                            isMicOn = !isMicOn
                        }
                    },
                    modifier = Modifier
                        .size(48.dp)
                        .background(LitterTheme.surface, CircleShape),
                ) {
                    Icon(
                        if (isMicOn) Icons.Default.Mic else Icons.Default.MicOff,
                        contentDescription = "Microphone",
                        tint = if (isMicOn) LitterTheme.accent else LitterTheme.textMuted,
                    )
                }
            }
        }
    }

    // API key dialog — saves on the LOCAL server (threadKey.serverId), then stops + restarts session
    if (needsApiKey) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { },
            title = { Text("API Key Required", color = LitterTheme.textPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "Enter your OpenAI API key to use realtime voice.",
                        color = LitterTheme.textSecondary,
                        fontSize = 13.sp,
                    )
                    androidx.compose.material3.OutlinedTextField(
                        value = apiKey,
                        onValueChange = { apiKey = it },
                        label = { Text("API Key") },
                        placeholder = { Text("sk-...") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                androidx.compose.material3.Button(
                    onClick = {
                        if (apiKey.isBlank()) return@Button
                        if (server?.isLocal != true) return@Button
                        isSavingKey = true
                        scope.launch {
                            try {
                                // Save API key on THIS server (local)
                                android.util.Log.i("VoiceScreen", "Saving API key on server ${threadKey.serverId}")
                                appModel.rpc.loginAccount(
                                    threadKey.serverId,
                                    uniffi.codex_mobile_client.LoginAccountParams.ApiKey(apiKey = apiKey.trim()),
                                )
                                // Verify it saved
                                appModel.rpc.getAccount(
                                    threadKey.serverId,
                                    uniffi.codex_mobile_client.GetAccountParams(refreshToken = false),
                                )
                                appModel.refreshSnapshot()

                                // Stop current session, wait, restart (matching iOS saveApiKeyAndRetry)
                                android.util.Log.i("VoiceScreen", "API key saved, restarting voice session")
                                voiceController.stopActiveVoiceSession(appModel)
                                kotlinx.coroutines.delay(150)
                                voiceController.startVoiceOnThread(appModel, threadKey)
                                apiKey = ""
                            } catch (e: Exception) {
                                android.util.Log.e("VoiceScreen", "Save API key failed", e)
                            }
                            isSavingKey = false
                        }
                    },
                    enabled = apiKey.isNotBlank() && !isSavingKey,
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.accent,
                        contentColor = Color.Black,
                    ),
                ) {
                    if (isSavingKey) {
                        androidx.compose.material3.CircularProgressIndicator(
                            modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = Color.Black,
                        )
                    } else {
                        Text("Save & Connect")
                    }
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = onBack) {
                    Text("Cancel", color = LitterTheme.textSecondary)
                }
            },
        )
    }
}

/**
 * Radial edge glow effect synced to audio levels.
 */
@Composable
private fun EdgeGlow(inputLevel: Float, outputLevel: Float, phase: AppVoiceSessionPhase) {
    val transition = rememberInfiniteTransition(label = "glow")
    val pulse by transition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            tween(1500, easing = LinearEasing),
            RepeatMode.Reverse,
        ),
        label = "pulse",
    )

    val glowColor = when (phase) {
        AppVoiceSessionPhase.LISTENING -> LitterTheme.accent
        AppVoiceSessionPhase.SPEAKING -> Color(0xFF4A9EFF)
        AppVoiceSessionPhase.THINKING -> Color(0xFFFFB74D)
        else -> LitterTheme.accent
    }

    val intensity = maxOf(inputLevel, outputLevel) * pulse

    Canvas(modifier = Modifier.fillMaxSize()) {
        // Bottom glow (input)
        if (inputLevel > 0.01f) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        glowColor.copy(alpha = inputLevel * 0.4f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width / 2, size.height),
                    radius = size.width * 0.8f * intensity,
                ),
                center = Offset(size.width / 2, size.height),
                radius = size.width * 0.8f,
            )
        }

        // Top glow (output)
        if (outputLevel > 0.01f) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        glowColor.copy(alpha = outputLevel * 0.3f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width / 2, 0f),
                    radius = size.width * 0.6f * intensity,
                ),
                center = Offset(size.width / 2, 0f),
                radius = size.width * 0.6f,
            )
        }
    }
}
