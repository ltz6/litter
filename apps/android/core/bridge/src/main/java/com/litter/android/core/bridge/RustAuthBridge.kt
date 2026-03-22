package com.litter.android.core.bridge

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject

// ---------------------------------------------------------------------------
// Rust AuthStorage trait — Kotlin-side implementation
//
// Maps to the `AuthStorage` trait defined in
// `shared/rust-bridge/codex-mobile-client/src/auth.rs`:
//
//   pub trait AuthStorage: Send + Sync {
//       fn store(&self, server_id: &str, credentials: StoredCredentials) -> Result<(), String>;
//       fn load(&self, server_id: &str) -> Result<Option<StoredCredentials>, String>;
//       fn delete(&self, server_id: &str) -> Result<(), String>;
//       fn list_server_ids(&self) -> Result<Vec<String>, String>;
//   }
//
// Currently the Rust FFI creates an `InMemoryAuthStorage` on init. Once the
// JNI bridge is extended to accept an external storage callback, this class
// will be registered as the platform storage implementation, replacing the
// in-memory default with encrypted on-disk persistence.
// ---------------------------------------------------------------------------

/**
 * Mirrors the Rust `AuthMethod` enum.
 */
enum class RustAuthMethod(val wire: String) {
    NONE("None"),
    API_KEY("ApiKey"),
    CHATGPT_OAUTH("ChatGptOAuth"),
    ;

    companion object {
        fun from(value: String): RustAuthMethod =
            entries.firstOrNull { it.wire == value } ?: NONE
    }
}

/**
 * Mirrors the Rust `StoredCredentials` struct.
 */
data class RustStoredCredentials(
    val method: RustAuthMethod,
    val apiKey: String? = null,
    val accessToken: String? = null,
    val refreshToken: String? = null,
    val expiresAt: Long? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("method", method.wire)
        put("apiKey", apiKey ?: JSONObject.NULL)
        put("accessToken", accessToken ?: JSONObject.NULL)
        put("refreshToken", refreshToken ?: JSONObject.NULL)
        put("expiresAt", expiresAt ?: JSONObject.NULL)
    }

    companion object {
        fun fromJson(obj: JSONObject): RustStoredCredentials =
            RustStoredCredentials(
                method = RustAuthMethod.from(obj.optString("method", "None")),
                apiKey = obj.optString("apiKey", null),
                accessToken = obj.optString("accessToken", null),
                refreshToken = obj.optString("refreshToken", null),
                expiresAt = if (obj.has("expiresAt") && !obj.isNull("expiresAt")) obj.getLong("expiresAt") else null,
            )
    }
}

/**
 * Mirrors the Rust `AuthState` enum.
 */
sealed class RustAuthState {
    data object Unknown : RustAuthState()
    data object NotAuthenticated : RustAuthState()
    data class Authenticating(val method: RustAuthMethod) : RustAuthState()
    data class Authenticated(val method: RustAuthMethod, val email: String? = null, val name: String? = null, val plan: String? = null) : RustAuthState()
    data class AuthFailed(val error: String, val method: RustAuthMethod) : RustAuthState()
    data class TokenExpired(val email: String? = null, val name: String? = null, val plan: String? = null) : RustAuthState()

    companion object {
        fun fromJson(obj: JSONObject): RustAuthState {
            val type = obj.optString("type", "Unknown")
            return when (type) {
                "NotAuthenticated" -> NotAuthenticated
                "Authenticating" -> Authenticating(
                    method = RustAuthMethod.from(obj.optString("method", "None")),
                )
                "Authenticated" -> Authenticated(
                    method = RustAuthMethod.from(obj.optString("method", "None")),
                    email = obj.optString("email", null),
                    name = obj.optString("name", null),
                    plan = obj.optString("plan", null),
                )
                "AuthFailed" -> AuthFailed(
                    error = obj.optString("error", ""),
                    method = RustAuthMethod.from(obj.optString("method", "None")),
                )
                "TokenExpired" -> TokenExpired(
                    email = obj.optString("email", null),
                    name = obj.optString("name", null),
                    plan = obj.optString("plan", null),
                )
                else -> Unknown
            }
        }
    }
}

