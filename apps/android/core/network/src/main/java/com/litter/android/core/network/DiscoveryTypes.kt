package com.litter.android.core.network

/**
 * Source from which a server was discovered.
 */
enum class DiscoverySource {
    LOCAL,
    BUNDLED,
    BONJOUR,
    TAILSCALE,
    SSH,
    LAN,
    MANUAL,
}

/**
 * A server discovered during network scanning.
 */
data class DiscoveredServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: DiscoverySource,
    val hasCodexServer: Boolean = false,
)
