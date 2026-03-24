package com.litter.android.state

import uniffi.codex_mobile_client.SshBridge
import java.util.concurrent.ConcurrentHashMap

/**
 * Thread-safe tracking of SSH session IDs per server.
 * Allows cleanup of SSH sessions on server disconnect.
 */
class SshSessionStore(private val ssh: SshBridge) {
    private val sessions = ConcurrentHashMap<String, String>() // serverId → sessionId

    fun record(serverId: String, sessionId: String) {
        sessions[serverId] = sessionId
    }

    fun clear(serverId: String) {
        sessions.remove(serverId)
    }

    suspend fun close(serverId: String) {
        val sessionId = sessions.remove(serverId) ?: return
        try {
            ssh.sshClose(sessionId)
        } catch (_: Exception) {
            // Best-effort cleanup
        }
    }

    fun activeSessionId(serverId: String): String? = sessions[serverId]
}
