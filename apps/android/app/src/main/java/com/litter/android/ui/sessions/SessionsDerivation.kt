package com.litter.android.ui.sessions

import com.litter.android.ui.home.HomeDashboardSupport
import uniffi.codex_mobile_client.AppSessionSummary

/**
 * Tree node for session fork relationships.
 */
data class SessionTreeNode(
    val summary: AppSessionSummary,
    val children: List<SessionTreeNode>,
    val depth: Int,
)

/**
 * Sessions grouped by (server, workspace).
 */
data class WorkspaceSessionGroup(
    val serverId: String,
    val serverName: String,
    val cwd: String,
    val workspaceLabel: String,
    val nodes: List<SessionTreeNode>,
    val latestUpdate: Long,
)

data class SessionsDerivedData(
    val groups: List<WorkspaceSessionGroup>,
    val totalCount: Int,
    val filteredCount: Int,
)

enum class WorkspaceSortMode { RECENT, NAME, DATE }

/**
 * Pure functions for deriving session tree structure from flat AppSessionSummary list.
 * Operates on Rust-provided data — no business logic duplication.
 */
object SessionsDerivation {

    fun derive(
        summaries: List<AppSessionSummary>,
        serverFilter: String? = null,
        forkOnly: Boolean = false,
        searchQuery: String = "",
        sortMode: WorkspaceSortMode = WorkspaceSortMode.RECENT,
    ): SessionsDerivedData {
        val totalCount = summaries.size

        // Filter
        var filtered = summaries.toList()
        if (serverFilter != null) {
            filtered = filtered.filter { it.key.serverId == serverFilter }
        }
        if (forkOnly) {
            filtered = filtered.filter { it.isFork }
        }
        if (searchQuery.isNotBlank()) {
            val q = searchQuery.lowercase()
            filtered = filtered.filter { s ->
                (s.title?.lowercase()?.contains(q) == true) ||
                    (s.cwd?.lowercase()?.contains(q) == true) ||
                    (s.model?.lowercase()?.contains(q) == true) ||
                    (s.agentDisplayLabel?.lowercase()?.contains(q) == true) ||
                    s.serverDisplayName.lowercase().contains(q)
            }
        }

        val filteredCount = filtered.size

        // Build parent→children map
        val byThreadId = filtered.associateBy { it.key.threadId }
        val childrenMap = mutableMapOf<String, MutableList<AppSessionSummary>>()
        val roots = mutableListOf<AppSessionSummary>()

        for (session in filtered) {
            val parentId = session.parentThreadId
            if (parentId != null && parentId in byThreadId) {
                childrenMap.getOrPut(parentId) { mutableListOf() }.add(session)
            } else {
                roots.add(session)
            }
        }

        // Build trees from roots
        fun buildTree(summary: AppSessionSummary, depth: Int): SessionTreeNode {
            val children = childrenMap[summary.key.threadId]
                ?.sortedByDescending { it.updatedAt ?: 0L }
                ?.map { buildTree(it, depth + 1) }
                ?: emptyList()
            return SessionTreeNode(summary, children, depth)
        }

        // Group by workspace (serverId + normalized cwd)
        val groupMap = mutableMapOf<String, MutableList<SessionTreeNode>>()
        val groupMeta = mutableMapOf<String, Triple<String, String, String>>() // key → (serverId, serverName, cwd)

        for (root in roots) {
            val cwd = normalizedCwd(root.cwd)
            val groupKey = "${root.key.serverId}|$cwd"
            groupMap.getOrPut(groupKey) { mutableListOf() }.add(buildTree(root, 0))
            if (groupKey !in groupMeta) {
                groupMeta[groupKey] = Triple(root.key.serverId, root.serverDisplayName, root.cwd ?: "~")
            }
        }

        // Build groups
        val groups = groupMap.map { (key, nodes) ->
            val (serverId, serverName, cwd) = groupMeta[key]!!
            val latestUpdate = nodes.maxOfLatest()
            WorkspaceSessionGroup(
                serverId = serverId,
                serverName = serverName,
                cwd = cwd,
                workspaceLabel = HomeDashboardSupport.workspaceLabel(cwd),
                nodes = nodes.sortedByDescending { it.summary.updatedAt ?: 0L },
                latestUpdate = latestUpdate,
            )
        }

        // Sort groups
        val sortedGroups = when (sortMode) {
            WorkspaceSortMode.RECENT -> groups.sortedByDescending { it.latestUpdate }
            WorkspaceSortMode.NAME -> groups.sortedBy { it.workspaceLabel.lowercase() }
            WorkspaceSortMode.DATE -> groups.sortedByDescending { it.latestUpdate }
        }

        return SessionsDerivedData(
            groups = sortedGroups,
            totalCount = totalCount,
            filteredCount = filteredCount,
        )
    }

    fun normalizedCwd(cwd: String?): String {
        if (cwd.isNullOrBlank()) return "~"
        return cwd.trimEnd('/').lowercase()
    }

    /** Recursively find latest updatedAt across all nodes. */
    private fun List<SessionTreeNode>.maxOfLatest(): Long {
        var max = 0L
        for (node in this) {
            val t = node.summary.updatedAt ?: 0L
            if (t > max) max = t
            val childMax = node.children.maxOfLatest()
            if (childMax > max) max = childMax
        }
        return max
    }
}
