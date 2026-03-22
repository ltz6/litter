package com.litter.android.core.bridge

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * SSH bootstrap bridge that delegates to the Rust `MobileClient` via
 * [RustMobileClient.call] for SSH connections and remote server startup.
 *
 * This replaces the pure-Kotlin [com.litter.android.state.SshSessionManager]
 * which uses JSch for SSH transport. The Rust implementation handles:
 * - SSH connection (password and key auth)
 * - Host key verification
 * - Remote codex/codex-app-server discovery
 * - Server process launch and port probing
 *
 * ## Migration
 *
 * To switch from the legacy SSH manager to this bridge:
 * 1. Replace `SshSessionManager()` with `RustSshBridge(client)`.
 * 2. Call [connect] + [startRemoteServer] the same way.
 * 3. Once validated, the legacy `SshSessionManager.kt` and the JSch dependency
 *    in `apps/android/app/build.gradle.kts` can be removed:
 *    ```
 *    // Remove this line from build.gradle.kts:
 *    // implementation("com.github.mwiede:jsch:0.2.22")
 *    ```
 *
 * ## Host Key Verification
 *
 * The legacy JSch implementation sets `StrictHostKeyChecking=no`. This bridge
 * supports an optional [hostKeyVerifier] callback that can prompt the user to
 * accept unknown host keys. If not provided, all host keys are accepted
 * (matching legacy behavior).
 */
