package com.litter.android.ui.settings

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.WallpaperConfig
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.WallpaperScope
import com.litter.android.ui.WallpaperType
import com.litter.android.ui.colorFromHex
import uniffi.codex_mobile_client.ThreadKey

@Composable
fun WallpaperAdjustScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
    onApplied: () -> Unit,
) {
    val currentConfig = WallpaperManager.resolvedConfig(threadKey)
    var blur by remember { mutableFloatStateOf(currentConfig?.blur ?: 0f) }
    var brightness by remember { mutableFloatStateOf(currentConfig?.brightness ?: 1f) }
    var motionEnabled by remember { mutableStateOf(currentConfig?.motionEnabled ?: false) }
    val isBlurred = blur > 0.01f

    val previewBitmap = remember(currentConfig) {
        currentConfig?.let { WallpaperManager.resolvedBitmapForConfig(it, threadKey) }
    }

    Box(modifier = Modifier.fillMaxSize().background(LitterTheme.background)) {
        // Live preview with effects
        val blurRadius = (blur * 25f).dp
        val brightnessAlpha = brightness.coerceIn(0f, 1f)

        if (previewBitmap != null) {
            Image(
                bitmap = previewBitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxSize()
                    .then(if (blurRadius > 0.dp) Modifier.blur(blurRadius) else Modifier)
                    .graphicsLayer { alpha = brightnessAlpha },
            )
        } else if (currentConfig?.type == WallpaperType.SOLID_COLOR) {
            val color = currentConfig.colorHex?.let { colorFromHex(it) } ?: LitterTheme.background
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(color)
                    .graphicsLayer { alpha = brightnessAlpha },
            )
        }

        // Sample bubbles
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.Center)
                .padding(horizontal = 32.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SampleBubble("Can you help me refactor this module?", isUser = true)
            SampleBubble("Sure! I'll analyze the code structure.", isUser = false)
        }

        // Top bar
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .background(LitterTheme.surface.copy(alpha = 0.85f))
                .padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Adjust Wallpaper",
                color = LitterTheme.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        // Bottom controls
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .background(
                    LitterTheme.surface.copy(alpha = 0.95f),
                    RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                )
                .padding(16.dp),
        ) {
            // Checkboxes
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = isBlurred,
                        onCheckedChange = { checked ->
                            blur = if (checked) 0.5f else 0f
                        },
                        colors = CheckboxDefaults.colors(
                            checkedColor = LitterTheme.accent,
                            uncheckedColor = LitterTheme.textMuted,
                        ),
                    )
                    Text("Blurred", color = LitterTheme.textPrimary, fontSize = 13.sp)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = motionEnabled,
                        onCheckedChange = { motionEnabled = it },
                        colors = CheckboxDefaults.colors(
                            checkedColor = LitterTheme.accent,
                            uncheckedColor = LitterTheme.textMuted,
                        ),
                    )
                    Text("Motion", color = LitterTheme.textPrimary, fontSize = 13.sp)
                }
            }

            Spacer(Modifier.height(12.dp))

            // Brightness slider
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("\u2600", fontSize = 14.sp, color = LitterTheme.textMuted) // dim sun
                Slider(
                    value = brightness,
                    onValueChange = { brightness = it },
                    valueRange = 0.2f..1f,
                    modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                    colors = SliderDefaults.colors(
                        thumbColor = LitterTheme.accent,
                        activeTrackColor = LitterTheme.accent,
                        inactiveTrackColor = LitterTheme.border,
                    ),
                )
                Text("\u2600", fontSize = 20.sp, color = LitterTheme.textPrimary) // bright sun
            }

            Spacer(Modifier.height(16.dp))

            // Apply buttons
            Button(
                onClick = {
                    val config = currentConfig?.copy(
                        blur = blur,
                        brightness = brightness,
                        motionEnabled = motionEnabled,
                    ) ?: return@Button
                    WallpaperManager.setWallpaper(config, WallpaperScope.Thread(threadKey))
                    onApplied()
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.accent,
                    contentColor = LitterTheme.onAccentStrong,
                ),
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Apply for This Thread", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }

            Spacer(Modifier.height(8.dp))

            Button(
                onClick = {
                    val config = currentConfig?.copy(
                        blur = blur,
                        brightness = brightness,
                        motionEnabled = motionEnabled,
                    ) ?: return@Button
                    WallpaperManager.setWallpaper(config, WallpaperScope.Server(threadKey.serverId))
                    onApplied()
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.surface,
                    contentColor = LitterTheme.textPrimary,
                ),
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Apply for This Server", fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun SampleBubble(text: String, isUser: Boolean) {
    val bgColor = if (isUser) LitterTheme.accent.copy(alpha = 0.15f) else LitterTheme.surface.copy(alpha = 0.85f)

    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Text(
            text = text,
            color = LitterTheme.textPrimary,
            fontSize = 13.sp,
            modifier = Modifier
                .background(bgColor, RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}
