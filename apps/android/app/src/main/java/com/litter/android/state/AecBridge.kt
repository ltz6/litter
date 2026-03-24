package com.litter.android.state

import android.media.audiofx.AcousticEchoCanceler
import java.util.concurrent.locks.ReentrantLock

/**
 * Android uses the platform echo canceller on the recorder session.
 * Render/capture methods remain as no-ops so the rest of the voice pipeline
 * can stay shared with the iOS-oriented flow.
 */
class AecBridge private constructor(
    private val effect: AcousticEchoCanceler?,
) {
    private val lock = ReentrantLock()

    companion object {
        fun attach(audioSessionId: Int): AecBridge? {
            if (!AcousticEchoCanceler.isAvailable()) return null
            val effect = AcousticEchoCanceler.create(audioSessionId) ?: return null
            runCatching { effect.enabled = true }
            return AecBridge(effect)
        }
    }

    fun analyzeRender(samples: FloatArray) {
        lock.lock()
        try {
            // Platform AEC is attached directly to the recorder session.
        } finally {
            lock.unlock()
        }
    }

    fun processCapture(samples: FloatArray): FloatArray {
        lock.lock()
        try {
            return samples
        } finally {
            lock.unlock()
        }
    }

    fun release() {
        runCatching { effect?.release() }
    }
}