class RustSshBridge(
    private val client: RustMobileClient,
    private val hostKeyVerifier: HostKeyVerifier? = null,
) {
    /**
     * Callback interface for host key verification.
     *
     * Implementations should show a dialog to the user and return `true` to
     * accept or `false` to reject the connection.
     */
    fun interface HostKeyVerifier {
        /**
         * Verify an SSH host key.
         *
         * @param host the remote hostname or IP
         * @param port the SSH port
         * @param keyType the key algorithm (e.g. "ssh-ed25519", "ssh-rsa")
         * @param fingerprint the key fingerprint (SHA-256 hash)
         * @return `true` to accept the key, `false` to reject
         */
        suspend fun verify(host: String, port: Int, keyType: String, fingerprint: String): Boolean
    }

    // -----------------------------------------------------------------------
    // Connection state
    // -----------------------------------------------------------------------

    private var connectedHost: String? = null
    private var connectedPort: Int? = null
    private var sshSessionId: String? = null

    val isConnected: Boolean get() = sshSessionId != null

    // -----------------------------------------------------------------------
    // SSH connect
    // -----------------------------------------------------------------------

    /**
     * Establish an SSH connection to the remote host.
     *
     * Delegates to the Rust `ssh_connect` method which handles the SSH handshake,
     * authentication, and session setup.
     *
     * @param host the remote hostname or IP address
     * @param port the SSH port (default 22)
     * @param username the SSH username
     * @param password the password (for password auth), or null for key auth
     * @param privateKeyPem the PEM-encoded private key (for key auth), or null
     * @param passphrase the key passphrase, or null
     * @throws RustSshException if the connection fails
     */
    suspend fun connect(
        host: String,
        port: Int = 22,
        username: String,
        password: String? = null,
        privateKeyPem: String? = null,
        passphrase: String? = null,
    ) = withContext(Dispatchers.IO) {
        // Disconnect any existing session first.
        runCatching { disconnect() }

        val params = JSONObject().apply {
            put("host", host.trim())
            put("port", port)
            put("username", username)
            if (password != null) {
                put("password", password)
            }
            if (privateKeyPem != null) {
                put("private_key_pem", privateKeyPem)
                if (passphrase != null) {
                    put("passphrase", passphrase)
                }
            }
            // Accept all host keys by default (matching legacy JSch behavior).
            // When a verifier is provided, the Rust side should invoke it via
            // a callback event; for now we set accept_host_key=true.
            put("accept_host_key", hostKeyVerifier == null)
        }

        try {
            val result = client.call("ssh_connect", params)
            sshSessionId = result.optString("session_id", null)
            connectedHost = host.trim()
            connectedPort = port
        } catch (e: Exception) {
            throw RustSshException(
                "Could not connect to $host:$port. Check SSH reachability and credentials.",
                e,
            )
        }
    }

    /**
     * Convenience method matching legacy [com.litter.android.state.SshCredentials] usage.
     *
     * Accepts the same credential sealed class and delegates to [connect].
     */
    suspend fun connect(
        host: String,
        port: Int = 22,
        credentials: SshCredentialParams,
    ) {
        when (credentials) {
            is SshCredentialParams.Password -> connect(
                host = host,
                port = port,
                username = credentials.username,
                password = credentials.password,
            )
            is SshCredentialParams.Key -> connect(
                host = host,
                port = port,
                username = credentials.username,
                privateKeyPem = credentials.privateKeyPem,
                passphrase = credentials.passphrase,
            )
        }
    }

    // -----------------------------------------------------------------------
    // Remote server bootstrap
    // -----------------------------------------------------------------------

    /**
     * Start a Codex app-server on the remote host via SSH.
     *
     * Delegates to the Rust `ssh_bootstrap` method which:
     * 1. Finds `codex` or `codex-app-server` on the remote PATH
     * 2. Starts the server on an available port (8390+)
     * 3. Waits for the server to begin accepting connections
     *
     * @return the port the remote server is listening on
     * @throws RustSshException if the server cannot be started
     */
    suspend fun startRemoteServer(): Int = withContext(Dispatchers.IO) {
        val sessionId = sshSessionId ?: throw RustSshException("SSH not connected.")

        val params = JSONObject().apply {
            put("session_id", sessionId)
            if (connectedHost?.contains(':') == true) {
                put("ipv6", true)
            }
        }

        try {
            val result = client.call("ssh_bootstrap", params)
            val port = result.optInt("port", -1)
            if (port <= 0) {
                throw RustSshException(
                    result.optString("error", "Remote server failed to start — no port returned."),
                )
            }
            port
        } catch (e: RustSshException) {
            throw e
        } catch (e: Exception) {
            throw RustSshException("Failed to start remote server.", e)
        }
    }

    // -----------------------------------------------------------------------
    // SSH exec (general purpose)
    // -----------------------------------------------------------------------

    /**
     * Execute a command on the remote host via SSH.
     *
     * @param command the shell command to execute
     * @param timeoutMs timeout in milliseconds
     * @return the command output (stdout)
     * @throws RustSshException if the command fails or SSH is not connected
     */
    suspend fun exec(command: String, timeoutMs: Int = 15_000): String = withContext(Dispatchers.IO) {
        val sessionId = sshSessionId ?: throw RustSshException("SSH not connected.")

        val params = JSONObject().apply {
            put("session_id", sessionId)
            put("command", command)
            put("timeout_ms", timeoutMs)
        }

        try {
            val result = client.call("ssh_exec", params)
            result.optString("stdout", "")
        } catch (e: Exception) {
            throw RustSshException("SSH command failed.", e)
        }
    }

    // -----------------------------------------------------------------------
    // Disconnect
    // -----------------------------------------------------------------------

    /**
     * Disconnect the SSH session.
     *
     * Safe to call multiple times.
     */
    suspend fun disconnect() = withContext(Dispatchers.IO) {
        val sessionId = sshSessionId ?: return@withContext
        sshSessionId = null
        connectedHost = null
        connectedPort = null

        runCatching {
            client.call("ssh_disconnect", JSONObject().put("session_id", sessionId))
        }
    }
}

/**
 * Credential parameters for SSH connections via [RustSshBridge].
 *
 * This mirrors [com.litter.android.state.SshCredentials] but is decoupled
 * from the JSch dependency.
 */
sealed class SshCredentialParams {
    data class Password(
        val username: String,
        val password: String,
    ) : SshCredentialParams()

    data class Key(
        val username: String,
        val privateKeyPem: String,
        val passphrase: String? = null,
    ) : SshCredentialParams()
}

/**
 * Exception type for Rust SSH bridge errors.
 *
 * Drop-in replacement for [com.litter.android.state.SshException].
 */
class RustSshException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
