package com.litter.android.ui.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeIndexEntry
import com.litter.android.ui.LitterThemeManager
import com.litter.android.ui.WallpaperConfig
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.WallpaperScope
import com.litter.android.ui.WallpaperType
import com.litter.android.ui.colorFromHex
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey

@Composable
fun WallpaperSelectionScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
    onAdjust: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val themes = LitterThemeManager.themeIndex
    var previewConfig by remember { mutableStateOf(WallpaperManager.resolvedConfig(threadKey)) }

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        if (uri != null) {
            scope.launch {
                val success = WallpaperManager.setCustomImageFromUri(uri, WallpaperScope.Thread(threadKey))
                if (success) {
                    previewConfig = WallpaperConfig(type = WallpaperType.CUSTOM_IMAGE)
                    onAdjust()
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(LitterTheme.background)) {
        // Full-screen preview
        val previewBitmap = remember(previewConfig) {
            previewConfig?.let { WallpaperManager.resolvedBitmapForConfig(it, threadKey) }
        }
        if (previewBitmap != null) {
            Image(
                bitmap = previewBitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else if (previewConfig?.type == WallpaperType.SOLID_COLOR) {
            val color = previewConfig?.colorHex?.let { colorFromHex(it) } ?: LitterTheme.background
            Box(modifier = Modifier.fillMaxSize().background(color))
        } else {
            Box(modifier = Modifier.fillMaxSize().background(LitterTheme.background))
        }

        // Sample bubbles overlay
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.Center)
                .padding(horizontal = 32.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SampleBubble(
                text = "Can you help me refactor this module?",
                isUser = true,
            )
            SampleBubble(
                text = "Sure! I'll analyze the code structure and suggest improvements.",
                isUser = false,
            )
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
                text = "Select Wallpaper",
                color = LitterTheme.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        // Bottom card
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
            Text(
                text = "Select Theme",
                color = LitterTheme.textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(12.dp))

            // Theme thumbnails row
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(horizontal = 4.dp),
            ) {
                // No wallpaper option
                item {
                    ThemeThumbnail(
                        label = "None",
                        backgroundColor = LitterTheme.background,
                        accentColor = null,
                        isSelected = previewConfig == null || previewConfig?.type == WallpaperType.NONE,
                        isNone = true,
                        onClick = {
                            previewConfig = null
                            WallpaperManager.clearWallpaper(WallpaperScope.Thread(threadKey))
                        },
                    )
                }

                items(themes) { theme ->
                    val bg = colorFromHex(theme.backgroundHex)
                    val accent = colorFromHex(theme.accentHex)
                    ThemeThumbnail(
                        label = theme.name,
                        backgroundColor = bg,
                        accentColor = accent,
                        isSelected = previewConfig?.themeSlug == theme.slug,
                        onClick = {
                            val config = WallpaperConfig(
                                type = WallpaperType.THEME,
                                themeSlug = theme.slug,
                            )
                            previewConfig = config
                            // Temporarily set so preview updates
                            WallpaperManager.setWallpaper(config, WallpaperScope.Thread(threadKey))
                            onAdjust()
                        },
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            // Photo picker button
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                TextButton(
                    onClick = {
                        photoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                        )
                    },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(
                        Icons.Default.Image,
                        contentDescription = null,
                        tint = LitterTheme.accent,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Choose Photo",
                        color = LitterTheme.accent,
                        fontSize = 13.sp,
                    )
                }

                TextButton(
                    onClick = {
                        // Set a solid color wallpaper with the current theme accent
                        val hex = String.format("#%06X", 0xFFFFFF and LitterTheme.accent.toArgb())
                        val config = WallpaperConfig(
                            type = WallpaperType.SOLID_COLOR,
                            colorHex = hex,
                        )
                        previewConfig = config
                        WallpaperManager.setWallpaper(config, WallpaperScope.Thread(threadKey))
                        onAdjust()
                    },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(
                        Icons.Default.Palette,
                        contentDescription = null,
                        tint = LitterTheme.accent,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Set a Color",
                        color = LitterTheme.accent,
                        fontSize = 13.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun ThemeThumbnail(
    label: String,
    backgroundColor: Color,
    accentColor: Color?,
    isSelected: Boolean,
    isNone: Boolean = false,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(64.dp)
            .clickable(onClick = onClick),
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(backgroundColor)
                .then(
                    if (isSelected) {
                        Modifier.border(2.dp, LitterTheme.accent, RoundedCornerShape(10.dp))
                    } else {
                        Modifier.border(1.dp, LitterTheme.border, RoundedCornerShape(10.dp))
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (isNone) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = "No wallpaper",
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(20.dp),
                )
            } else if (accentColor != null) {
                // Mini pattern preview — draw dots
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(accentColor.copy(alpha = 0.5f)),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            text = label,
            color = if (isSelected) LitterTheme.accent else LitterTheme.textMuted,
            fontSize = 9.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SampleBubble(text: String, isUser: Boolean) {
    val bgColor = if (isUser) LitterTheme.accent.copy(alpha = 0.15f) else LitterTheme.surface.copy(alpha = 0.85f)
    val alignment = if (isUser) Alignment.End else Alignment.Start

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
