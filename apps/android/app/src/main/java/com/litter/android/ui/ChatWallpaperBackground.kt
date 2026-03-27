package com.litter.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import uniffi.codex_mobile_client.ThreadKey

@Composable
fun ChatWallpaperBackground(
    threadKey: ThreadKey? = null,
    modifier: Modifier = Modifier,
) {
    WallpaperBackdrop(threadKey = threadKey, modifier = modifier.fillMaxSize())
}

@Composable
fun WallpaperBackdrop(
    threadKey: ThreadKey? = null,
    modifier: Modifier = Modifier,
) {
    // Read version to recompose when wallpaper prefs change
    @Suppress("UNUSED_VARIABLE")
    val ver = WallpaperManager.version
    val config = if (threadKey != null) WallpaperManager.resolvedConfig(threadKey) else null
    val bitmap = if (config != null) {
        WallpaperManager.resolvedBitmapForConfig(config, threadKey)
    } else {
        null
    }

    val isVideo = config?.type == WallpaperType.CUSTOM_VIDEO || config?.type == WallpaperType.VIDEO_URL
    val videoPath = if (isVideo) WallpaperManager.videoFilePath(threadKey) else null

    if (config != null && (bitmap != null || config.type == WallpaperType.SOLID_COLOR || (isVideo && videoPath != null))) {
        val blurRadius = (config.blur * 25f).dp
        val brightnessAlpha = config.brightness.coerceIn(0f, 1f)

        if (isVideo && videoPath != null) {
            Box(
                modifier = modifier
                    .blur(blurRadius)
                    .graphicsLayer { alpha = brightnessAlpha },
            ) {
                VideoWallpaperPlayer(
                    filePath = videoPath,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        } else if (config.type == WallpaperType.SOLID_COLOR) {
            val color = config.colorHex?.let { colorFromHex(it) }
                ?: LitterTheme.background
            Box(
                modifier = modifier
                    .background(color)
                    .graphicsLayer { alpha = brightnessAlpha },
            )
        } else if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = modifier
                    .blur(blurRadius)
                    .graphicsLayer { alpha = brightnessAlpha },
            )
        }
    } else {
        Box(
            modifier = modifier.background(LitterTheme.backgroundBrush),
        )
    }
}