// ---------------------------------------------------------------------------
// EncryptedSharedPreferences-backed AuthStorage
//
// This is the Android-side implementation of the Rust `AuthStorage` trait.
// It stores `StoredCredentials` as JSON blobs in EncryptedSharedPreferences,
// keyed by server_id.
//
// This storage class will be wired into the Rust MobileClient once the JNI
// init function is extended to accept an external storage callback. Until
// then, the RustAuthBridge uses it locally and the Rust side uses
// InMemoryAuthStorage — meaning credentials set through the bridge are
// persisted on the Android side but the Rust MobileClient must be re-informed
// on each app launch.
// ---------------------------------------------------------------------------

/**
 * EncryptedSharedPreferences implementation of the Rust `AuthStorage` trait.
 *
 * Persists [RustStoredCredentials] as encrypted JSON blobs. Each server_id
 * maps to a single JSON string in the preference file.
 */
class EncryptedAuthStorage(context: Context) {

    private val prefs: SharedPreferences? =
        runCatching {
            val appContext = context.applicationContext
            val masterKey =
                MasterKey
                    .Builder(appContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
            EncryptedSharedPreferences.create(
                appContext,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrNull()

    val isAvailable: Boolean get() = prefs != null

    /** Store credentials for a server. Maps to `AuthStorage::store`. */
    fun store(serverId: String, credentials: RustStoredCredentials) {
        val prefs = prefs ?: return
        prefs.edit()
            .putString(keyFor(serverId), credentials.toJson().toString())
            .apply()
    }

    /** Load credentials for a server. Maps to `AuthStorage::load`. */
    fun load(serverId: String): RustStoredCredentials? {
        val prefs = prefs ?: return null
        val raw = prefs.getString(keyFor(serverId), null) ?: return null
        return runCatching {
            RustStoredCredentials.fromJson(JSONObject(raw))
        }.getOrNull()
    }

    /** Delete credentials for a server. Maps to `AuthStorage::delete`. */
    fun delete(serverId: String) {
        val prefs = prefs ?: return
        prefs.edit().remove(keyFor(serverId)).apply()
    }

    /** List all server IDs with stored credentials. Maps to `AuthStorage::list_server_ids`. */
    fun listServerIds(): List<String> {
        val prefs = prefs ?: return emptyList()
        return prefs.all.keys
            .filter { it.startsWith(KEY_PREFIX) }
            .map { it.removePrefix(KEY_PREFIX) }
    }

    private fun keyFor(serverId: String): String = "$KEY_PREFIX$serverId"

    private companion object {
        private const val PREFS_NAME = "rust_auth_storage_secure"
        private const val KEY_PREFIX = "auth:"
    }
}

// ---------------------------------------------------------------------------
// RustAuthBridge — high-level auth facade
//
// Bridges the Rust MobileAuthManager through RustMobileClient, combining:
//   1. Persistent encrypted storage (EncryptedAuthStorage)
//   2. RPC calls to Rust for state-machine transitions
//   3. Migration path from BundledAuthStore / SavedServerCredentialStore
//
// Auth methods exposed:
//   - checkAuth(serverId)       -> RustAuthState
//   - setApiKey(serverId, key)  -> Unit
//   - startOAuth(serverId)      -> String (authorize URL)
//   - completeOAuth(serverId, redirectUrl) -> RustAuthState
//   - logout(serverId)          -> Unit
//
// NOTE: `startOAuth` and `completeOAuth` require the Rust FFI dispatch to be
// extended with "check_auth", "start_oauth", "complete_oauth", and "logout"
// methods. Until that wiring is complete, these methods will throw from the
// Rust side with "unknown method". The `setApiKey` method is already wired.
// ---------------------------------------------------------------------------

/**
 * High-level auth bridge that routes auth operations through [RustMobileClient]
 * and persists credentials locally via [EncryptedAuthStorage].
 *
 * This class is the Android replacement for the combination of:
 * - [com.litter.android.state.BundledAuthStore] (OAuth tokens)
 * - [com.litter.android.state.SavedServerCredentialStore] (server user/pass)
 *
 * SSH credentials ([com.litter.android.state.SshCredentialStore]) remain
 * separate as they are not part of the Rust auth model.
 *
 * ## Dependencies kept
 * - `androidx.security:security-crypto` — still used for [EncryptedAuthStorage].
 *
 * ## Dependencies replaced
 * - The separate `bundled_auth_tokens` and `litter_saved_server_credentials_secure`
 *   EncryptedSharedPreferences files are unified into a single `rust_auth_storage_secure`
 *   preference file with a structured JSON schema matching Rust's `StoredCredentials`.
 */
class RustAuthBridge(
    context: Context,
    private val client: RustMobileClient,
) {
    private val storage = EncryptedAuthStorage(context)

    /** Whether the encrypted storage backend initialized successfully. */
    val isStorageAvailable: Boolean get() = storage.isAvailable

    // -- Public API -------------------------------------------------------

    /**
     * Check the authentication state for a server.
     *
     * Delegates to Rust `MobileAuthManager::check_auth` via the `check_auth`
     * RPC method. Also syncs any locally-persisted credentials into Rust if
     * the Rust side reports `NotAuthenticated` but we have stored credentials.
     *
     * NOTE: Requires the Rust FFI dispatch to handle "check_auth". Until then,
     * falls back to local storage inspection.
     */
    suspend fun checkAuth(serverId: String): RustAuthState {
        // Try Rust-side check first.
        return try {
            val result = client.call(
                "check_auth",
                JSONObject().put("server_id", serverId),
            )
            RustAuthState.fromJson(result)
        } catch (_: Exception) {
            // Fallback: inspect local storage directly.
            val creds = storage.load(serverId)
            if (creds != null) {
                if (creds.expiresAt != null && creds.expiresAt <= System.currentTimeMillis() / 1000) {
                    RustAuthState.TokenExpired()
                } else {
                    RustAuthState.Authenticated(method = creds.method)
                }
            } else {
                RustAuthState.NotAuthenticated
            }
        }
    }

    /**
     * Set an API key for a server.
     *
     * Persists the key in local encrypted storage AND sends it to the Rust
     * MobileClient via the already-wired `set_api_key` RPC method.
     */
    suspend fun setApiKey(serverId: String, key: String) {
        // Persist locally for cross-launch durability.
        storage.store(
            serverId,
            RustStoredCredentials(
                method = RustAuthMethod.API_KEY,
                apiKey = key,
            ),
        )

        // Inform the Rust side (this RPC is already wired in dispatch_method).
        client.setApiKey(serverId, key)
    }

    /**
     * Start an OAuth flow for a server.
     *
     * Returns the authorization URL that should be opened in a browser or
     * WebView. The Rust side transitions the server to `Authenticating` state.
     *
     * NOTE: Requires the Rust FFI dispatch to handle "start_oauth".
     *
     * @return The OAuth authorization URL.
     * @throws IllegalStateException if the Rust call fails.
     */
    suspend fun startOAuth(serverId: String): String {
        val result = client.call(
            "start_oauth",
            JSONObject().put("server_id", serverId),
        )
        return result.optString("url", "")
    }

    /**
     * Complete an OAuth flow by providing the redirect URL containing tokens.
     *
     * Parses the redirect URL on the Rust side, persists credentials, and
     * transitions to `Authenticated`. Also saves credentials to local
     * encrypted storage for cross-launch persistence.
     *
     * NOTE: Requires the Rust FFI dispatch to handle "complete_oauth".
     *
     * @return The resulting auth state.
     * @throws IllegalStateException if the Rust call fails.
     */
    suspend fun completeOAuth(serverId: String, redirectUrl: String): RustAuthState {
        val result = client.call(
            "complete_oauth",
            JSONObject().apply {
                put("server_id", serverId)
                put("redirect_url", redirectUrl)
            },
        )

        // Persist the resulting credentials locally as well.
        val accessToken = result.optString("accessToken", null)
        val refreshToken = result.optString("refreshToken", null)
        val expiresAt = if (result.has("expiresAt") && !result.isNull("expiresAt")) result.getLong("expiresAt") else null
        if (accessToken != null) {
            storage.store(
                serverId,
                RustStoredCredentials(
                    method = RustAuthMethod.CHATGPT_OAUTH,
                    accessToken = accessToken,
                    refreshToken = refreshToken,
                    expiresAt = expiresAt,
                ),
            )
        }

        return RustAuthState.fromJson(result)
    }

    /**
     * Log out of a server.
     *
     * Deletes credentials from both local encrypted storage and the Rust
     * MobileAuthManager.
     *
     * NOTE: Requires the Rust FFI dispatch to handle "logout".
     */
    suspend fun logout(serverId: String) {
        // Clear local storage first.
        storage.delete(serverId)

        // Inform Rust side.
        try {
            client.call(
                "logout",
                JSONObject().put("server_id", serverId),
            )
        } catch (_: Exception) {
            // Best-effort: local storage was already cleared.
        }
    }

    // -- Migration helpers ------------------------------------------------

    /**
     * Migrate credentials from the legacy [BundledAuthStore] format.
     *
     * Call this once during app startup to import any existing OAuth tokens
     * into the unified Rust auth storage. After migration, the legacy store
     * can be cleared.
     *
     * @param accessToken  The legacy access token.
     * @param refreshToken The legacy refresh token (nullable).
     * @param serverId     The server to associate these credentials with.
     */
    fun migrateFromBundledAuth(
        serverId: String,
        accessToken: String,
        refreshToken: String?,
    ) {
        if (storage.load(serverId) != null) return // Already migrated.

        storage.store(
            serverId,
            RustStoredCredentials(
                method = RustAuthMethod.CHATGPT_OAUTH,
                accessToken = accessToken,
                refreshToken = refreshToken,
            ),
        )
    }

    /**
     * Migrate credentials from the legacy [SavedServerCredentialStore] format.
     *
     * Server username/password pairs are stored as API keys in the new unified
     * storage (the Rust auth model treats direct credentials as API key auth).
     *
     * @param serverId The server ID.
     * @param password The server password / API key.
     */
    fun migrateFromSavedServerCredentials(
        serverId: String,
        password: String,
    ) {
        if (storage.load(serverId) != null) return // Already migrated.

        storage.store(
            serverId,
            RustStoredCredentials(
                method = RustAuthMethod.API_KEY,
                apiKey = password,
            ),
        )
    }

    /**
     * Re-hydrate the Rust MobileClient with all locally persisted credentials.
     *
     * Should be called after [RustMobileClient.init] to push any credentials
     * that survived across app launches into the (initially empty) Rust
     * in-memory auth storage.
     */
    suspend fun rehydrateRustClient() {
        for (serverId in storage.listServerIds()) {
            val creds = storage.load(serverId) ?: continue
            try {
                when (creds.method) {
                    RustAuthMethod.API_KEY -> {
                        val key = creds.apiKey ?: continue
                        client.setApiKey(serverId, key)
                    }
                    RustAuthMethod.CHATGPT_OAUTH -> {
                        // TODO: Once the Rust FFI exposes a "restore_credentials" method,
                        // push the full StoredCredentials back. For now OAuth tokens cannot
                        // be re-hydrated into Rust's InMemoryAuthStorage without an
                        // additional dispatch method.
                    }
                    RustAuthMethod.NONE -> { /* nothing to restore */ }
                }
            } catch (e: Exception) {
                // Best-effort: skip this server on failure.
            }
        }
    }
}
