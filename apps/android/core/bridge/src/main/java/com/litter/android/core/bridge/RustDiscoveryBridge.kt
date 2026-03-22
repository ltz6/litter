package com.litter.android.core.bridge

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.litter.android.core.network.DiscoveredServer
import com.litter.android.core.network.DiscoverySource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Discovery bridge that delegates to the Rust `scan_servers` implementation
 * via [RustMobileClient], supplemented by platform-native mDNS results from
 * Android's [NsdManager].
 *
 * This replaces the pure-Kotlin [com.litter.android.core.network.ServerDiscoveryService]
 * which performs its own Bonjour, Tailscale, ARP, and subnet scanning. The Rust
 * implementation handles Tailscale, subnet probing, and ARP internally; this bridge
 * adds Android-specific NSD (mDNS/Bonjour) results that the Rust layer cannot
 * access without platform APIs.
 *
 * ## Migration
 *
 * To switch from the legacy discovery service to this bridge:
 * 1. Replace `ServerDiscoveryService(context)` with `RustDiscoveryBridge(client, context)`.
 * 2. Call [discoverProgressive] the same way — the callback signature is identical.
 * 3. Once validated, the legacy `ServerDiscoveryService.kt` can be removed.
 */
class RustDiscoveryBridge(
    private val client: RustMobileClient,
    private val context: Context? = null,
) {
    /**
     * Run a full discovery scan. Results are delivered progressively via [onUpdate]
     * as they arrive from both the Rust scan and platform mDNS.
     *
     * The returned list is the final merged result set.
     */
    suspend fun discoverProgressive(
        onUpdate: (List<DiscoveredServer>) -> Unit,
    ): List<DiscoveredServer> = withContext(Dispatchers.IO) {
        val results = LinkedHashMap<String, DiscoveredServer>()

        // Always include static local/bundled entries up front.
        results["local"] = DiscoveredServer(
            id = "local",
            name = "On Device",
            host = "127.0.0.1",
            port = 8390,
            source = DiscoverySource.LOCAL,
            hasCodexServer = true,
        )
        results["bundled"] = DiscoveredServer(
            id = "bundled",
            name = "Bundled Server",
            host = "127.0.0.1",
            port = 4500,
            source = DiscoverySource.BUNDLED,
            hasCodexServer = true,
        )

        onUpdate(sortedServers(results.values))

        // Run Rust scan and platform mDNS in parallel.
        coroutineScope {
            val rustScan = async {
                runCatching { client.scanServers() }.getOrDefault(emptyList())
            }
            val nsdScan = async {
                runCatching { discoverNsd(timeoutMs = 5_000L) }.getOrDefault(emptyList())
            }

            // Merge Rust results first (they include Tailscale, subnet, ARP).
            val rustServers = rustScan.await()
            for (server in rustServers) {
                val discovered = toDiscoveredServer(server)
                if (discovered != null) {
                    upsert(results, discovered)
                }
            }
            onUpdate(sortedServers(results.values))

            // Merge platform mDNS results.
            val nsdServers = nsdScan.await()
            for (server in nsdServers) {
                upsert(results, server)
            }
            onUpdate(sortedServers(results.values))
        }

        sortedServers(results.values)
    }

    /**
     * Simple non-progressive scan. Returns the final merged list.
     */
    suspend fun discover(): List<DiscoveredServer> = discoverProgressive {}

    // -----------------------------------------------------------------------
    // Platform mDNS via NsdManager
    // -----------------------------------------------------------------------

    /**
     * Discover servers via Android NSD (mDNS/Bonjour).
     *
     * This feeds results that the Rust layer cannot obtain on its own because
     * Android's NSD APIs require a platform [Context] and [NsdManager].
     */
    private fun discoverNsd(timeoutMs: Long): List<DiscoveredServer> {
        val appContext = context ?: return emptyList()
        val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return emptyList()

        val sshCandidates = discoverNsdService(nsdManager, "_ssh._tcp.", timeoutMs, codexService = false)
        val codexCandidates = discoverNsdService(nsdManager, "_codex._tcp.", timeoutMs, codexService = true)

        // Merge: codex service results take priority over SSH-only results.
        val merged = LinkedHashMap<String, DiscoveredServer>()
        for (server in sshCandidates) {
            merged[server.id] = server
        }
        for (server in codexCandidates) {
            val existing = merged[server.id]
            if (existing == null || server.hasCodexServer) {
                merged[server.id] = server
            }
        }
        return merged.values.toList()
    }

    @Suppress("DEPRECATION")
    private fun discoverNsdService(
        nsdManager: NsdManager,
        serviceType: String,
        timeoutMs: Long,
        codexService: Boolean,
    ): List<DiscoveredServer> {
        val found = ConcurrentHashMap<String, DiscoveredServer>()
        val done = CountDownLatch(1)

        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                done.countDown()
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                done.countDown()
            }

            override fun onDiscoveryStarted(serviceType: String?) = Unit
            override fun onDiscoveryStopped(serviceType: String?) {
                done.countDown()
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                runCatching {
                    nsdManager.resolveService(
                        serviceInfo,
                        object : NsdManager.ResolveListener {
                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                            override fun onServiceResolved(resolved: NsdServiceInfo) {
                                val host = resolved.host?.hostAddress?.trim().orEmpty()
                                if (!isLikelyIpv4(host) || host == "127.0.0.1") return

                                val name = cleanHostName(resolved.serviceName).ifBlank { host }
                                val port = if (codexService && resolved.port > 0) resolved.port else null

                                found[host] = DiscoveredServer(
                                    id = "network-$host",
                                    name = name,
                                    host = host,
                                    port = port ?: 22,
                                    source = DiscoverySource.BONJOUR,
                                    hasCodexServer = port != null,
                                )
                            }
                        },
                    )
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
        }

        runCatching {
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
            done.await(timeoutMs, TimeUnit.MILLISECONDS)
            nsdManager.stopServiceDiscovery(listener)
        }

        return found.values.toList()
    }

    // -----------------------------------------------------------------------
    // Conversion and merge helpers
    // -----------------------------------------------------------------------

    private fun toDiscoveredServer(rust: RustDiscoveredServer): DiscoveredServer? {
        if (rust.host.isBlank() || rust.host == "127.0.0.1") return null

        val source = when (rust.source) {
            "bonjour", "mdns" -> DiscoverySource.BONJOUR
            "tailscale" -> DiscoverySource.TAILSCALE
            "lan", "arp", "subnet" -> DiscoverySource.LAN
            "ssh" -> DiscoverySource.SSH
            "manual" -> DiscoverySource.MANUAL
            else -> DiscoverySource.LAN
        }

        return DiscoveredServer(
            id = rust.id.ifBlank { "network-${rust.host}" },
            name = rust.name.ifBlank { rust.host },
            host = rust.host,
            port = rust.port,
            source = source,
            hasCodexServer = rust.port != 22,
        )
    }

    private fun upsert(results: MutableMap<String, DiscoveredServer>, server: DiscoveredServer) {
        val existing = results[server.id]
        if (existing == null) {
            results[server.id] = server
            return
        }

        val betterSource = sourceRank(server.source) < sourceRank(existing.source)
        val hasCodexUpgrade = server.hasCodexServer && !existing.hasCodexServer
        val betterName = existing.name == existing.host && server.name != server.host

        if (betterSource || hasCodexUpgrade || betterName) {
            results[server.id] = server
        }
    }

    private fun sortedServers(servers: Collection<DiscoveredServer>): List<DiscoveredServer> =
        servers.sortedWith(
            compareBy<DiscoveredServer> { sourceRank(it.source) }
                .thenBy { it.name.lowercase() },
        )

    private fun sourceRank(source: DiscoverySource): Int = when (source) {
        DiscoverySource.LOCAL -> 0
        DiscoverySource.BUNDLED -> 1
        DiscoverySource.BONJOUR -> 2
        DiscoverySource.TAILSCALE -> 3
        DiscoverySource.SSH -> 4
        DiscoverySource.LAN -> 5
        DiscoverySource.MANUAL -> 6
    }

    private fun isLikelyIpv4(value: String): Boolean {
        val chunks = value.split('.')
        if (chunks.size != 4) return false
        return chunks.all { chunk ->
            val n = chunk.toIntOrNull() ?: return@all false
            n in 0..255
        }
    }

    private fun cleanHostName(raw: String?): String {
        var value = raw?.trim().orEmpty()
        if (value.endsWith(".local", ignoreCase = true)) {
            value = value.substring(0, value.length - ".local".length)
        }
        if (value.endsWith('.')) {
            value = value.dropLast(1)
        }
        return value
    }
}
