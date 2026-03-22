import Foundation
import ActivityKit
import Observation
import UIKit
import UserNotifications

// MARK: - ThreadResponseWithHydration convenience accessors

extension ThreadResponseWithHydration {
    /// Pre-hydrated conversation items decoded from the Rust hydration output.
    var hydratedItems: [ConversationItem] {
        RustConversationBridge.conversationItems(from: hydratedConversationItems)
    }
}

struct SkillMentionSelection: Equatable {
    let name: String
    let path: String
}

private extension ThreadItem {
    var threadItemId: String {
        switch self {
        case .userMessage(let id, _),
             .agentMessage(let id, _, _),
             .plan(let id, _),
             .reasoning(let id, _, _),
             .commandExecution(let id, _, _, _, _, _, _, _, _),
             .fileChange(let id, _, _),
             .mcpToolCall(let id, _, _, _, _, _, _, _),
             .dynamicToolCall(let id, _, _, _, _, _, _),
             .collabAgentToolCall(let id, _, _, _, _, _, _, _, _),
             .webSearch(let id, _, _),
             .imageView(let id, _),
             .imageGeneration(let id, _, _, _),
             .enteredReviewMode(let id, _),
             .exitedReviewMode(let id, _),
             .contextCompaction(let id):
            return id
        }
    }

    var isUserOrAgentMessage: Bool {
        switch self {
        case .userMessage, .agentMessage:
            return true
        default:
            return false
        }
    }

    var liveActivityLabel: String? {
        switch self {
        case .commandExecution(_, let command, _, _, _, _, _, _, _):
            return command
        case .dynamicToolCall(_, let tool, _, _, _, _, _):
            return tool
        case .mcpToolCall(_, let server, let tool, _, _, _, _, _):
            return server.isEmpty ? tool : "\(server).\(tool)"
        case .collabAgentToolCall(_, let tool, _, _, _, _, _, _, _):
            return tool.displayName
        case .webSearch(_, let query, _):
            return query.isEmpty ? "webSearch" : query
        case .fileChange:
            return "fileChange"
        case .plan:
            return "plan"
        case .reasoning:
            return "reasoning"
        case .imageView:
            return "imageView"
        case .imageGeneration:
            return "imageGeneration"
        case .enteredReviewMode:
            return "enteredReviewMode"
        case .exitedReviewMode:
            return "exitedReviewMode"
        case .contextCompaction:
            return "contextCompaction"
        case .userMessage, .agentMessage:
            return nil
        }
    }
}

private extension CollabAgentTool {
    var displayName: String {
        switch self {
        case .spawnAgent:
            return "spawnAgent"
        case .sendInput:
            return "sendInput"
        case .resumeAgent:
            return "resumeAgent"
        case .wait:
            return "wait"
        case .closeAgent:
            return "closeAgent"
        }
    }
}

private func extractString(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dict[key] as? String {
            return value
        }
        if let value = dict[key] as? NSNumber {
            return value.stringValue
        }
    }
    return nil
}

enum AgentLabelFormatter {
    static func format(
        nickname: String?,
        role: String?,
        fallbackIdentifier: String? = nil
    ) -> String? {
        let cleanNickname = sanitized(nickname)
        let cleanRole = sanitized(role)
        switch (cleanNickname, cleanRole) {
        case let (nickname?, role?):
            return "\(nickname) [\(role)]"
        case let (nickname?, nil):
            return nickname
        case let (nil, role?):
            return "[\(role)]"
        default:
            return sanitized(fallbackIdentifier)
        }
    }

    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func looksLikeDisplayLabel(_ raw: String?) -> Bool {
        guard let value = sanitized(raw),
              value.hasSuffix("]"),
              let openBracket = value.lastIndex(of: "[") else {
            return false
        }
        let nickname = value[..<openBracket].trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = value.index(after: openBracket)
        let roleEnd = value.index(before: value.endIndex)
        let role = value[roleStart..<roleEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return !nickname.isEmpty && !role.isEmpty
    }
}

@MainActor
@Observable
final class ServerManager: VoiceActions {
    static let shared = ServerManager()
    static let localServerID = "local"
    private static let persistedLocalVoiceThreadIDKey = "litter.voice.local.thread_id"

    var connections: [String: ServerConnection] = [:]
    var threads: [ThreadKey: ThreadState] = [:]
    var activeThreadKey: ThreadKey?
    var pendingApprovals: [PendingApproval] = []
    var pendingUserInputRequests: [PendingUserInputRequest] = []
    var composerPrefillRequest: ComposerPrefillRequest?
    var activeVoiceSession: VoiceSessionState?
    private(set) var agentDirectoryVersion: Int = 0
    private(set) var handoffThreadKeys: [String: ThreadKey] = [:]
    @ObservationIgnored var handoffModel: String?
    @ObservationIgnored var handoffEffort: String?
    @ObservationIgnored var handoffFastMode: Bool = false
    @ObservationIgnored private var voiceHandoffThreads: [String: ThreadKey] = [:]
    @ObservationIgnored private lazy var handoffManager = RustHandoffManager(localServerId: Self.localServerID)
    @ObservationIgnored private var handoffActionPollTask: Task<Void, Never>?

    @ObservationIgnored private let savedServersKey = "codex_saved_servers"
    @ObservationIgnored private var voiceHandoffThreads: [String: ThreadKey] = [:]
    private(set) var handoffThreadKeys: [String: ThreadKey] = [:]
    @ObservationIgnored var handoffModel: String?
    @ObservationIgnored var handoffEffort: String?
    @ObservationIgnored var handoffFastMode: Bool = false
    @ObservationIgnored private var liveItemMessageIndices: [ThreadKey: [String: Int]] = [:]
    @ObservationIgnored private var liveTurnDiffMessageIndices: [ThreadKey: [String: Int]] = [:]
    @ObservationIgnored private var serversUsingItemNotifications: Set<String> = []
    @ObservationIgnored private var threadTurnCounts: [ThreadKey: Int] = [:]
    @ObservationIgnored private var agentDirectory = AgentDirectory()
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    @ObservationIgnored private var ts: String { Self.tsFormatter.string(from: Date()) }
    @ObservationIgnored private var backgroundedTurnKeys: Set<ThreadKey> = []
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var bgWakeCount: Int = 0
    @ObservationIgnored private var liveActivities: [ThreadKey: Activity<CodexTurnAttributes>] = [:]
    @ObservationIgnored private var voiceCallActivity: Activity<CodexVoiceCallAttributes>?
    @ObservationIgnored private var liveActivityStartDates: [ThreadKey: Date] = [:]
    @ObservationIgnored private var liveActivityToolCallCounts: [ThreadKey: Int] = [:]
    @ObservationIgnored private var liveActivityOutputSnippets: [ThreadKey: String] = [:]
    @ObservationIgnored private var liveActivityLastUpdateTimes: [ThreadKey: CFAbsoluteTime] = [:]
    @ObservationIgnored private var liveActivityFileChangeCounts: [ThreadKey: Int] = [:]
    @ObservationIgnored private var notificationPermissionRequested = false
    @ObservationIgnored private var deferredThreadMetadataRefreshTasks: [ThreadKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var deferredThreadMetadataRefreshTokens: [ThreadKey: UUID] = [:]
    @ObservationIgnored private var deferredThreadMessageHydrationTasks: [ThreadKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var deferredSubagentIdentityHydrationTasks: [ThreadKey: Task<Void, Never>] = [:]
    @ObservationIgnored private let pushProxy = PushProxyClient()
    @ObservationIgnored private var pushProxyRegistrationId: String?
    @ObservationIgnored private var suppressNotifications = false
    @ObservationIgnored var devicePushToken: Data?
    @ObservationIgnored private let voiceSessionCoordinator = VoiceSessionCoordinator()
    @ObservationIgnored private var voiceInputDecayToken: UUID?
    @ObservationIgnored private var voiceOutputDecayToken: UUID?
    @ObservationIgnored private var voicePreviousActiveThreadKey: ThreadKey?
    @ObservationIgnored private var voiceStopRequestedThreadKey: ThreadKey?
    @ObservationIgnored private var lastHandledVoiceEndRequestToken: String?
    @ObservationIgnored private var lastRealtimeTranscriptDelta: [ThreadKey: (speaker: String, delta: String, timestamp: CFAbsoluteTime)] = [:]
    @ObservationIgnored private var pendingRealtimeMessageIDs: [ThreadKey: (user: String?, assistant: String?)] = [:]
    @ObservationIgnored private var notificationWorkTask: Task<Void, Never>?
    @ObservationIgnored private let networkMonitor = NetworkMonitor()
    @ObservationIgnored private let initialHydratedMessageCount = 48
    @ObservationIgnored private let hydrationChunkSize = 96
    private struct PersistedContextUsageSnapshot: Decodable {
        let contextTokens: Int64?
        let modelContextWindow: Int64?
    }

    private struct AgentDirectoryEntry: Equatable {
        var nickname: String?
        var role: String?
        var threadId: String?
        var agentId: String?

        func merged(over existing: AgentDirectoryEntry?) -> AgentDirectoryEntry {
            AgentDirectoryEntry(
                nickname: nickname ?? existing?.nickname,
                role: role ?? existing?.role,
                threadId: threadId ?? existing?.threadId,
                agentId: agentId ?? existing?.agentId
            )
        }
    }

    private struct AgentDirectory {
        var byThreadId: [String: AgentDirectoryEntry] = [:]
        var byAgentId: [String: AgentDirectoryEntry] = [:]

        mutating func removeServer(_ serverId: String) {
            let prefix = "\(serverId):"
            byThreadId = byThreadId.filter { !$0.key.hasPrefix(prefix) }
            byAgentId = byAgentId.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    init() {
        voiceSessionCoordinator.onEvent = { [weak self] event in
            self?.handleVoiceSessionCoordinatorEvent(event)
        }
        installVoiceSessionControlObserver()
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = CFNotificationName(VoiceSessionControl.endRequestDarwinNotification as CFString)
        CFNotificationCenterRemoveObserver(center, observer, name, nil)
    }

    enum ApprovalKind: String, Codable {
        case commandExecution
        case fileChange
    }

    enum ApprovalDecision: String {
        case accept
        case acceptForSession
        case decline
        case cancel
    }

    struct PendingApproval: Identifiable, Equatable {
        let id: String
        let requestId: String
        let serverId: String
        let method: String
        let kind: ApprovalKind
        let threadId: String?
        let turnId: String?
        let itemId: String?
        let command: String?
        let cwd: String?
        let reason: String?
        let grantRoot: String?
        let requesterAgentNickname: String?
        let requesterAgentRole: String?
        let createdAt: Date
    }

    struct ComposerPrefillRequest: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    struct PendingUserInputOption: Equatable {
        let label: String
        let description: String
    }

    struct PendingUserInputQuestion: Equatable {
        let id: String
        let header: String
        let question: String
        let isOther: Bool
        let isSecret: Bool
        let options: [PendingUserInputOption]
    }

    struct PendingUserInputRequest: Identifiable, Equatable {
        let id: String
        let requestId: String
        let serverId: String
        let threadId: String
        let turnId: String
        let itemId: String
        let questions: [PendingUserInputQuestion]
        let requesterAgentNickname: String?
        let requesterAgentRole: String?
        let createdAt: Date
    }

    var sortedThreads: [ThreadState] {
        threads.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeThread: ThreadState? {
        activeThreadKey.flatMap { threads[$0] }
    }

    var activeConnection: ServerConnection? {
        activeThreadKey.flatMap { connections[$0.serverId] }
    }

    var activePendingApproval: PendingApproval? {
        pendingApprovals.first
    }

    func pendingUserInputRequest(for key: ThreadKey?) -> PendingUserInputRequest? {
        guard let key else { return nil }
        return pendingUserInputRequests.first {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }
    }

    var hasAnyConnection: Bool {
        connections.values.contains { $0.isConnected }
    }

    var hasInstalledNetworkMonitorCallbacks: Bool {
        networkMonitor.onNetworkLost != nil && networkMonitor.onNetworkRestored != nil
    }

    private func persistedLocalVoiceThreadId() -> String? {
        let stored = UserDefaults.standard.string(forKey: Self.persistedLocalVoiceThreadIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    private func setPersistedLocalVoiceThreadId(_ threadId: String?) {
        let trimmed = threadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.persistedLocalVoiceThreadIDKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.persistedLocalVoiceThreadIDKey)
        }
    }

    private func clearPersistedLocalVoiceThreadIfNeeded(_ key: ThreadKey) {
        guard key.serverId == Self.localServerID,
              persistedLocalVoiceThreadId() == key.threadId else {
            return
        }
        setPersistedLocalVoiceThreadId(nil)
    }

    private func makeLocalServer() -> DiscoveredServer {
        return DiscoveredServer(
            id: Self.localServerID,
            name: UIDevice.current.name,
            hostname: "127.0.0.1",
            port: nil,
            source: .local,
            hasCodexServer: true
        )
    }

    private func ensureLocalConnection() async throws -> ServerConnection {
        if let existing = connections[Self.localServerID] {
            if !existing.isConnected {
                await existing.connect()
                if existing.isConnected {
                    await refreshSessions(for: existing.id)
                }
            }
            guard existing.isConnected else {
                throw NSError(
                    domain: "Litter",
                    code: 3305,
                    userInfo: [NSLocalizedDescriptionKey: "Could not connect to the local Codex server"]
                )
            }
            return existing
        }

        let localServer = makeLocalServer()
        await addServer(localServer, target: .local)
        guard let connection = connections[Self.localServerID], connection.isConnected else {
            throw NSError(
                domain: "Litter",
                code: 3306,
                userInfo: [NSLocalizedDescriptionKey: "Could not start the local Codex server"]
            )
        }
        return connection
    }

    private func discardThreadState(_ key: ThreadKey) {
        cancelThreadMetadataRefresh(for: key)
        deferredThreadMessageHydrationTasks[key]?.cancel()
        deferredThreadMessageHydrationTasks.removeValue(forKey: key)
        deferredSubagentIdentityHydrationTasks[key]?.cancel()
        deferredSubagentIdentityHydrationTasks.removeValue(forKey: key)
        threads.removeValue(forKey: key)
        threadTurnCounts.removeValue(forKey: key)
        liveItemMessageIndices.removeValue(forKey: key)
        liveTurnDiffMessageIndices.removeValue(forKey: key)
    }

    private func preferredVoiceThreadCwd(for key: ThreadKey?, fallback: String) -> String {
        let existingCwd = key.flatMap {
            threads[$0]?.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        if !existingCwd.isEmpty {
            return existingCwd
        }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }

        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    }

    private func ensurePinnedLocalVoiceThread(
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        let connection = try await ensureLocalConnection()
        let serverId = connection.id

        if let storedThreadId = persistedLocalVoiceThreadId() {
            let key = ThreadKey(serverId: serverId, threadId: storedThreadId)
            if await resumeThread(
                serverId: serverId,
                threadId: storedThreadId,
                cwd: preferredVoiceThreadCwd(for: key, fallback: cwd),
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            ) {
                return key
            }

            setPersistedLocalVoiceThreadId(nil)
            discardThreadState(key)
        }

        let key = try await startThread(
            serverId: serverId,
            cwd: preferredVoiceThreadCwd(for: nil, fallback: cwd),
            model: model,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            dynamicTools: ExperimentalFeatures.shared.isEnabled(.generativeUI)
                ? GenerativeUITools.buildDynamicToolSpecs()
                : nil
        )
        setPersistedLocalVoiceThreadId(key.threadId)
        return key
    }

    private func debugAgentDirectoryLog(_ message: @autoclosure () -> String) {
        _ = message
    }

    private func logTargetResolution(targetId: String, resolvedLabel: String?, reason: String) {
        let label = resolvedLabel ?? "<nil>"
        debugAgentDirectoryLog("targetId=\(targetId) resolvedLabel=\(label) \(reason)")
    }

    private func agentDirectoryServerScope(_ serverId: String?) -> String? {
        sanitizedLineageId(serverId) ?? sanitizedLineageId(activeThreadKey?.serverId)
    }

    private func agentDirectoryScopedKey(serverId: String, id: String) -> String {
        "\(serverId):\(id)"
    }

    func resolvedAgentTargetLabel(for target: String, serverId: String? = nil) -> String? {
        if AgentLabelFormatter.looksLikeDisplayLabel(target),
           let label = AgentLabelFormatter.sanitized(target) {
            logTargetResolution(
                targetId: label,
                resolvedLabel: label,
                reason: "resolved-via=preformatted-target"
            )
            return label
        }
        guard let normalizedTarget = sanitizedLineageId(target) else {
            logTargetResolution(
                targetId: target,
                resolvedLabel: nil,
                reason: "unresolved reason=empty-target"
            )
            return nil
        }
        let serverScope = agentDirectoryServerScope(serverId)
        if let entry = mergedAgentDirectoryEntry(serverId: serverScope, threadId: normalizedTarget, agentId: normalizedTarget) {
            let label = AgentLabelFormatter.format(
                nickname: entry.nickname,
                role: entry.role,
                fallbackIdentifier: entry.threadId ?? entry.agentId ?? normalizedTarget
            )
            logTargetResolution(
                targetId: normalizedTarget,
                resolvedLabel: label,
                reason: "resolved-via=agent-directory"
            )
            return label
        }
        let threadMatch: ThreadState?
        if let serverScope {
            threadMatch = threads.values.first(where: { $0.serverId == serverScope && $0.threadId == normalizedTarget })
        } else {
            threadMatch = threads.values.first(where: { $0.threadId == normalizedTarget })
        }
        if let thread = threadMatch {
            let label = AgentLabelFormatter.format(
                nickname: thread.agentNickname,
                role: thread.agentRole,
                fallbackIdentifier: normalizedTarget
            )
            logTargetResolution(
                targetId: normalizedTarget,
                resolvedLabel: label,
                reason: "resolved-via=thread-state"
            )
            return label
        }
        logTargetResolution(
            targetId: normalizedTarget,
            resolvedLabel: nil,
            reason: "unresolved reason=no-agent-directory-or-thread-match serverScope=\(serverScope ?? "<nil>")"
        )
        return nil
    }

    /// Resolve a receiver/agent ID to an actual ThreadKey by checking
    /// the agent directory and threads dictionary. The receiver ID might be
    /// an agent ID rather than a thread ID, so we look it up in the directory
    /// to find the real thread ID.
    func resolvedThreadKey(for receiverId: String, serverId: String) -> ThreadKey? {
        let normalized = sanitizedLineageId(receiverId)
        guard let normalized else { return nil }

        // Direct match in threads dictionary
        let directKey = ThreadKey(serverId: serverId, threadId: normalized)
        if threads[directKey] != nil {
            return directKey
        }

        // Look up in agent directory — receiverId might be an agent ID
        if let entry = mergedAgentDirectoryEntry(serverId: serverId, threadId: normalized, agentId: normalized),
           let resolvedThreadId = entry.threadId {
            return ThreadKey(serverId: serverId, threadId: resolvedThreadId)
        }

        return directKey
    }

    // MARK: - Server Lifecycle

    @discardableResult
    func addServer(_ server: DiscoveredServer, target: ConnectionTarget) async -> String {
        startNetworkMonitorIfNeeded()

        if let existing = connections[server.id] {
            if existing.server == server && existing.target == target {
                configureConnectionCallbacks(existing, serverId: server.id)
                if !existing.isConnected {
                    await existing.connect()
                    if existing.isConnected {
                        await refreshSessions(for: server.id)
                    }
                }
                return server.id
            }

            existing.disconnect()
            connections.removeValue(forKey: server.id)
        }

        if let existing = connections.values.first(where: { $0.server.deduplicationKey == server.deduplicationKey }) {
            configureConnectionCallbacks(existing, serverId: existing.id)
            if !existing.isConnected {
                await existing.connect()
                if existing.isConnected {
                    await refreshSessions(for: existing.id)
                }
            }
            return existing.id
        }

        let conn = ServerConnection(server: server, target: target)
        configureConnectionCallbacks(conn, serverId: server.id)
        connections[server.id] = conn
        saveServerList()
        await conn.connect()
        if conn.isConnected {
            await refreshSessions(for: server.id)
        }
        registerServerWithHandoffManager(server: server, target: target, isConnected: conn.isConnected)
        return server.id
    }

    private func configureConnectionCallbacks(_ conn: ServerConnection, serverId: String) {
        conn.onTypedEvent = { [weak self] event in
            self?.enqueueTypedEvent(serverId: serverId, event: event)
        }
        conn.onServerRequest = { [weak self] requestId, method, data in
            self?.handleServerRequest(
                serverId: serverId,
                requestId: requestId,
                method: method,
                data: data
            ) ?? false
        }
        conn.onDisconnect = { [weak self] in
            NSLog("[%@ ws] disconnected server=%@", self?.ts ?? "?", serverId)
            self?.removePendingApprovals(forServerId: serverId)
            self?.removePendingUserInputRequests(forServerId: serverId)
            if self?.activeVoiceSession?.threadKey.serverId == serverId {
                let key = self?.activeVoiceSession?.threadKey ?? ThreadKey(serverId: serverId, threadId: "")
                self?.appendVoiceSessionSystemMessage(
                    "Realtime voice disconnected from server",
                    to: key
                )
                self?.failVoiceSession("Realtime voice disconnected")
            }
        }
        conn.onLoginCompleted = { [weak self, weak conn] in
            guard let self else { return }
            Task { @MainActor [weak conn] in
                await self.refreshSessions(for: serverId)
                if self.activeThreadKey?.serverId == serverId {
                    await self.syncActiveThreadFromServer()
                }
                conn?.loginCompleted = false
            }
        }
    }

    private func enqueueTypedEvent(serverId: String, event: UiEvent) {
        let previousTask = notificationWorkTask
        notificationWorkTask = Task { [weak self] in
            _ = await previousTask?.result
            guard let self, !Task.isCancelled else { return }
            self.handleTypedEvent(serverId: serverId, event: event)
        }
    }

    private func handleTypedEvent(serverId: String, event: UiEvent) {
        if suppressNotifications { return }
        switch event {
        case .turnStarted(let key, let turnId):
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            ensureThreadExistsByKey(serverId: serverId, threadId: key.threadId)
            threads[threadKey]?.status = .thinking
            threads[threadKey]?.activeTurnId = turnId
            if threads[threadKey]?.isSubagent == true { threads[threadKey]?.agentStatus = .running }
            removePendingRequests(serverId: serverId, threadId: key.threadId)

        case .turnCompleted(let key, _):
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            threads[threadKey]?.status = .ready
            threads[threadKey]?.updatedAt = Date()
            threads[threadKey]?.activeTurnId = nil
            if threads[threadKey]?.isSubagent == true { threads[threadKey]?.agentStatus = .completed }
            removePendingRequests(serverId: serverId, threadId: key.threadId)
            liveItemMessageIndices[threadKey] = nil
            liveTurnDiffMessageIndices[threadKey] = nil
            backgroundedTurnKeys.remove(threadKey)
            if var session = activeVoiceSession, session.threadKey == threadKey, session.phase == .handoff {
                session.phase = .listening
                activeVoiceSession = session
                syncVoiceCallActivity()
            }
            endLiveActivity(key: threadKey, phase: .completed)
            postLocalNotificationIfNeeded(model: threads[threadKey]?.model ?? "", threadPreview: threads[threadKey]?.preview)
            Task { await connections[serverId]?.fetchRateLimits() }

        case .messageDelta(let key, _, let delta):
            guard !delta.isEmpty else { return }
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            ensureThreadExistsByKey(serverId: serverId, threadId: key.threadId)
            guard let thread = threads[threadKey] else { return }
            if let last = thread.items.last, case .assistant(var data) = last.content {
                data.text += delta
                thread.items[thread.items.count - 1].content = .assistant(data)
                thread.items[thread.items.count - 1].timestamp = Date()
            } else {
                thread.items.append(makeAssistantItem(text: delta, agentNickname: thread.agentNickname, agentRole: thread.agentRole, sourceTurnId: thread.activeTurnId, sourceTurnIndex: nil))
            }
            thread.updatedAt = Date()
            updateLiveActivityOutput(key: threadKey, thread: thread)

        case .reasoningDelta(let key, _, let delta):
            guard !delta.isEmpty else { return }
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            guard let thread = threads[threadKey] else { return }
            if let last = thread.items.last, case .reasoning(var data) = last.content {
                if data.content.isEmpty { data.content.append(delta) } else { data.content[data.content.count - 1] += delta }
                thread.items[thread.items.count - 1].content = .reasoning(data)
            } else {
                thread.items.append(ConversationItem(id: UUID().uuidString, content: .reasoning(ConversationReasoningData(summary: [], content: [delta])), sourceTurnId: thread.activeTurnId, sourceTurnIndex: nil, timestamp: Date()))
            }
            thread.updatedAt = Date()

        case .planDelta(let key, let itemId, let delta):
            guard !delta.isEmpty else { return }
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            guard let thread = threads[threadKey] else { return }
            _ = appendProposedPlanDelta(delta, itemId: itemId, turnId: thread.activeTurnId, key: threadKey, thread: thread)

        case .commandOutputDelta(let key, let itemId, let delta):
            guard !delta.isEmpty else { return }
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            guard let thread = threads[threadKey] else { return }
            _ = appendCommandOutputDelta(delta, itemId: itemId, key: threadKey, thread: thread)

        case .itemStarted(_, let notification):
            handleTypedItemNotification(
                serverId: serverId,
                item: notification.item,
                threadId: notification.threadId,
                turnId: notification.turnId,
                isInProgressEvent: true
            )

        case .itemCompleted(_, let notification):
            handleTypedItemNotification(
                serverId: serverId,
                item: notification.item,
                threadId: notification.threadId,
                turnId: notification.turnId,
                isInProgressEvent: false
            )

        case .realtimeStarted(_, let notification):
            handleRealtimeStarted(serverId: serverId, notification: notification)

        case .realtimeItemAdded(_, let notification):
            handleRealtimeItemAdded(serverId: serverId, notification: notification)

        case .realtimeOutputAudioDelta(_, let notification):
            handleRealtimeOutputAudioDelta(serverId: serverId, notification: notification)

        case .realtimeError(_, let notification):
            handleRealtimeError(serverId: serverId, notification: notification)

        case .realtimeClosed(_, let notification):
            handleRealtimeClosed(serverId: serverId, notification: notification)

        case .accountLoginCompleted(let notification):
            connections[serverId]?.handleAccountLoginCompleted(notification)

        case .accountUpdated(let notification):
            connections[serverId]?.handleAccountUpdated(notification)

        case .accountRateLimitsUpdated(let notification):
            connections[serverId]?.handleAccountRateLimitsUpdated(notification)

        case .contextTokensUpdated(let key, let used, let limit):
            let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
            threads[threadKey]?.contextTokensUsed = Int64(used)
            threads[threadKey]?.modelContextWindow = Int64(limit)

        case .error(let key, let message, _):
            if let key {
                let threadKey = ThreadKey(serverId: serverId, threadId: key.threadId)
                if let thread = threads[threadKey] {
                    thread.items.append(ConversationItem(id: UUID().uuidString, content: .error(ConversationSystemErrorData(title: "Error", message: message, details: nil)), timestamp: Date()))
                    thread.status = .error(message)
                    thread.updatedAt = Date()
                    endLiveActivity(key: threadKey, phase: .failed)
                }
            }

        case .rawNotification(let rawServerId, let method, let paramsJson):
            let sid = rawServerId.isEmpty ? serverId : rawServerId
            let parsed: Any
            if let data = paramsJson.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                parsed = obj
            } else {
                parsed = [String: Any]()
            }
            handleRawNotification(serverId: sid, method: method, params: parsed)

        case .approvalRequested, .connectionStateChanged:
            break
        }
    }

    /// Handle raw notification events that arrive via the `.rawNotification` typed event path.
    /// `params` is the decoded params object (not the full JSON-RPC envelope).
    private func handleRawNotification(serverId: String, method: String, params: Any) {
        let paramsDict = params as? [String: Any] ?? [:]

        switch method {
        case "sessionConfigured":
            handleSessionConfiguredFromParams(serverId: serverId, params: paramsDict)

        case "thread/started":
            handleThreadStartedFromParams(serverId: serverId, params: paramsDict)

        case "thread/status/changed":
            if let threadId = extractString(paramsDict, keys: ["threadId", "thread_id"]),
               !threadId.isEmpty {
                ensureThreadExistsByKey(serverId: serverId, threadId: threadId)
            }

        case "codex/event/error":
            handleErrorNotificationFromParams(serverId: serverId, params: paramsDict)

        case "codex/event/task_complete":
            let threadId = extractString(paramsDict, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
                ?? (paramsDict["turn"] as? [String: Any]).flatMap { extractString($0, keys: ["threadId", "thread_id"]) }
            if let threadId {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .ready
                threads[key]?.updatedAt = Date()
                threads[key]?.activeTurnId = nil
                if threads[key]?.isSubagent == true {
                    threads[key]?.agentStatus = .completed
                }
                removePendingRequests(serverId: serverId, threadId: threadId)
                liveItemMessageIndices[key] = nil
                liveTurnDiffMessageIndices[key] = nil
                backgroundedTurnKeys.remove(key)
                endLiveActivity(key: key, phase: .completed)
                postLocalNotificationIfNeeded(model: threads[key]?.model ?? "", threadPreview: threads[key]?.preview)
            } else {
                for (_, thread) in threads where thread.serverId == serverId && thread.hasTurnActive {
                    thread.status = .ready
                    thread.updatedAt = Date()
                    thread.activeTurnId = nil
                    removePendingRequests(serverId: serverId, threadId: thread.threadId)
                    liveItemMessageIndices[thread.key] = nil
                    liveTurnDiffMessageIndices[thread.key] = nil
                    backgroundedTurnKeys.remove(thread.key)
                }
                endAllLiveActivities(phase: .completed)
                postLocalNotificationIfNeeded(model: "", threadPreview: nil)
            }
            Task { await connections[serverId]?.fetchRateLimits() }

        case "serverRequest/resolved":
            removePendingRequests(
                serverId: serverId,
                threadId: extractString(paramsDict, keys: ["threadId", "thread_id"]),
                requestId: extractString(paramsDict, keys: ["requestId", "request_id"])
            )

        case "turn/diff/updated":
            handleTurnDiffFromParams(serverId: serverId, params: paramsDict)

        case "turn/plan/updated":
            handleTurnPlanUpdatedFromParams(serverId: serverId, params: paramsDict)

        default:
            if method.hasPrefix("item/") {
                handleItemNotificationFromParams(serverId: serverId, method: method, params: paramsDict)
            } else if method == "codex/event/turn_diff" {
                handleLegacyCodexEventFromParams(serverId: serverId, method: method, params: paramsDict)
            } else if method == "codex/event" || method.hasPrefix("codex/event/") {
                ingestCodexEventAgentMetadataFromParams(serverId: serverId, method: method, params: paramsDict)
                if !serversUsingItemNotifications.contains(serverId) {
                    handleLegacyCodexEventFromParams(serverId: serverId, method: method, params: paramsDict)
                }
            }
        }
    }

    // MARK: - Raw Notification Handlers (params-based)

    private func handleSessionConfiguredFromParams(serverId: String, params: [String: Any]) {
        guard let sessionId = extractString(params, keys: ["sessionId", "session_id", "threadId", "thread_id"]),
              !sessionId.isEmpty else { return }

        guard let conn = connections[serverId] else { return }
        let key = ThreadKey(serverId: serverId, threadId: sessionId)
        let thread = threads[key] ?? ThreadState(
            serverId: serverId,
            threadId: sessionId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        let parentId = extractString(
            params,
            keys: ["forkedFromId", "forked_from_id", "parentThreadId", "parent_thread_id"]
        )
        let rootId = extractString(params, keys: ["rootThreadId", "root_thread_id"])
        let title = extractString(params, keys: ["threadName", "thread_name"])
        let cwd = extractString(params, keys: ["cwd"])
        let model = extractString(params, keys: ["model"])
        let modelProvider = extractString(params, keys: ["modelProvider", "model_provider", "modelProviderId", "model_provider_id"])
        let reasoningEffort = extractString(params, keys: ["reasoningEffort", "reasoning_effort"])
        let agentMetadata = extractAgentMetadata(params)

        thread.parentThreadId = sanitizedLineageId(parentId) ?? thread.parentThreadId
        thread.rootThreadId = sanitizedLineageId(rootId) ?? thread.rootThreadId
        thread.agentNickname = agentMetadata.nickname ?? thread.agentNickname
        thread.agentRole = agentMetadata.role ?? thread.agentRole
        upsertAgentDirectory(
            serverId: serverId,
            threadId: sessionId,
            agentId: agentMetadata.agentId,
            nickname: thread.agentNickname,
            role: thread.agentRole
        )
        if let title, !title.isEmpty {
            thread.preview = title
        }
        if let cwd, !cwd.isEmpty {
            thread.cwd = cwd
        }
        if let model, !model.isEmpty {
            thread.model = model
        }
        if let modelProvider, !modelProvider.isEmpty {
            thread.modelProvider = modelProvider
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            thread.reasoningEffort = reasoningEffort
        }

        threads[key] = thread
        let currentCwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentCwd.isEmpty {
            scheduleThreadMetadataRefresh(for: key, cwd: currentCwd)
        }
    }

    private func handleThreadStartedFromParams(serverId: String, params: [String: Any]) {
        let threadObj = (params["thread"] as? [String: Any]) ?? params
        guard let threadId = extractString(threadObj, keys: ["id", "threadId", "thread_id"]),
              !threadId.isEmpty else { return }

        let key = ThreadKey(serverId: serverId, threadId: threadId)
        guard threads[key] == nil else { return }
        guard let conn = connections[serverId] else { return }

        let state = ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )

        if let preview = extractString(threadObj, keys: ["preview"]), !preview.isEmpty {
            state.preview = preview
        }
        if let modelProvider = extractString(threadObj, keys: ["modelProvider", "model_provider"]), !modelProvider.isEmpty {
            state.modelProvider = modelProvider
        }
        if let model = extractString(threadObj, keys: ["model"]), !model.isEmpty {
            state.model = model
        }
        if let cwd = extractString(threadObj, keys: ["cwd"]), !cwd.isEmpty {
            state.cwd = cwd
        }
        if let createdAt = (threadObj["createdAt"] as? TimeInterval) ?? (threadObj["created_at"] as? TimeInterval) {
            state.updatedAt = Date(timeIntervalSince1970: createdAt)
        }

        let source = (threadObj["source"] as? [String: Any])
            ?? (threadObj["sessionSource"] as? [String: Any])
        if let source {
            let threadSpawn = (source["thread_spawn"] as? [String: Any])
                ?? (source["threadSpawn"] as? [String: Any])
            if let threadSpawn {
                state.parentThreadId = sanitizedLineageId(
                    extractString(threadSpawn, keys: ["parent_thread_id", "parentThreadId"])
                )
                state.agentNickname = extractString(threadSpawn, keys: ["agent_nickname", "agentNickname"])
                state.agentRole = extractString(threadSpawn, keys: ["agent_role", "agentRole"])

                upsertAgentDirectory(
                    serverId: serverId,
                    threadId: threadId,
                    agentId: nil,
                    nickname: state.agentNickname,
                    role: state.agentRole
                )
            }
        }

        let agentMetadata = extractAgentMetadata(threadObj)
        if state.agentNickname == nil { state.agentNickname = agentMetadata.nickname }
        if state.agentRole == nil { state.agentRole = agentMetadata.role }
        if state.parentThreadId == nil {
            state.parentThreadId = sanitizedLineageId(
                extractString(threadObj, keys: ["parentThreadId", "parent_thread_id"])
            )
        }

        state.requiresOpenHydration = true
        threads[key] = state
        threadTurnCounts[key] = 0
    }

    private func handleRealtimeStarted(serverId: String, notification: ThreadRealtimeStartedNotification) {
        let key = ThreadKey(serverId: serverId, threadId: notification.threadId)
        guard var session = activeVoiceSession, session.threadKey == key else { return }

        appendVoiceSessionDebug(
            "<- thread/realtime/started threadId=\(notification.threadId) sessionId=\(notification.sessionId ?? "nil")",
            to: &session
        )
        session.sessionId = notification.sessionId
        session.phase = .listening
        session.isListening = true
        activeVoiceSession = session
        syncVoiceCallActivity()

        do {
            try voiceSessionCoordinator.start { [weak self] chunk in
                guard let self else { return }
                await self.appendRealtimeAudioChunk(chunk, for: key)
            }
        } catch {
            appendVoiceSessionSystemMessage(
                "Failed to start microphone capture: \(error.localizedDescription)",
                to: key
            )
            failVoiceSession(error.localizedDescription)
        }
    }

    private func appendFinalRealtimeMessage(
        role: String,
        text: String,
        itemId: String,
        to session: inout VoiceSessionState
    ) {
        guard !text.isEmpty else { return }
        let speaker = role == "user" ? "You" : "Codex"
        let messageId = "rtv-\(itemId)"
        let item = VoiceSessionTranscriptEntry(
            id: messageId,
            speaker: speaker,
            text: text,
            timestamp: Date()
        )

        if let existingIndex = session.transcriptHistory.firstIndex(where: { $0.id == messageId }) {
            session.transcriptHistory[existingIndex] = item
        } else {
            session.transcriptHistory.append(item)
        }
    }

    private func reserveRealtimeTranscriptMessage(
        role: String,
        itemId: String,
        to session: inout VoiceSessionState
    ) {
        let speaker = role == "user" ? "You" : "Codex"
        let messageId = "rtv-\(itemId)"
        guard !session.transcriptHistory.contains(where: { $0.id == messageId }) else { return }

        session.transcriptHistory.append(
            VoiceSessionTranscriptEntry(
                id: messageId,
                speaker: speaker,
                text: "",
                timestamp: Date()
            )
        )
    }

    private func isProvisionalRealtimeMessageID(_ itemId: String?) -> Bool {
        guard let itemId, !itemId.isEmpty else { return false }
        return !itemId.hasPrefix("item_")
    }

    private func rekeyRealtimeTranscriptMessage(
        from oldItemId: String?,
        to newItemId: String,
        speaker: String,
        session: inout VoiceSessionState
    ) {
        guard let oldItemId, oldItemId != newItemId else { return }

        let oldMessageId = "rtv-\(oldItemId)"
        let newMessageId = "rtv-\(newItemId)"
        guard oldMessageId != newMessageId else { return }

        if let oldIndex = session.transcriptHistory.firstIndex(where: { $0.id == oldMessageId }) {
            let oldEntry = session.transcriptHistory[oldIndex]
            let mergedEntry = VoiceSessionTranscriptEntry(
                id: newMessageId,
                speaker: speaker,
                text: oldEntry.text,
                timestamp: oldEntry.timestamp
            )

            if let existingNewIndex = session.transcriptHistory.firstIndex(where: { $0.id == newMessageId }) {
                let existingNew = session.transcriptHistory[existingNewIndex]
                let preferredText = existingNew.text.count >= mergedEntry.text.count ? existingNew.text : mergedEntry.text
                let preferredTimestamp = oldIndex <= existingNewIndex ? oldEntry.timestamp : existingNew.timestamp
                let replacement = VoiceSessionTranscriptEntry(
                    id: newMessageId,
                    speaker: speaker,
                    text: preferredText,
                    timestamp: preferredTimestamp
                )

                if oldIndex < existingNewIndex {
                    session.transcriptHistory[oldIndex] = replacement
                    session.transcriptHistory.remove(at: existingNewIndex)
                } else {
                    session.transcriptHistory[existingNewIndex] = replacement
                    session.transcriptHistory.remove(at: oldIndex)
                }
            } else {
                session.transcriptHistory[oldIndex] = mergedEntry
            }
        }

        if session.transcriptLiveMessageID == oldMessageId {
            session.transcriptLiveMessageID = newMessageId
        }
    }

    private func flushRealtimeTranscriptIfNeeded(
        for key: ThreadKey,
        session: inout VoiceSessionState,
        speaker: String? = nil
    ) {
        let resolvedSpeaker = speaker ?? session.transcriptSpeaker
        guard let resolvedSpeaker,
              let text = session.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        let role: String
        switch resolvedSpeaker {
        case "You":
            role = "user"
        case "Codex":
            role = "assistant"
        default:
            return
        }

        let pending = pendingRealtimeMessageIDs[key] ?? (nil, nil)
        let itemId = (role == "user" ? pending.user : pending.assistant) ?? UUID().uuidString
        appendFinalRealtimeMessage(role: role, text: text, itemId: itemId, to: &session)

        if session.transcriptSpeaker == resolvedSpeaker {
            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
        }
    }

    private func shouldSkipRealtimeTranscriptDelta(
        _ delta: String,
        speaker: String,
        for key: ThreadKey
    ) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let previous = lastRealtimeTranscriptDelta[key],
           previous.speaker == speaker,
           previous.delta == delta,
           now - previous.timestamp < 0.5 {
            return true
        }
        lastRealtimeTranscriptDelta[key] = (speaker: speaker, delta: delta, timestamp: now)
        return false
    }

    private func applyRealtimeTranscriptDelta(
        _ delta: String,
        speaker: String,
        phase: VoiceSessionPhase,
        key: ThreadKey,
        session: inout VoiceSessionState
    ) {
        guard !delta.isEmpty else { return }
        guard !shouldSkipRealtimeTranscriptDelta(delta, speaker: speaker, for: key) else { return }

        let pending = pendingRealtimeMessageIDs[key] ?? (nil, nil)
        let pendingItemID: String
        if speaker == "You" {
            pendingItemID = pending.user ?? UUID().uuidString
            if pending.user == nil {
                pendingRealtimeMessageIDs[key] = (pendingItemID, pending.assistant)
            }
        } else {
            let existingAssistantId = pending.assistant
            let shouldRotateAssistantRow: Bool = {
                guard let existingAssistantId else { return true }
                if isProvisionalRealtimeMessageID(existingAssistantId) {
                    return false
                }
                let existingMessageId = "rtv-\(existingAssistantId)"
                let hasPersistedText = session.transcriptHistory.contains(where: {
                    $0.id == existingMessageId && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                let isCurrentLive = session.transcriptLiveMessageID == existingMessageId
                return hasPersistedText && !isCurrentLive
            }()

            if shouldRotateAssistantRow {
                pendingItemID = UUID().uuidString
                pendingRealtimeMessageIDs[key] = (pending.user, pendingItemID)
            } else {
                pendingItemID = existingAssistantId ?? UUID().uuidString
                if existingAssistantId == nil {
                    pendingRealtimeMessageIDs[key] = (pending.user, pendingItemID)
                }
            }
        }

        let messageId = "rtv-\(pendingItemID)"
        let existingHistoryText = session.transcriptHistory.first(where: { $0.id == messageId })?.text
        let liveTextForSpeaker: String? = (
            session.transcriptSpeaker == speaker && session.transcriptLiveMessageID == messageId
        ) ? session.transcriptText : nil
        let existing = liveTextForSpeaker ?? existingHistoryText ?? ""

        let mergedText: String
        if existing == delta || existing.hasSuffix(delta) {
            mergedText = existing
        } else if delta.hasPrefix(existing) {
            mergedText = delta
        } else if existing.hasPrefix(delta) {
            mergedText = existing
        } else {
            mergedText = existing + delta
        }

        appendFinalRealtimeMessage(
            role: speaker == "You" ? "user" : "assistant",
            text: mergedText,
            itemId: pendingItemID,
            to: &session
        )

        let shouldPromoteToLive: Bool
        if session.transcriptSpeaker == nil || session.transcriptSpeaker == speaker {
            shouldPromoteToLive = true
        } else {
            shouldPromoteToLive = existingHistoryText == nil
        }

        if shouldPromoteToLive {
            session.transcriptText = mergedText
            session.transcriptSpeaker = speaker
            session.transcriptLiveMessageID = messageId
            session.phase = phase
        }

        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func handleRealtimeItemAdded(serverId: String, notification: ThreadRealtimeItemAddedNotification) {
        let key = ThreadKey(serverId: serverId, threadId: notification.threadId)
        guard var session = activeVoiceSession,
              session.threadKey == key,
              let item = notification.item.objectValue else {
            return
        }

        let itemType = extractString(item, keys: ["type"]) ?? ""

        switch itemType {
        case "handoff_request":
            flushRealtimeTranscriptIfNeeded(for: key, session: &session)

            let handoffId = extractString(item, keys: ["handoff_id", "handoffId", "id"]) ?? UUID().uuidString
            let inputTranscript = extractString(item, keys: ["input_transcript", "inputTranscript"]) ?? ""
            let transcriptEntries = (item["active_transcript"] as? [[String: Any]]) ?? []
            let activeTranscript = transcriptEntries
                .compactMap { entry -> String? in
                    guard let role = entry["role"] as? String,
                          let text = entry["text"] as? String else {
                        return nil
                    }
                    return "\(role): \(text)"
                }
                .joined(separator: "\n")
            let resolvedActiveTranscript = activeTranscript.isEmpty
                ? (extractString(item, keys: ["active_transcript", "activeTranscript"]) ?? "")
                : activeTranscript
            let serverHint = extractString(item, keys: ["server_hint", "serverHint", "server"])
            let fallbackTranscript = extractString(item, keys: ["fallback_transcript", "fallbackTranscript"])

            appendVoiceSessionDebug(
                "<- thread/realtime/itemAdded type=handoff_request id=\(handoffId) server=\(serverHint ?? "nil")",
                to: &session
            )
            session.phase = .handoff
            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
            activeVoiceSession = session
            syncVoiceCallActivity()

            syncHandoffTurnConfig()
            handoffManager.handleHandoffRequest(
                handoffId: handoffId,
                voiceServerId: serverId,
                voiceThreadId: notification.threadId,
                inputTranscript: inputTranscript,
                activeTranscript: resolvedActiveTranscript,
                serverHint: serverHint,
                fallbackTranscript: fallbackTranscript
            )
            processHandoffActions()

        case "message":
            let role = extractString(item, keys: ["role"]) ?? "assistant"
            let itemId = extractString(item, keys: ["id"]) ?? UUID().uuidString
            let content = item["content"] as? [[String: Any]] ?? []

            if role == "user" {
                flushRealtimeTranscriptIfNeeded(for: key, session: &session, speaker: "Codex")
                voiceSessionCoordinator.flushPlayback()
                let pending = pendingRealtimeMessageIDs[key] ?? (nil, nil)
                if let pendingUserId = pending.user,
                   isProvisionalRealtimeMessageID(pendingUserId),
                   (session.transcriptHistory.contains(where: { $0.id == "rtv-\(pendingUserId)" }) ||
                    session.transcriptLiveMessageID == "rtv-\(pendingUserId)") {
                    rekeyRealtimeTranscriptMessage(
                        from: pendingUserId,
                        to: itemId,
                        speaker: "You",
                        session: &session
                    )
                }
                pendingRealtimeMessageIDs[key] = (itemId, pending.assistant)
                reserveRealtimeTranscriptMessage(role: role, itemId: itemId, to: &session)
            } else {
                flushRealtimeTranscriptIfNeeded(for: key, session: &session, speaker: "You")
                let pending = pendingRealtimeMessageIDs[key] ?? (nil, nil)
                if let pendingAssistantId = pending.assistant,
                   isProvisionalRealtimeMessageID(pendingAssistantId),
                   (session.transcriptHistory.contains(where: { $0.id == "rtv-\(pendingAssistantId)" }) ||
                    session.transcriptLiveMessageID == "rtv-\(pendingAssistantId)") {
                    rekeyRealtimeTranscriptMessage(
                        from: pendingAssistantId,
                        to: itemId,
                        speaker: "Codex",
                        session: &session
                    )
                }
                pendingRealtimeMessageIDs[key] = (pending.user, itemId)
                reserveRealtimeTranscriptMessage(role: role, itemId: itemId, to: &session)
            }

            let text = content.compactMap { part -> String? in
                guard (extractString(part, keys: ["type"]) ?? "") == "text" else { return nil }
                return extractString(part, keys: ["text"])
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                if role == "user", session.transcriptSpeaker == "You" {
                    session.transcriptLiveMessageID = "rtv-\(itemId)"
                } else if role == "assistant", session.transcriptSpeaker == "Codex" {
                    session.transcriptLiveMessageID = "rtv-\(itemId)"
                }
                activeVoiceSession = session
                return
            }

            appendVoiceSessionDebug("<- thread/realtime/itemAdded role=\(role) text=\(text)", to: &session)
            appendFinalRealtimeMessage(role: role, text: text, itemId: itemId, to: &session)

            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
            if role == "assistant", !session.isSpeaking {
                session.phase = .thinking
            }
            activeVoiceSession = session
            syncVoiceCallActivity()

        case "input_transcript_delta", "output_transcript_delta":
            let delta = extractString(item, keys: ["delta"]) ?? ""
            guard !delta.isEmpty else { return }
            let speaker = itemType == "input_transcript_delta" ? "You" : "Codex"
            let phase: VoiceSessionPhase = itemType == "input_transcript_delta" ? .listening : .speaking
            applyRealtimeTranscriptDelta(
                delta,
                speaker: speaker,
                phase: phase,
                key: key,
                session: &session
            )

        case "speech_started":
            voiceSessionCoordinator.flushPlayback()
            let pending = pendingRealtimeMessageIDs[key] ?? (nil, nil)
            pendingRealtimeMessageIDs[key] = (nil, pending.assistant)
            if session.transcriptSpeaker == "Codex" {
                flushRealtimeTranscriptIfNeeded(for: key, session: &session, speaker: "Codex")
            } else if session.transcriptSpeaker != "You" {
                session.transcriptText = nil
                session.transcriptSpeaker = nil
                session.transcriptLiveMessageID = nil
            }
            activeVoiceSession = session

        default:
            appendVoiceSessionDebug(
                "<- thread/realtime/itemAdded unknown type=\(itemType)",
                to: &session
            )
            activeVoiceSession = session
        }
    }

    // MARK: - Cross-Server Handoff (Rust-backed)

    private func registerServerWithHandoffManager(server: DiscoveredServer, target: ConnectionTarget, isConnected: Bool) {
        handoffManager.registerServer(
            serverId: server.id,
            name: server.name,
            hostname: server.hostname,
            isLocal: target == .local,
            isConnected: isConnected
        )
    }

    private func syncHandoffTurnConfig() {
        handoffManager.setTurnConfig(model: handoffModel, effort: handoffEffort, fastMode: handoffFastMode)
    }

    private func processHandoffActions() {
        let actions = handoffManager.drainActions()
        for action in actions { dispatchSingleHandoffAction(action) }
    }

    private func executeHandoffStartThread(handoffId: String, serverId: String, cwd: String) async {
        do {
            let key = try await startThread(serverId: serverId, cwd: cwd)
            handoffManager.reportThreadCreated(handoffId: handoffId, serverId: serverId, threadId: key.threadId)
            handoffThreadKeys[handoffId] = key
            voiceHandoffThreads[handoffId] = key
            if var session = activeVoiceSession {
                session.handoffRemoteThreadKey = key
                activeVoiceSession = session
            }
            processHandoffActions()
        } catch {
            handoffManager.reportThreadFailed(handoffId: handoffId, error: error.localizedDescription)
            processHandoffActions()
        }
    }

    private func executeHandoffSendTurn(handoffId: String, serverId: String, threadId: String, transcript: String, model: String?, effort: String?, fastMode: Bool) async {
        guard let conn = connections[serverId] else {
            handoffManager.reportTurnFailed(handoffId: handoffId, error: "No connection for server \(serverId)")
            processHandoffActions()
            return
        }
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        ensureThreadExistsByKey(serverId: serverId, threadId: threadId)
        let baseItemCount = threads[key]?.items.count ?? 0
        do {
            let _ = try await conn.sendTurn(threadId: threadId, text: transcript, model: model, effort: effort)
            handoffManager.reportTurnSent(handoffId: handoffId, baseItemCount: baseItemCount)
            startHandoffStreamPolling(handoffId: handoffId, serverId: serverId, threadId: threadId)
            processHandoffActions()
        } catch {
            handoffManager.reportTurnFailed(handoffId: handoffId, error: error.localizedDescription)
            processHandoffActions()
        }
    }

    private func executeHandoffResolve(handoffId: String, voiceServerId: String, voiceThreadId: String, text: String) async {
        guard let conn = connections[voiceServerId] else { return }
        let voiceKey = ThreadKey(serverId: voiceServerId, threadId: voiceThreadId)
        recordVoiceSessionDebug("-> resolveHandoff id=\(handoffId) text=\(text.prefix(80))", for: voiceKey)
        do {
            try await conn.resolveRealtimeHandoff(threadId: voiceThreadId, handoffId: handoffId, outputText: text)
            recordVoiceSessionDebug("<- resolveHandoff id=\(handoffId) ok", for: voiceKey)
        } catch {
            recordVoiceSessionDebug("<- resolveHandoff id=\(handoffId) error=\(error.localizedDescription)", for: voiceKey)
        }
    }

    private func executeHandoffFinalize(handoffId: String, voiceServerId: String, voiceThreadId: String) async {
        guard let conn = connections[voiceServerId] else { return }
        let voiceKey = ThreadKey(serverId: voiceServerId, threadId: voiceThreadId)
        recordVoiceSessionDebug("-> finalizeHandoff id=\(handoffId)", for: voiceKey)
        do {
            try await conn.finalizeRealtimeHandoff(threadId: voiceThreadId, handoffId: handoffId)
            handoffManager.reportFinalized(handoffId: handoffId)
            processHandoffActions()
        } catch {
            recordVoiceSessionDebug("<- finalizeHandoff id=\(handoffId) error=\(error.localizedDescription)", for: voiceKey)
        }
        if var session = activeVoiceSession {
            session.phase = .listening
            session.handoffRemoteThreadKey = nil
            activeVoiceSession = session
            syncVoiceCallActivity()
        }
        handoffThreadKeys.removeValue(forKey: handoffId)
        voiceHandoffThreads.removeValue(forKey: handoffId)
    }

    private func startHandoffStreamPolling(handoffId: String, serverId: String, threadId: String) {
        handoffActionPollTask?.cancel()
        handoffActionPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let key = ThreadKey(serverId: serverId, threadId: threadId)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let thread = self.threads[key] else { break }
                let turnActive = thread.status == .thinking
                let items: [(id: String, text: String)] = thread.items.suffix(20).compactMap { item in
                    switch item.content {
                    case .assistant(let data): return (id: item.id, text: data.text)
                    case .commandExecution(let data): return (id: item.id, text: "[cmd] \(data.command.prefix(80)) \(data.status)")
                    case .mcpToolCall(let data): return (id: item.id, text: "[\(data.tool)] \(data.status)")
                    default: return nil
                    }
                }
                self.handoffManager.pollStreamProgress(handoffId: handoffId, items: items, turnActive: turnActive)
                for action in self.handoffManager.drainActions() { self.dispatchSingleHandoffAction(action) }
                if !turnActive { break }
            }
        }
    }

    private func dispatchSingleHandoffAction(_ action: HandoffAction) {
        switch action {
        case .startThread(let hid, let sid, _, let cwd):
            Task { @MainActor in await self.executeHandoffStartThread(handoffId: hid, serverId: sid, cwd: cwd) }
        case .sendTurn(let hid, let sid, let tid, let transcript, let config):
            Task { @MainActor in await self.executeHandoffSendTurn(handoffId: hid, serverId: sid, threadId: tid, transcript: transcript, model: config.model, effort: config.effort, fastMode: config.fastMode) }
        case .resolveHandoff(let hid, let vtk, let text):
            Task { @MainActor in await self.executeHandoffResolve(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId, text: text) }
        case .finalizeHandoff(let hid, let vtk):
            Task { @MainActor in await self.executeHandoffFinalize(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId) }
        case .updateHandoffItem(let hid, let vtk, let rtk):
            updateHandoffConversationItem(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId, remoteServerId: rtk.serverId, remoteThreadId: rtk.threadId)
        case .completeHandoffItem(let hid, let vtk):
            completeHandoffConversationItem(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId)
        case .setVoicePhase(let phase):
            if var session = activeVoiceSession {
                switch phase {
                case "listening": session.phase = .listening
                case "thinking": session.phase = .thinking
                case "handoff": session.phase = .handoff
                default: break
                }
                activeVoiceSession = session
                syncVoiceCallActivity()
            }
        case .error(let hid, let msg):
            NSLog("[handoff] error id=%@ message=%@", hid, msg)
            if let vk = activeVoiceSession?.threadKey { recordVoiceSessionDebug("handoff error id=\(hid): \(msg)", for: vk) }
        }
    }

    private func updateHandoffConversationItem(handoffId: String, voiceServerId: String, voiceThreadId: String, remoteServerId: String, remoteThreadId: String) {
        let voiceKey = ThreadKey(serverId: voiceServerId, threadId: voiceThreadId)
        guard let thread = threads[voiceKey] else { return }
        let name = connections[remoteServerId]?.server.name ?? remoteServerId
        let item = ConversationItem(id: "handoff-\(handoffId)", content: .note(ConversationNoteData(title: "Handoff", body: "Executing on \(name)...")), timestamp: Date())
        if let idx = thread.items.firstIndex(where: { $0.id == "handoff-\(handoffId)" }) {
            thread.items[idx] = item
        } else {
            thread.items.append(item)
        }
        thread.updatedAt = Date()
    }

    private func completeHandoffConversationItem(handoffId: String, voiceServerId: String, voiceThreadId: String) {
        let voiceKey = ThreadKey(serverId: voiceServerId, threadId: voiceThreadId)
        guard let thread = threads[voiceKey] else { return }
        let itemId = "handoff-\(handoffId)"
        if let idx = thread.items.firstIndex(where: { $0.id == itemId }),
           case .note(var data) = thread.items[idx].content {
            data.body = data.body.replacingOccurrences(of: "...", with: " (completed)")
            thread.items[idx].content = .note(data)
            thread.items[idx].timestamp = Date()
        }
        thread.updatedAt = Date()
    }

    private func handleRealtimeOutputAudioDelta(serverId: String, notification: ThreadRealtimeOutputAudioDeltaNotification) {
        let key = ThreadKey(serverId: serverId, threadId: notification.threadId)
        guard activeVoiceSession?.threadKey == key else { return }
        if let session = activeVoiceSession,
           session.debugEntries.filter({ $0.line.contains("thread/realtime/outputAudio/delta") }).count < 3 {
            recordVoiceSessionDebug(
                "<- thread/realtime/outputAudio/delta bytes=\(notification.audio.data.count) rate=\(notification.audio.sampleRate)",
                for: key
            )
        }
        voiceSessionCoordinator.enqueueOutputAudio(notification.audio)
    }

    private func handleRealtimeError(serverId: String, notification: ThreadRealtimeErrorNotification) {
        let key = ThreadKey(serverId: serverId, threadId: notification.threadId)
        guard activeVoiceSession?.threadKey == key else { return }
        recordVoiceSessionDebug(
            "<- thread/realtime/error threadId=\(notification.threadId) message=\(notification.message)",
            for: key
        )
        if notification.message.contains("active response in progress") {
            return
        }
        appendVoiceSessionSystemMessage("Realtime voice error: \(notification.message)", to: key)
        failVoiceSession(notification.message)
    }

    private func handleRealtimeClosed(serverId: String, notification: ThreadRealtimeClosedNotification) {
        let key = ThreadKey(serverId: serverId, threadId: notification.threadId)
        guard activeVoiceSession?.threadKey == key else { return }

        if var session = activeVoiceSession, session.threadKey == key {
            flushRealtimeTranscriptIfNeeded(for: key, session: &session)
            activeVoiceSession = session
        }

        recordVoiceSessionDebug(
            "<- thread/realtime/closed threadId=\(notification.threadId) reason=\(notification.reason ?? "nil")",
            for: key
        )
        let reason = notification.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if voiceStopRequestedThreadKey == key || reason == "requested" {
            voiceStopRequestedThreadKey = nil
            endVoiceSessionImmediately()
            return
        }
        if !reason.isEmpty, reason != "requested" {
            appendVoiceSessionSystemMessage("Realtime voice closed: \(reason)", to: key)
        }
        failVoiceSession(reason.isEmpty ? "Voice session closed" : reason)
    }

    private func handleAgentMessageDeltaFromParams(serverId: String, params: [String: Any]) {
        let delta = (params["delta"] as? String) ?? ""
        guard !delta.isEmpty else { return }

        let source = params["source"]
        func extractSourceField(_ source: Any?, keys: [String]) -> String? {
            guard let sourceDict = source as? [String: Any] else { return nil }
            let subAgent = (sourceDict["subAgent"] as? [String: Any]) ?? (sourceDict["sub_agent"] as? [String: Any])
            guard let subAgent else { return nil }
            let threadSpawn = (subAgent["thread_spawn"] as? [String: Any]) ?? (subAgent["threadSpawn"] as? [String: Any])

            func extract(from dict: [String: Any]?) -> String? {
                guard let dict else { return nil }
                for key in keys {
                    if let value = dict[key] as? String {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    } else if let value = dict[key] as? NSNumber {
                        return value.stringValue
                    }
                }
                return nil
            }
            return extract(from: threadSpawn) ?? extract(from: subAgent)
        }

        let explicitThreadId = sanitizedLineageId(
            extractString(params, keys: ["threadId", "thread_id"])
            ?? extractSourceField(source, keys: ["thread_id", "threadId"])
        )
        let agentId = sanitizedLineageId(
            extractString(params, keys: ["agentId", "agent_id", "id"])
            ?? extractSourceField(source, keys: ["agent_id", "agentId", "id"])
        )
        let agentNicknameRaw = sanitizedLineageId(
            extractString(params, keys: ["agentNickname", "agent_nickname", "nickname", "name"])
            ?? extractSourceField(source, keys: ["agent_nickname", "agentNickname", "nickname", "name"])
        )
        let agentRoleRaw = sanitizedLineageId(
            extractString(params, keys: ["agentRole", "agent_role", "agentType", "agent_type", "role", "type"])
            ?? extractSourceField(source, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"])
        )

        let key = resolveThreadKey(serverId: serverId, threadId: explicitThreadId)
        guard let thread = threads[key] else { return }
        let agentNickname = agentNicknameRaw ?? thread.agentNickname
        let agentRole = agentRoleRaw ?? thread.agentRole
        debugAgentDirectoryLog(
            "delta parsed threadId=\(explicitThreadId ?? "<nil>") agentId=\(agentId ?? "<nil>") nickname=\(agentNickname ?? "<nil>") role=\(agentRole ?? "<nil>")"
        )
        if let last = thread.items.last,
           case .assistant(var data) = last.content {
            data.text += delta
            if data.agentNickname == nil {
                data.agentNickname = agentNickname
            }
            if data.agentRole == nil {
                data.agentRole = agentRole
            }
            thread.items[thread.items.count - 1].content = .assistant(data)
            thread.items[thread.items.count - 1].timestamp = Date()
        } else {
            thread.items.append(
                makeAssistantItem(
                    text: delta,
                    agentNickname: agentNickname,
                    agentRole: agentRole,
                    sourceTurnId: thread.activeTurnId,
                    sourceTurnIndex: nil
                )
            )
        }
        if explicitThreadId != nil || agentId == nil {
            thread.agentNickname = agentNickname
            thread.agentRole = agentRole
        }
        upsertAgentDirectory(
            serverId: serverId,
            threadId: explicitThreadId ?? (agentId == nil ? key.threadId : nil),
            agentId: agentId,
            nickname: agentNickname,
            role: agentRole
        )
        thread.updatedAt = Date()
        updateLiveActivityOutput(key: key, thread: thread)
    }

    private func handleErrorNotificationFromParams(serverId: String, params: [String: Any]) {
        let errorDict = params["error"] as? [String: Any]
        let message = (errorDict?["message"] as? String)
            ?? (params["message"] as? String)
            ?? "Unknown error"

        let threadId = extractString(params, keys: ["threadId", "thread_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        thread.items.append(
            ConversationItem(
                id: UUID().uuidString,
                content: .error(ConversationSystemErrorData(title: "Error", message: message, details: nil)),
                timestamp: Date()
            )
        )
        thread.status = .error(message)
        thread.updatedAt = Date()
        endLiveActivity(key: key, phase: .failed)
    }

    private func handleTurnDiffFromParams(serverId: String, params: [String: Any]) {
        let threadId = extractString(params, keys: ["threadId", "thread_id"])
        let turnId = extractString(params, keys: ["turnId", "turn_id"])
        guard let diff = extractString(params, keys: ["diff"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !diff.isEmpty else { return }

        let key = resolveThreadKey(serverId: serverId, threadId: threadId)

        let diffHeaders = diff.components(separatedBy: "diff --git ").count - 1
        let fileChangeCount = max(diffHeaders, 1)
        liveActivityFileChangeCounts[key] = fileChangeCount

        guard let thread = threads[key] else { return }
        let msg = ConversationItem(
            id: turnId ?? UUID().uuidString,
            content: .turnDiff(ConversationTurnDiffData(diff: diff)),
            sourceTurnId: turnId,
            sourceTurnIndex: nil,
            timestamp: Date()
        )

        if let turnId, !turnId.isEmpty {
            upsertLiveTurnDiffMessage(msg, turnId: turnId, key: key, thread: thread)
        } else {
            thread.items.append(msg)
        }
        thread.updatedAt = Date()
    }

    private func handleTurnPlanUpdatedFromParams(serverId: String, params: [String: Any]) {
        guard let turnId = extractString(params, keys: ["turnId", "turn_id"]),
              !turnId.isEmpty else {
            return
        }

        let threadId = extractString(params, keys: ["threadId", "thread_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        upsertTurnTodoList(turnId: turnId, steps: planSteps(from: params["plan"]), thread: thread)
        thread.updatedAt = Date()
    }

    private func handleTypedItemNotification(
        serverId: String,
        item: ThreadItem,
        threadId: String,
        turnId: String,
        isInProgressEvent: Bool
    ) {
        serversUsingItemNotifications.insert(serverId)
        ensureThreadExistsByKey(serverId: serverId, threadId: threadId)
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        if item.isUserOrAgentMessage {
            return
        }

        if case .dynamicToolCall(let itemId, let toolName, let arguments, _, _, _, _) = item {
            if toolName == GenerativeUITools.showWidgetToolName {
                if !isInProgressEvent {
                    if let index = liveItemMessageIndices[key]?[itemId],
                       thread.items.indices.contains(index),
                       case .widget(var data) = thread.items[index].content {
                        data.widgetState.isFinalized = true
                        data.status = "completed"
                        thread.items[index].content = .widget(data)
                    }
                    liveItemMessageIndices[key]?[itemId] = nil
                    thread.updatedAt = Date()
                    return
                }

                let args = arguments.objectValue ?? [:]
                let widget = WidgetState.fromArguments(args, callId: itemId)
                let msg = ConversationItem(
                    id: itemId,
                    content: .widget(ConversationWidgetData(widgetState: widget, status: "inProgress")),
                    timestamp: Date()
                )
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
                thread.updatedAt = Date()
                return
            }

            if toolName == GenerativeUITools.readMeToolName {
                return
            }
        }

        if isInProgressEvent, let toolName = item.liveActivityLabel {
            updateLiveActivity(key: key, phase: .toolCall, toolName: toolName)
        }

        guard let msg = RustConversationBridge.hydrateItem(
            item: item,
            turnId: turnId,
            defaultAgentNickname: thread.agentNickname,
            defaultAgentRole: thread.agentRole,
            isInProgressEvent: isInProgressEvent
        ) else {
            return
        }

        let itemId = item.threadItemId
        if isInProgressEvent {
            upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
        } else {
            completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
        }
        thread.updatedAt = Date()
        scheduleSubagentIdentityHydrationIfNeeded(serverId: serverId, item: item)
    }

    private func handleItemNotificationFromParams(serverId: String, method: String, params: [String: Any]) {
        serversUsingItemNotifications.insert(serverId)

        let threadId = extractString(params, keys: ["threadId", "thread_id"])
        if let threadId { ensureThreadExistsByKey(serverId: serverId, threadId: threadId) }
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        switch method {
        case "item/mcpToolCall/progress":
            guard let progress = extractString(params, keys: ["message"]), !progress.isEmpty else { return }
            if let itemId = extractString(params, keys: ["itemId", "item_id"]),
               appendMcpProgress(progress, itemId: itemId, key: key, thread: thread) {
                thread.updatedAt = Date()
                return
            }
            thread.items.append(
                ConversationItem(
                    id: UUID().uuidString,
                    content: .note(ConversationNoteData(title: "MCP Tool Progress", body: progress)),
                    timestamp: Date()
                )
            )
            thread.updatedAt = Date()

        default:
            break
        }
    }

    private func handleLegacyCodexEventFromParams(serverId: String, method: String, params: [String: Any]) {
        let eventPayload: [String: Any]
        let eventType: String

        if method == "codex/event" {
            guard let msg = params["msg"] as? [String: Any] else { return }
            eventPayload = msg
            eventType = extractString(msg, keys: ["type"]) ?? ""
        } else {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = String(method.dropFirst("codex/event/".count))
        }

        guard !eventType.isEmpty else { return }

        let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            ?? extractString(eventPayload, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        switch eventType {
        case "exec_command_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let command = extractCommandText(eventPayload)
            let cwd = extractString(eventPayload, keys: ["cwd"]) ?? ""

            updateLiveActivity(key: key, phase: .toolCall, toolName: command.isEmpty ? "shell" : command)

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .commandExecution(
                    ConversationCommandExecutionData(
                        command: command,
                        cwd: cwd,
                        status: "inProgress",
                        output: nil,
                        exitCode: nil,
                        durationMs: nil,
                        processId: nil,
                        actions: []
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "exec_command_output_delta":
            guard let delta = extractString(eventPayload, keys: ["chunk"]), !delta.isEmpty else { return }
            if let itemId = extractString(eventPayload, keys: ["call_id", "callId"]),
               appendCommandOutputDelta(delta, itemId: itemId, key: key, thread: thread) {
                thread.updatedAt = Date()
                return
            }
            thread.items.append(
                ConversationItem(
                    id: UUID().uuidString,
                    content: .note(ConversationNoteData(title: "Command Output", body: delta)),
                    timestamp: Date()
                )
            )
            thread.updatedAt = Date()

        case "exec_command_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let command = extractCommandText(eventPayload)
            let cwd = extractString(eventPayload, keys: ["cwd"]) ?? ""
            let status = extractString(eventPayload, keys: ["status"]) ?? "completed"
            let exitCode = extractString(eventPayload, keys: ["exit_code", "exitCode"])
            let durationMs = durationMillis(from: eventPayload["duration"])

            let output = extractCommandOutput(eventPayload)
            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .commandExecution(
                    ConversationCommandExecutionData(
                        command: command,
                        cwd: cwd,
                        status: status,
                        output: output.isEmpty ? nil : output,
                        exitCode: exitCode.flatMap(Int.init),
                        durationMs: durationMs,
                        processId: nil,
                        actions: []
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "mcp_tool_call_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let invocation = eventPayload["invocation"] as? [String: Any]
            let server = invocation.flatMap { extractString($0, keys: ["server"]) } ?? ""
            let tool = invocation.flatMap { extractString($0, keys: ["tool"]) } ?? ""

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .mcpToolCall(
                    ConversationMcpToolCallData(
                        server: server,
                        tool: tool,
                        status: "inProgress",
                        durationMs: nil,
                        argumentsJSON: invocation.flatMap { $0["arguments"] }.flatMap(prettyJSON),
                        contentSummary: nil,
                        structuredContentJSON: nil,
                        rawOutputJSON: nil,
                        errorMessage: nil,
                        progressMessages: []
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "mcp_tool_call_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let invocation = eventPayload["invocation"] as? [String: Any]
            let server = invocation.flatMap { extractString($0, keys: ["server"]) } ?? ""
            let tool = invocation.flatMap { extractString($0, keys: ["tool"]) } ?? ""
            let durationMs = durationMillis(from: eventPayload["duration"])
            let result = eventPayload["result"]

            var status = "completed"
            if let resultDict = result as? [String: Any], resultDict["Err"] != nil {
                status = "failed"
            }

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .mcpToolCall(
                    ConversationMcpToolCallData(
                        server: server,
                        tool: tool,
                        status: status,
                        durationMs: durationMs,
                        argumentsJSON: invocation.flatMap { $0["arguments"] }.flatMap(prettyJSON),
                        contentSummary: result.map(stringifyValue),
                        structuredContentJSON: nil,
                        rawOutputJSON: result.flatMap(prettyJSON),
                        errorMessage: status == "failed" ? stringifyValue(result ?? "") : nil,
                        progressMessages: []
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "web_search_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId", "item_id", "itemId"])
            let query = extractString(eventPayload, keys: ["query"]) ?? ""

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .webSearch(
                    ConversationWebSearchData(
                        query: query,
                        actionJSON: nil,
                        isInProgress: true
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "web_search_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId", "item_id", "itemId"])
            let query = extractString(eventPayload, keys: ["query"]) ?? ""
            let status = extractString(eventPayload, keys: ["status"]) ?? "completed"

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .webSearch(
                    ConversationWebSearchData(
                        query: query,
                        actionJSON: eventPayload["action"].flatMap(prettyJSON),
                        isInProgress: status.lowercased().contains("progress")
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "patch_apply_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let autoApproved = (eventPayload["auto_approved"] as? Bool) == true

            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .fileChange(
                    ConversationFileChangeData(
                        status: "inProgress",
                        changes: legacyPatchChanges(from: eventPayload["changes"]),
                        outputDelta: autoApproved ? "Approval: auto" : "Approval: requested"
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "patch_apply_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let status = extractString(eventPayload, keys: ["status"]) ?? ((eventPayload["success"] as? Bool) == true ? "completed" : "failed")
            let stdout = extractString(eventPayload, keys: ["stdout"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = extractString(eventPayload, keys: ["stderr"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let outputDelta = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let msg = ConversationItem(
                id: itemId ?? UUID().uuidString,
                content: .fileChange(
                    ConversationFileChangeData(
                        status: status,
                        changes: legacyPatchChanges(from: eventPayload["changes"]),
                        outputDelta: outputDelta.isEmpty ? nil : outputDelta
                    )
                ),
                timestamp: Date()
            )
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        case "turn_diff":
            let turnId = extractString(params, keys: ["id", "turnId", "turn_id"])
                ?? extractString(eventPayload, keys: ["id", "turnId", "turn_id"])
            guard let diff = extractString(eventPayload, keys: ["unified_diff"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !diff.isEmpty else { return }
            let msg = ConversationItem(
                id: turnId ?? UUID().uuidString,
                content: .turnDiff(ConversationTurnDiffData(diff: diff)),
                sourceTurnId: turnId,
                sourceTurnIndex: nil,
                timestamp: Date()
            )

            if let turnId, !turnId.isEmpty {
                upsertLiveTurnDiffMessage(msg, turnId: turnId, key: key, thread: thread)
            } else {
                thread.items.append(msg)
            }
            thread.updatedAt = Date()

        default:
            break
        }
    }

    private func ingestCodexEventAgentMetadataFromParams(serverId: String, method: String, params: [String: Any]) {
        let eventPayload: [String: Any]
        let eventType: String
        if method == "codex/event" {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = extractString(eventPayload, keys: ["type"]) ?? "codex/event"
        } else {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = String(method.dropFirst("codex/event/".count))
        }

        func upsertIdentity(
            threadId: String?,
            agentId: String?,
            nickname: String?,
            role: String?,
            source: String
        ) {
            let normalizedThreadId = sanitizedLineageId(threadId)
            let normalizedAgentId = sanitizedLineageId(agentId)
            let normalizedNickname = sanitizedLineageId(nickname)
            let normalizedRole = sanitizedLineageId(role)
            guard normalizedThreadId != nil || normalizedAgentId != nil || normalizedNickname != nil || normalizedRole != nil else {
                return
            }
            upsertAgentDirectory(
                serverId: serverId,
                threadId: normalizedThreadId,
                agentId: normalizedAgentId,
                nickname: normalizedNickname,
                role: normalizedRole
            )
            debugAgentDirectoryLog(
                "codex-event metadata server=\(serverId) event=\(eventType) source=\(source) threadId=\(normalizedThreadId ?? "<nil>") agentId=\(normalizedAgentId ?? "<nil>") nickname=\(normalizedNickname ?? "<nil>") role=\(normalizedRole ?? "<nil>")"
            )
        }

        var senderMetadata = extractAgentMetadata(eventPayload)
        senderMetadata.threadId = senderMetadata.threadId
            ?? sanitizedLineageId(
                extractString(
                    eventPayload,
                    keys: ["sender_thread_id", "senderThreadId", "thread_id", "threadId", "conversation_id", "conversationId"]
                )
            )
            ?? sanitizedLineageId(
                extractString(
                    params,
                    keys: ["thread_id", "threadId", "conversation_id", "conversationId"]
                )
            )
        senderMetadata.agentId = senderMetadata.agentId
            ?? sanitizedLineageId(extractString(eventPayload, keys: ["sender_agent_id", "senderAgentId"]))
        upsertIdentity(
            threadId: senderMetadata.threadId,
            agentId: senderMetadata.agentId,
            nickname: senderMetadata.nickname,
            role: senderMetadata.role,
            source: "sender"
        )

        upsertIdentity(
            threadId: extractString(eventPayload, keys: ["new_thread_id", "newThreadId"]),
            agentId: extractString(eventPayload, keys: ["new_agent_id", "newAgentId"]),
            nickname: extractString(eventPayload, keys: ["new_agent_nickname", "newAgentNickname"]),
            role: extractString(eventPayload, keys: ["new_agent_role", "newAgentRole"]),
            source: "spawn-end"
        )

        upsertIdentity(
            threadId: extractString(eventPayload, keys: ["receiver_thread_id", "receiverThreadId"]),
            agentId: extractString(eventPayload, keys: ["receiver_agent_id", "receiverAgentId"]),
            nickname: extractString(eventPayload, keys: ["receiver_agent_nickname", "receiverAgentNickname"]),
            role: extractString(eventPayload, keys: ["receiver_agent_role", "receiverAgentRole"]),
            source: "receiver-single"
        )

        let receiverThreadIds = extractStringArray(
            eventPayload,
            keys: ["receiver_thread_ids", "receiverThreadIds"]
        )
        let receiverAgentsAny = (eventPayload["receiver_agents"] as? [Any]) ?? (eventPayload["receiverAgents"] as? [Any]) ?? []

        for (index, threadId) in receiverThreadIds.enumerated() {
            let alignedAgent = index < receiverAgentsAny.count ? (receiverAgentsAny[index] as? [String: Any]) : nil
            let alignedIdentity = alignedAgent.map { extractAgentMetadata($0) }
            upsertIdentity(
                threadId: threadId,
                agentId: alignedIdentity?.agentId ?? alignedAgent.flatMap { extractString($0, keys: ["agent_id", "agentId", "id"]) },
                nickname: alignedIdentity?.nickname ?? alignedAgent.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) },
                role: alignedIdentity?.role ?? alignedAgent.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]) },
                source: "receiver-thread-ids[\(index)]"
            )
        }

        for (index, rawReceiver) in receiverAgentsAny.enumerated() {
            if let receiver = rawReceiver as? [String: Any] {
                let metadata = extractAgentMetadata(receiver)
                let threadId = metadata.threadId
                    ?? extractString(receiver, keys: ["thread_id", "threadId", "receiver_thread_id", "receiverThreadId"])
                upsertIdentity(
                    threadId: threadId,
                    agentId: metadata.agentId,
                    nickname: metadata.nickname ?? extractString(receiver, keys: ["receiver_agent_nickname", "receiverAgentNickname"]),
                    role: metadata.role ?? extractString(receiver, keys: ["receiver_agent_role", "receiverAgentRole"]),
                    source: "receiver-agents[\(index)]"
                )
            } else {
                upsertIdentity(
                    threadId: extractStringValue(rawReceiver),
                    agentId: nil,
                    nickname: nil,
                    role: nil,
                    source: "receiver-agents[\(index)]-scalar"
                )
            }
        }

        if let statuses = eventPayload["statuses"] as? [String: Any] {
            for (threadId, rawStatus) in statuses {
                let statusDict = rawStatus as? [String: Any]
                upsertIdentity(
                    threadId: threadId,
                    agentId: statusDict.flatMap { extractString($0, keys: ["agent_id", "agentId"]) },
                    nickname: statusDict.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname"]) },
                    role: statusDict.flatMap { extractString($0, keys: ["agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType"]) },
                    source: "statuses"
                )
            }
        }

        if let statusEntries = eventPayload["agent_statuses"] as? [Any] {
            for (index, rawEntry) in statusEntries.enumerated() {
                guard let entry = rawEntry as? [String: Any] else { continue }
                upsertIdentity(
                    threadId: extractString(entry, keys: ["thread_id", "threadId", "receiver_thread_id", "receiverThreadId"]),
                    agentId: extractString(entry, keys: ["agent_id", "agentId"]),
                    nickname: extractString(entry, keys: ["agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname"]),
                    role: extractString(entry, keys: ["agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType"]),
                    source: "agent-statuses[\(index)]"
                )
            }
        }
    }

    func removeServer(id: String) {
        if activeVoiceSession?.threadKey.serverId == id {
            endVoiceSessionImmediately()
        }
        if id == Self.localServerID {
            setPersistedLocalVoiceThreadId(nil)
        }
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        handoffManager.unregisterServer(serverId: id)
        removePendingApprovals(forServerId: id)
        removePendingUserInputRequests(forServerId: id)
        for key in threads.keys where key.serverId == id {
            cancelThreadMetadataRefresh(for: key)
            liveItemMessageIndices.removeValue(forKey: key)
            liveTurnDiffMessageIndices.removeValue(forKey: key)
            threadTurnCounts.removeValue(forKey: key)
        }
        serversUsingItemNotifications.remove(id)
        let directoryEntryCount = agentDirectory.byThreadId.count + agentDirectory.byAgentId.count
        agentDirectory.removeServer(id)
        let updatedDirectoryEntryCount = agentDirectory.byThreadId.count + agentDirectory.byAgentId.count
        if updatedDirectoryEntryCount != directoryEntryCount {
            agentDirectoryVersion = agentDirectoryVersion &+ 1
        }
        threads = threads.filter { $0.key.serverId != id }
        if activeThreadKey?.serverId == id {
            activeThreadKey = nil
        }
        saveServerList()
    }

    func clearActiveThread() {
        activeThreadKey = nil
    }

    func reconnectAll() async {
        startNetworkMonitorIfNeeded()
        let saved = loadSavedServers()
        await withTaskGroup(of: Void.self) { group in
            for s in saved {
                let server = s.toDiscoveredServer()
                guard let target = server.connectionTarget else { continue }
                group.addTask { @MainActor in
                    await self.addServer(server, target: target)
                }
            }
        }
    }

    private func startNetworkMonitorIfNeeded() {
        guard networkMonitor.onNetworkLost == nil else { return }
        networkMonitor.onNetworkLost = { [weak self] in
            guard let self else { return }
            NSLog("[network] marking all connections disconnected")
            for (_, conn) in self.connections {
                conn.connectionHealth = .disconnected
            }
        }
        networkMonitor.onNetworkRestored = { [weak self] in
            guard let self else { return }
            NSLog("[network] restoring connections")
            Task {
                for (_, conn) in self.connections where !conn.isConnected {
                    conn.disconnect()
                    await conn.connect()
                }
            }
        }
        networkMonitor.start()
    }

    // MARK: - Thread Lifecycle

    func startThread(
        serverId: String,
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil,
        dynamicTools: [DynamicToolSpecParams]? = nil
    ) async throws -> ThreadKey {
        guard let conn = connections[serverId] else {
            throw NSError(domain: "Litter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No connection for server"])
        }
        let key = try await conn.startThread(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            dynamicTools: dynamicTools ?? (ExperimentalFeatures.shared.isEnabled(.generativeUI) ? GenerativeUITools.buildDynamicToolSpecs() : nil)
        )
        let state = ThreadState(
            serverId: key.serverId,
            threadId: key.threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.cwd = cwd
        state.model = model ?? ""
        state.requiresOpenHydration = false
        state.updatedAt = Date()
        threads[key] = state
        threadTurnCounts[key] = 0
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
        activeThreadKey = key
        _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        scheduleThreadMetadataRefresh(for: key, cwd: cwd)
        return key
    }

    func resumeThread(
        serverId: String,
        threadId: String,
        cwd: String,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async -> Bool {
        guard let conn = connections[serverId] else { return false }
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        let state = threads[key] ?? ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.status = .connecting
        threads[key] = state
        activeThreadKey = key
        do {
            let resp = try await conn.resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
            await applyResumedThreadResponse(
                resp,
                to: state,
                key: key,
                serverId: serverId
            )
            return true
        } catch {
            if containsLocalRealtimeItems(state.items), isMissingRolloutError(error) {
                state.status = .ready
                state.requiresOpenHydration = false
                return true
            }
            state.status = .error(error.localizedDescription)
            return false
        }
    }

    func hydrateThreadIfNeeded(
        _ key: ThreadKey,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async -> Bool {
        guard let thread = threads[key],
              thread.items.isEmpty,
              thread.requiresOpenHydration,
              let conn = connections[key.serverId] else {
            return threads[key]?.items.isEmpty == false
        }

        thread.status = .connecting
        let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd

        do {
            let resp = try await conn.resumeThread(
                threadId: key.threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
            await applyResumedThreadResponse(
                resp,
                to: thread,
                key: key,
                serverId: key.serverId
            )
            return true
        } catch {
            if containsLocalRealtimeItems(thread.items), isMissingRolloutError(error) {
                thread.status = .ready
                thread.requiresOpenHydration = false
                return true
            }
            thread.status = .error(error.localizedDescription)
            return false
        }
    }

    func ensureThreadPlaceholderForPresentation(_ key: ThreadKey) {
        ensureThreadExistsByKey(serverId: key.serverId, threadId: key.threadId)
    }

    func viewThread(
        _ key: ThreadKey,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async -> Bool {
        guard let thread = threads[key] else { return false }

        if thread.requiresOpenHydration && thread.items.isEmpty {
            let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd
            return await resumeThread(
                serverId: key.serverId,
                threadId: key.threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
        } else {
            thread.requiresOpenHydration = false
            activeThreadKey = key
            let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd
            _ = RecentDirectoryStore.shared.record(path: cwd, for: key.serverId)
            scheduleThreadMetadataRefresh(for: key, cwd: cwd)
            return true
        }
    }

    func prepareThreadForPresentation(
        _ key: ThreadKey,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async -> Bool {
        guard let thread = threads[key] else { return false }
        if activeThreadKey == key && !thread.requiresOpenHydration {
            return true
        }
        return await viewThread(
            key,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    private var knownRealtimeVoiceThreadKeys: [ThreadKey] {
        var keys = Set<ThreadKey>()
        if let activeKey = activeVoiceSession?.threadKey,
           !activeKey.threadId.isEmpty {
            keys.insert(activeKey)
        }
        if let stopKey = voiceStopRequestedThreadKey,
           !stopKey.threadId.isEmpty {
            keys.insert(stopKey)
        }
        if let persistedLocalThreadId = persistedLocalVoiceThreadId(),
           !persistedLocalThreadId.isEmpty,
           connections[Self.localServerID] != nil {
            keys.insert(ThreadKey(serverId: Self.localServerID, threadId: persistedLocalThreadId))
        }
        return Array(keys)
    }

    private func cleanupKnownRealtimeVoiceSessions(beforeStartingOn key: ThreadKey? = nil) async {
        let candidateKeys = knownRealtimeVoiceThreadKeys
        guard !candidateKeys.isEmpty else { return }

        for candidate in candidateKeys {
            guard candidate != key,
                  let connection = connections[candidate.serverId],
                  connection.isConnected else {
                continue
            }
            if candidate == activeVoiceSession?.threadKey {
                recordVoiceSessionDebug(
                    "-> thread/realtime/stop cleanup \(debugJSONString(["threadId": candidate.threadId]))",
                    for: candidate
                )
            }
            do {
                try await connection.stopRealtimeConversation(threadId: candidate.threadId)
                if candidate == activeVoiceSession?.threadKey {
                    recordVoiceSessionDebug(
                        "<- thread/realtime/stop cleanup {}",
                        for: candidate
                    )
                }
            } catch {
                if candidate == activeVoiceSession?.threadKey {
                    recordVoiceSessionDebug(
                        "<- thread/realtime/stop cleanup error \(error.localizedDescription)",
                        for: candidate
                    )
                }
            }
        }
    }

    private func updateVoiceSessionForPendingStop(_ key: ThreadKey) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }

        session.phase = .thinking
        session.isListening = false
        session.isSpeaking = false
        session.inputLevel = 0
        session.outputLevel = 0
        session.transcriptSpeaker = "System"
        session.transcriptText = "Hanging up..."
        session.lastError = nil
        appendVoiceSessionDebug("phase stopping", to: &session)
        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    func startVoiceOnThread(_ key: ThreadKey) async throws {
        if let existing = activeVoiceSession, existing.phase != .error { return }
        if activeVoiceSession != nil { endVoiceSessionImmediately() }
        guard key.serverId == Self.localServerID else {
            throw NSError(domain: "Litter", code: 3310,
                          userInfo: [NSLocalizedDescriptionKey: "Voice is only available on the local server"])
        }
        try await startRealtimeVoiceSession(for: key, previousActiveThreadKey: activeThreadKey)
    }

    func startPinnedLocalVoiceCall(
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws {
        guard activeVoiceSession == nil else { return }

        let previousKey = activeThreadKey
        let key = try await ensurePinnedLocalVoiceThread(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        if let previousKey, previousKey != key {
            activeThreadKey = previousKey
        } else if previousKey == nil {
            activeThreadKey = nil
        }

        try await startRealtimeVoiceSession(
            for: key,
            model: model,
            previousActiveThreadKey: previousKey
        )
    }

    private func startRealtimeVoiceSession(
        for key: ThreadKey,
        model: String? = nil,
        previousActiveThreadKey: ThreadKey?
    ) async throws {
        guard let thread = threads[key],
              let connection = connections[key.serverId],
              connection.isConnected else {
            throw NSError(
                domain: "Litter",
                code: 3302,
                userInfo: [NSLocalizedDescriptionKey: "Voice mode requires an active server connection"]
            )
        }

        if case .local = connection.target {
            // The in-process server is started with local realtime overrides,
            // so the local path does not need a config roundtrip here.
        } else {
            let features = try await connection.listExperimentalFeatures(limit: 200)
            guard Self.isRealtimeConversationEnabled(features.data) else {
                throw NSError(
                    domain: "Litter",
                    code: 3303,
                    userInfo: [NSLocalizedDescriptionKey: "This app-server does not have realtime conversation enabled"]
                )
            }
        }

        await cleanupKnownRealtimeVoiceSessions(beforeStartingOn: key)
        let runtimeSessionId = "litter-voice-\(UUID().uuidString.lowercased())"

        voicePreviousActiveThreadKey = previousActiveThreadKey
        activeThreadKey = key
        activeVoiceSession = VoiceSessionState.initial(
            threadKey: key,
            threadTitle: thread.preview,
            model: thread.model.isEmpty ? (model ?? thread.modelProvider) : thread.model
        )
        pendingRealtimeMessageIDs[key] = (nil, nil)
        lastRealtimeTranscriptDelta.removeValue(forKey: key)
        let authSnapshot = await connection.getAuthToken()
        recordVoiceSessionDebug(
            "phase connection=\(connection.connectionPhase) auth=\(debugAuthStatus(connection.authStatus)) authMethod=\(authSnapshot.method ?? "nil") tokenPresent=\(authSnapshot.token != nil)",
            for: key
        )
        let startRealtimePayload = debugJSONString([
            "threadId": key.threadId,
            "prompt": VoiceSessionControl.defaultPrompt,
            "sessionId": runtimeSessionId as Any,
            "clientControlledHandoff": true,
        ])
        recordVoiceSessionDebug(
            "-> thread/realtime/start \(startRealtimePayload)",
            for: key
        )
        syncVoiceCallActivity()

        do {
            try await connection.startRealtimeConversation(
                threadId: key.threadId,
                prompt: VoiceSessionControl.defaultPrompt,
                sessionId: runtimeSessionId,
                clientControlledHandoff: true
            )
            recordVoiceSessionDebug("<- thread/realtime/start {}", for: key)
        } catch {
            try? await connection.stopRealtimeConversation(threadId: key.threadId)
            recordVoiceSessionDebug("<- thread/realtime/start error \(error.localizedDescription)", for: key)
            failVoiceSession(error.localizedDescription)
            throw error
        }
    }

    func stopActiveVoiceSession() async {
        guard let session = activeVoiceSession else { return }
        let key = session.threadKey

        guard voiceStopRequestedThreadKey != key else { return }
        voiceStopRequestedThreadKey = key
        updateVoiceSessionForPendingStop(key)
        recordVoiceSessionDebug(
            "-> thread/realtime/stop \(debugJSONString(["threadId": key.threadId]))",
            for: key
        )

        guard let connection = connections[key.serverId], connection.isConnected else {
            recordVoiceSessionDebug("<- thread/realtime/stop skipped disconnected", for: key)
            voiceStopRequestedThreadKey = nil
            endVoiceSessionImmediately()
            return
        }

        do {
            try await connection.stopRealtimeConversation(threadId: key.threadId)
            recordVoiceSessionDebug("<- thread/realtime/stop {}", for: key)
            if voiceStopRequestedThreadKey == key {
                voiceStopRequestedThreadKey = nil
                endVoiceSessionImmediately()
            }
        } catch {
            recordVoiceSessionDebug("<- thread/realtime/stop error \(error.localizedDescription)", for: key)
            voiceStopRequestedThreadKey = nil
            appendVoiceSessionSystemMessage(
                "Failed to stop realtime voice: \(error.localizedDescription)",
                to: key
            )
            failVoiceSession("Failed to hang up: \(error.localizedDescription)")
        }
    }

    func toggleActiveVoiceSessionSpeaker() async throws {
        guard activeVoiceSession != nil else { return }
        try voiceSessionCoordinator.toggleSpeaker()
    }

    private static func isRealtimeConversationEnabled(_ features: [ExperimentalFeature]) -> Bool {
        features.contains { $0.name == VoiceSessionControl.realtimeFeatureName && $0.enabled }
    }

    private func installVoiceSessionControlObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let manager = Unmanaged<ServerManager>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                manager.handlePendingVoiceSessionEndRequestIfNeeded()
            }
        }
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            VoiceSessionControl.endRequestDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handlePendingVoiceSessionEndRequestIfNeeded() {
        guard let token = VoiceSessionControl.pendingEndRequestToken(after: lastHandledVoiceEndRequestToken) else {
            return
        }
        lastHandledVoiceEndRequestToken = token
        Task { await stopActiveVoiceSession() }
    }

    func forkThread(
        _ sourceKey: ThreadKey,
        cwd: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let sourceThread = threads[sourceKey] else {
            throw NSError(domain: "Litter", code: 1010, userInfo: [NSLocalizedDescriptionKey: "Source thread not found"])
        }
        guard !sourceThread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1011, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before forking"])
        }
        guard let conn = connections[sourceKey.serverId] else {
            throw NSError(domain: "Litter", code: 1012, userInfo: [NSLocalizedDescriptionKey: "No active server connection for this thread"])
        }

        let preferredCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forkCwd = (preferredCwd?.isEmpty == false) ? preferredCwd : sourceThread.cwd
        let response = try await conn.forkThread(
            threadId: sourceKey.threadId,
            cwd: forkCwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        let forkKey = ThreadKey(serverId: sourceKey.serverId, threadId: response.threadId)
        let forkedState = threads[forkKey] ?? ThreadState(
            serverId: sourceKey.serverId,
            threadId: response.threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        installRestoredMessages(
            response.hydratedItems,
            on: forkedState,
            key: forkKey,
            staged: false
        )
        threadTurnCounts[forkKey] = Int(response.turnCount)
        liveItemMessageIndices[forkKey] = nil
        liveTurnDiffMessageIndices[forkKey] = nil
        forkedState.cwd = response.cwd ?? forkedState.cwd
        forkedState.preview = sourceThread.preview
        forkedState.model = response.model ?? forkedState.model
        forkedState.modelProvider = response.modelProvider ?? response.model ?? forkedState.modelProvider
        forkedState.reasoningEffort = response.reasoningEffort
        forkedState.rolloutPath = response.threadPath
        forkedState.parentThreadId = sanitizedLineageId(response.parentThreadId) ?? sourceKey.threadId
        forkedState.rootThreadId = sanitizedLineageId(response.rootThreadId)
            ?? sourceThread.rootThreadId
            ?? sourceThread.parentThreadId
            ?? sourceKey.threadId
        forkedState.agentNickname = sanitizedLineageId(response.agentNickname)
        forkedState.agentRole = sanitizedLineageId(response.agentRole)
        forkedState.requiresOpenHydration = false
        upsertAgentDirectory(
            serverId: sourceKey.serverId,
            threadId: response.threadId,
            agentId: response.agentId,
            nickname: forkedState.agentNickname,
            role: forkedState.agentRole
        )
        forkedState.status = .ready
        forkedState.updatedAt = Date()
        threads[forkKey] = forkedState
        activeThreadKey = forkKey
        scheduleThreadMetadataRefresh(for: forkKey, cwd: response.cwd ?? forkedState.cwd)
        return forkKey
    }

    func forkActiveThread(
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let key = activeThreadKey,
              let thread = threads[key] else {
            throw NSError(domain: "Litter", code: 1013, userInfo: [NSLocalizedDescriptionKey: "No active thread to fork"])
        }
        return try await forkThread(
            key,
            cwd: thread.cwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    func forkFromMessage(
        _ item: ConversationItem,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let sourceKey = activeThreadKey,
              let sourceThread = threads[sourceKey] else {
            throw NSError(domain: "Litter", code: 1014, userInfo: [NSLocalizedDescriptionKey: "No active thread to fork"])
        }
        guard !sourceThread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1015, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before forking"])
        }
        guard item.isUserItem, item.isFromUserTurnBoundary else {
            throw NSError(domain: "Litter", code: 1016, userInfo: [NSLocalizedDescriptionKey: "Fork from here is only supported for user messages"])
        }

        let rollbackDepth = try rollbackDepthForItem(item, in: sourceKey)
        let forkKey = try await forkThread(
            sourceKey,
            cwd: sourceThread.cwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        guard rollbackDepth > 0 else { return forkKey }
        guard let forkConn = connections[forkKey.serverId],
              let forkThreadState = threads[forkKey] else {
            throw NSError(domain: "Litter", code: 1017, userInfo: [NSLocalizedDescriptionKey: "Forked thread unavailable"])
        }

        let rollbackResponse = try await forkConn.rollbackThread(threadId: forkKey.threadId, numTurns: rollbackDepth)
        installRestoredMessages(
            rollbackResponse.hydratedItems,
            on: forkThreadState,
            key: forkKey,
            staged: false
        )
        threadTurnCounts[forkKey] = Int(rollbackResponse.turnCount)
        forkThreadState.status = .ready
        forkThreadState.updatedAt = Date()
        liveItemMessageIndices[forkKey] = nil
        liveTurnDiffMessageIndices[forkKey] = nil
        return forkKey
    }

    func editMessage(_ item: ConversationItem) async throws {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1018, userInfo: [NSLocalizedDescriptionKey: "No active thread to edit"])
        }
        guard !thread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1019, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before editing"])
        }
        guard item.isUserItem, item.isFromUserTurnBoundary else {
            throw NSError(domain: "Litter", code: 1020, userInfo: [NSLocalizedDescriptionKey: "Only user messages can be edited"])
        }

        let rollbackDepth = try rollbackDepthForItem(item, in: key)
        if rollbackDepth > 0 {
            let response = try await conn.rollbackThread(threadId: key.threadId, numTurns: rollbackDepth)
            installRestoredMessages(
                response.hydratedItems,
                on: thread,
                key: key,
                staged: false
            )
            threadTurnCounts[key] = Int(response.turnCount)
            thread.status = .ready
            thread.updatedAt = Date()
            liveItemMessageIndices[key] = nil
            liveTurnDiffMessageIndices[key] = nil
        }
        composerPrefillRequest = ComposerPrefillRequest(text: item.userText ?? "")
    }

    // MARK: - Approvals

    func respondToPendingApproval(requestId: String, decision: ApprovalDecision) {
        guard let index = pendingApprovals.firstIndex(where: { $0.requestId == requestId }) else { return }
        let approval = pendingApprovals.remove(at: index)
        let decisionValue: String
        switch approval.method {
        case "execCommandApproval", "applyPatchApproval":
            switch decision {
            case .accept: decisionValue = "approved"
            case .acceptForSession: decisionValue = "approved_for_session"
            case .decline: decisionValue = "denied"
            case .cancel: decisionValue = "abort"
            }
        default:
            decisionValue = decision.rawValue
        }
        connections[approval.serverId]?.respondToServerRequest(
            id: approval.requestId,
            result: ["decision": decisionValue]
        )
    }

    func respondToPendingUserInput(requestId: String, answers: [String: [String]]) {
        guard let index = pendingUserInputRequests.firstIndex(where: { $0.requestId == requestId }) else { return }
        let request = pendingUserInputRequests.remove(at: index)
        let payloadAnswers = answers.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = ["answers": entry.value]
        }
        connections[request.serverId]?.respondToServerRequest(
            id: request.requestId,
            result: ["answers": payloadAnswers]
        )
    }

    private func handleServerRequest(serverId: String, requestId: String, method: String, data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let params = root["params"] as? [String: Any] ?? [:]

        let pending: PendingApproval
        switch method {
        case "item/commandExecution/requestApproval":
            let command = commandString(from: params)
            let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: threadId,
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "cmdId", "cmd_id"]),
                command: command?.isEmpty == true ? nil : command,
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "item/fileChange/requestApproval":
            let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: threadId,
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "patchId", "patch_id"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot", "grant_root"]),
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "execCommandApproval":
            let threadId = extractString(params, keys: ["conversationId", "threadId"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: threadId,
                turnId: nil,
                itemId: extractString(params, keys: ["approvalId", "callId", "cmdId"]),
                command: commandString(from: params),
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "applyPatchApproval":
            let threadId = extractString(params, keys: ["conversationId", "threadId"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: threadId,
                turnId: nil,
                itemId: extractString(params, keys: ["callId", "patchId"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot"]),
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "item/tool/requestUserInput":
            guard let threadId = extractString(params, keys: ["threadId", "thread_id"]),
                  let turnId = extractString(params, keys: ["turnId", "turn_id"]),
                  let itemId = extractString(params, keys: ["itemId", "item_id"]) else {
                return false
            }
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            let questions = pendingUserInputQuestions(from: params["questions"])
            guard !questions.isEmpty else { return false }
            pendingUserInputRequests.removeAll { $0.requestId == requestId }
            pendingUserInputRequests.append(
                PendingUserInputRequest(
                    id: requestId,
                    requestId: requestId,
                    serverId: serverId,
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    questions: questions,
                    requesterAgentNickname: requester.nickname,
                    requesterAgentRole: requester.role,
                    createdAt: Date()
                )
            )
            return true
        case "item/tool/call":
            return handleDynamicToolCall(serverId: serverId, requestId: requestId, params: params)
        case "account/chatgptAuthTokens/refresh":
            let previousAccountID = extractString(params, keys: ["previousAccountId", "previous_account_id"])
            Task { @MainActor [weak self] in
                await self?.handleChatGPTAuthTokensRefresh(
                    serverId: serverId,
                    requestId: requestId,
                    previousAccountID: previousAccountID
                )
            }
            return true
        default:
            return false
        }

        pendingApprovals.append(pending)
        return true
    }

    private func handleChatGPTAuthTokensRefresh(
        serverId: String,
        requestId: String,
        previousAccountID: String?
    ) async {
        guard let connection = connections[serverId] else { return }

        do {
            let tokens = try await ChatGPTOAuth.refreshStoredTokens(previousAccountID: previousAccountID)
            connection.respondToServerRequest(
                id: requestId,
                result: [
                    "accessToken": tokens.accessToken,
                    "chatgptAccountId": tokens.accountID,
                    "chatgptPlanType": tokens.planType ?? NSNull()
                ]
            )
        } catch {
            NSLog("[auth] ChatGPT token refresh failed: %@", error.localizedDescription)
            connection.respondToServerRequestError(id: requestId, message: error.localizedDescription)
        }
    }

    // MARK: - Dynamic Tool Calls

    private func localHandoffDynamicToolSpecs() -> [DynamicToolSpec]? {
        var tools = CrossServerTools.buildDynamicToolSpecs()
        if ExperimentalFeatures.shared.isEnabled(.generativeUI) {
            tools.append(contentsOf: GenerativeUITools.buildDynamicToolSpecs())
        }
        return tools.isEmpty ? nil : tools
    }

    private func handleDynamicToolCall(serverId: String, requestId: String, params: [String: Any]) -> Bool {
        guard let toolCallParams = ParsedDynamicToolCall(from: params) else {
            return false
        }

        let threadId = toolCallParams.threadId
        let key = ThreadKey(serverId: serverId, threadId: threadId)

        switch toolCallParams.tool {
        case GenerativeUITools.readMeToolName:
            handleReadMeToolCall(serverId: serverId, requestId: requestId, params: toolCallParams)
            return true
        case GenerativeUITools.showWidgetToolName:
            handleShowWidgetToolCall(serverId: serverId, requestId: requestId, key: key, params: toolCallParams)
            return true
        case CrossServerTools.listServersToolName:
            respondToDynamicToolCall(serverId: serverId, requestId: requestId, result: .success(listServersToolResult()))
            return true
        case CrossServerTools.listSessionsToolName:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.dynamicToolResult(
                    for: toolCallParams.tool,
                    arguments: toolCallParams.arguments
                )
                self.respondToDynamicToolCall(serverId: serverId, requestId: requestId, result: result)
            }
            return true
        case CrossServerTools.runOnServerToolName:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.dynamicToolResult(
                    for: toolCallParams.tool,
                    arguments: toolCallParams.arguments
                )
                self.respondToDynamicToolCall(serverId: serverId, requestId: requestId, result: result)
            }
            return true
        default:
            connections[serverId]?.respondToServerRequest(
                id: requestId,
                result: DynamicToolResult.error("Unknown dynamic tool: \(toolCallParams.tool)").asDictionary
            )
            return true
        }
    }

    private func handleReadMeToolCall(serverId: String, requestId: String, params: ParsedDynamicToolCall) {
        let modulesArg = params.arguments["modules"] as? [String] ?? []
        let modules = modulesArg.compactMap { WidgetGuidelineModule(rawValue: $0) }
        let guidelines = WidgetGuidelines.getGuidelines(modules: modules.isEmpty ? [.interactive] : modules)
        connections[serverId]?.respondToServerRequest(
            id: requestId,
            result: DynamicToolResult.text(guidelines).asDictionary
        )
    }

    private func handleShowWidgetToolCall(serverId: String, requestId: String, key: ThreadKey, params: ParsedDynamicToolCall) {
        guard let thread = threads[key] else {
            connections[serverId]?.respondToServerRequest(
                id: requestId,
                result: DynamicToolResult.error("Thread not found").asDictionary
            )
            return
        }

        let widget = WidgetState.fromArguments(params.arguments, callId: params.callId, isFinalized: true)

        let item = ConversationItem(
            id: params.callId,
            content: .widget(ConversationWidgetData(widgetState: widget, status: "completed")),
            sourceTurnId: thread.activeTurnId,
            sourceTurnIndex: nil,
            timestamp: Date()
        )

        if let index = liveItemMessageIndices[key]?[params.callId],
           thread.items.indices.contains(index) {
            thread.items[index] = item
        } else {
            thread.items.append(item)
        }

        thread.updatedAt = Date()

        connections[serverId]?.respondToServerRequest(
            id: requestId,
            result: DynamicToolResult.text("Widget \"\(widget.title)\" rendered and shown to the user (\(Int(widget.width))x\(Int(widget.height))).").asDictionary
        )
    }

    private func listServersToolResult() -> String {
        let items = connections.values
            .sorted { $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending }
            .map { connection in
                [
                    "id": connection.id,
                    "name": truncateTextForToolOutput(connection.server.name, maxBytes: 160),
                    "hostname": truncateTextForToolOutput(connection.server.hostname, maxBytes: 200),
                    "isConnected": connection.isConnected,
                    "isLocal": connection.id == Self.localServerID
                ]
            }
        return serializeDynamicToolPayload([
            "type": "servers",
            "items": items
        ], maxBytes: 24_000)
    }

    private func listSessionsToolResult(arguments: [String: Any]) async throws -> String {
        let limit = min(max(1, dynamicToolInt(arguments, keys: ["limit"]) ?? 20), 40)
        let requestedServer = dynamicToolString(arguments, keys: ["server_id", "server"])
        let connectionsToQuery = try dynamicToolConnections(matching: requestedServer, allowAllIfMissing: true)

        var items: [[String: Any]] = []
        var errors: [[String: String]] = []

        for connection in connectionsToQuery {
            do {
                let response = try await connection.listThreads(limit: limit)
                items.append(contentsOf: response.data.map { thread in
                    [
                        "id": thread.id,
                        "preview": truncateTextForToolOutput(thread.preview, maxBytes: 280),
                        "modelProvider": thread.modelProvider,
                        "updatedAt": thread.updatedAt,
                        "cwd": truncateTextForToolOutput(thread.cwd, maxBytes: 240),
                        "serverId": connection.id,
                        "serverName": truncateTextForToolOutput(connection.server.name, maxBytes: 160)
                    ]
                })
            } catch {
                errors.append([
                    "serverId": connection.id,
                    "serverName": truncateTextForToolOutput(connection.server.name, maxBytes: 160),
                    "message": truncateTextForToolOutput(error.localizedDescription, maxBytes: 240)
                ])
            }
        }

        items.sort {
            let lhs = $0["updatedAt"] as? Int64 ?? 0
            let rhs = $1["updatedAt"] as? Int64 ?? 0
            return lhs > rhs
        }
        if items.count > limit {
            items = Array(items.prefix(limit))
        }

        var payload: [String: Any] = [
            "type": "sessions",
            "items": items
        ]
        if !errors.isEmpty {
            payload["errors"] = errors
        }
        return serializeDynamicToolPayload(payload, maxBytes: 64_000)
    }

    private func runOnServerToolResult(arguments: [String: Any]) async throws -> String {
        let server = try dynamicToolConnection(
            matching: dynamicToolString(arguments, keys: ["server_id", "server"])
        )
        guard let prompt = dynamicToolString(arguments, keys: ["prompt"]),
              !prompt.isEmpty else {
            throw NSError(
                domain: "Litter",
                code: 3302,
                userInfo: [NSLocalizedDescriptionKey: "run_on_server requires prompt"]
            )
        }

        let key: ThreadKey
        if let existingThreadId = dynamicToolString(arguments, keys: ["thread_id"]), !existingThreadId.isEmpty {
            key = ThreadKey(serverId: server.id, threadId: existingThreadId)
            ensureThreadExistsByKey(serverId: server.id, threadId: existingThreadId)
        } else {
            let cwd = server.id == Self.localServerID ? "/" : "/tmp"
            key = try await startThread(
                serverId: server.id,
                cwd: cwd,
                approvalPolicy: "never",
                sandboxMode: server.id == Self.localServerID ? nil : "danger-full-access",
                dynamicTools: server.id == Self.localServerID ? localHandoffDynamicToolSpecs() : nil,
                activate: false
            )
        }

        let turnResponse = try await server.sendTurn(
            threadId: key.threadId,
            text: prompt,
            approvalPolicy: "never",
            model: dynamicToolString(arguments, keys: ["model"]),
            effort: dynamicToolString(arguments, keys: ["effort"]),
            serviceTier: dynamicToolString(arguments, keys: ["service_tier"])
        )
        if let turnId = turnResponse.turnId {
            threads[key]?.activeTurnId = turnId
        }
        threads[key]?.updatedAt = Date()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if threads[key]?.hasTurnActive != true {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let response = try await server.readThread(threadId: key.threadId)
        let items = readableSessionItems(from: response.thread, limit: 12)
        let assistantText = items.reversed().first { ($0["role"] as? String) == "assistant" }?["text"] as? String

        return serializeDynamicToolPayload([
            "type": "run_on_server",
            "serverId": server.id,
            "serverName": truncateTextForToolOutput(server.server.name, maxBytes: 160),
            "threadId": response.thread.id,
            "result": truncateTextForToolOutput(assistantText ?? "", maxBytes: 8_000),
            "items": items
        ], maxBytes: 96_000)
    }

    private func dynamicToolConnections(
        matching rawServer: String?,
        allowAllIfMissing: Bool
    ) throws -> [ServerConnection] {
        let connected = connections.values.filter(\.isConnected)
        guard let rawServer = rawServer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawServer.isEmpty else {
            if allowAllIfMissing {
                return connected.sorted {
                    $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
                }
            }
            throw NSError(
                domain: "Litter",
                code: 3303,
                userInfo: [NSLocalizedDescriptionKey: "A server name or ID is required"]
            )
        }

        let lowered = rawServer.lowercased()
        let matches = connected.filter { connection in
            connection.id.lowercased() == lowered ||
                connection.server.name.lowercased() == lowered ||
                connection.server.hostname.lowercased() == lowered ||
                (lowered == "local" && connection.id == Self.localServerID)
        }
        guard !matches.isEmpty else {
            throw NSError(
                domain: "Litter",
                code: 3304,
                userInfo: [NSLocalizedDescriptionKey: "Server '\(rawServer)' is not connected"]
            )
        }
        return matches.sorted {
            $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
        }
    }

    private func dynamicToolConnection(matching rawServer: String?) throws -> ServerConnection {
        let matches = try dynamicToolConnections(matching: rawServer, allowAllIfMissing: false)
        guard let first = matches.first else {
            throw NSError(
                domain: "Litter",
                code: 3305,
                userInfo: [NSLocalizedDescriptionKey: "No matching server connection"]
            )
        }
        return first
    }

    private func dynamicToolString(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func dynamicToolInt(_ arguments: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = arguments[key] as? Int {
                return value
            }
            if let value = arguments[key] as? NSNumber {
                return value.intValue
            }
            if let value = arguments[key] as? String,
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func serializeDynamicToolPayload(_ payload: Any, maxBytes: Int? = nil) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        guard let maxBytes else { return text }
        return truncateTextForToolOutput(text, maxBytes: maxBytes)
    }

    private func readableSessionItems(from thread: ResumedThread, limit: Int) -> [[String: Any]] {
        let allItems = thread.turns.flatMap(\.items)
        let mapped = allItems.compactMap(readableSessionItem)
        return Array(mapped.suffix(limit))
    }

    private func readableSessionItem(_ item: ResumedThreadItem) -> [String: Any]? {
        switch item {
        case .userMessage(let content, _):
            let text = content.compactMap { input in
                switch input.type {
                case "text":
                    return input.text
                case "image":
                    return input.url ?? input.path ?? input.name
                default:
                    return input.text ?? input.path ?? input.name ?? input.url
                }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ["role": "user", "text": truncateTextForToolOutput(text, maxBytes: 8_000)]
        case .agentMessage(let text, _, _, _, _, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : ["role": "assistant", "text": truncateTextForToolOutput(trimmed, maxBytes: 8_000)]
        case .reasoning(_, let content, _):
            let text = content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ["role": "reasoning", "text": truncateTextForToolOutput(text, maxBytes: 6_000)]
        case .commandExecution(let command, _, let status, _, let output, _, _, _, _):
            var entry: [String: Any] = [
                "role": "tool",
                "text": truncateTextForToolOutput(command, maxBytes: 600),
                "status": status
            ]
            if let output, !output.isEmpty {
                entry["output"] = truncateTextForToolOutput(output, maxBytes: 4_000)
            }
            return entry
        case .dynamicToolCall(let tool, _, let status, let contentItems, let success, _, _):
            var entry: [String: Any] = ["role": "tool", "tool": tool, "status": status]
            if let success {
                entry["success"] = success
            }
            if let contentItems {
                entry["contentPreview"] = previewToolValue(contentItems.value, maxBytes: 4_000)
            }
            return entry
        case .proposedPlan(let text, _):
            return ["role": "plan", "text": truncateTextForToolOutput(text, maxBytes: 4_000)]
        case .todoList(let items, _):
            let text = items
                .compactMap { ($0.step ?? $0.text)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return text.isEmpty ? nil : ["role": "todo", "text": truncateTextForToolOutput(text, maxBytes: 4_000)]
        case .fileChange(let changes, let status, _):
            return ["role": "tool", "status": status, "changes": changes.map(\.path)]
        case .mcpToolCall(let server, let tool, let status, _, let result, let error, _, _):
            var entry: [String: Any] = ["role": "tool", "server": server, "tool": tool, "status": status]
            if let result {
                entry["result"] = truncateTextForToolOutput(String(describing: result), maxBytes: 4_000)
            }
            if let error {
                entry["error"] = truncateTextForToolOutput(String(describing: error), maxBytes: 2_000)
            }
            return entry
        case .collabAgentToolCall(let tool, let status, _, _, _, let prompt, _):
            var entry: [String: Any] = ["role": "tool", "tool": tool, "status": status]
            if let prompt, !prompt.isEmpty {
                entry["prompt"] = truncateTextForToolOutput(prompt, maxBytes: 2_000)
            }
            return entry
        case .webSearch(let query, _, _, _):
            return ["role": "tool", "tool": "web_search", "text": truncateTextForToolOutput(query, maxBytes: 1_000)]
        case .imageView(let path, _):
            return ["role": "tool", "tool": "image_view", "path": path]
        case .enteredReviewMode(let review, _):
            return ["role": "system", "text": truncateTextForToolOutput("Entered review mode: \(review)", maxBytes: 600)]
        case .exitedReviewMode(let review, _):
            return ["role": "system", "text": truncateTextForToolOutput("Exited review mode: \(review)", maxBytes: 600)]
        case .contextCompaction:
            return ["role": "system", "text": "Context compacted"]
        case .unknown(let type, _):
            return ["role": "unknown", "type": type]
        case .ignored:
            return nil
        }
    }

    private func previewToolValue(_ value: Any, maxBytes: Int) -> String {
        if let string = value as? String {
            return truncateTextForToolOutput(string, maxBytes: maxBytes)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return truncateTextForToolOutput(text, maxBytes: maxBytes)
        }
        return truncateTextForToolOutput(String(describing: value), maxBytes: maxBytes)
    }

    private func truncateTextForToolOutput(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let marker = "\n[truncated]"
        let textBytes = text.lengthOfBytes(using: .utf8)
        guard textBytes > maxBytes else { return text }

        let markerBytes = marker.lengthOfBytes(using: .utf8)
        guard maxBytes > markerBytes else {
            return String(text.prefix(64))
        }

        let budget = maxBytes - markerBytes
        var result = ""
        result.reserveCapacity(min(text.count, budget))
        var usedBytes = 0
        for character in text {
            let charBytes = String(character).lengthOfBytes(using: .utf8)
            if usedBytes + charBytes > budget {
                break
            }
            result.append(character)
            usedBytes += charBytes
        }
        return result + marker
    }

    private func commandString(from params: [String: Any]) -> String? {
        if let command = extractString(params, keys: ["command"]), !command.isEmpty {
            return command
        }
        if let array = params["command"] as? [String], !array.isEmpty {
            return array.joined(separator: " ")
        }
        if let array = params["command"] as? [Any] {
            let parts = array.compactMap { value -> String? in
                if let text = value as? String {
                    return text
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        return nil
    }

    private func removePendingApprovals(forServerId serverId: String) {
        pendingApprovals.removeAll { $0.serverId == serverId }
    }

    private func removePendingUserInputRequests(forServerId serverId: String) {
        pendingUserInputRequests.removeAll { $0.serverId == serverId }
    }

    private func removePendingRequests(serverId: String, threadId: String?, requestId: String? = nil) {
        pendingApprovals.removeAll { pending in
            guard pending.serverId == serverId else { return false }
            if let requestId, pending.requestId == requestId {
                return true
            }
            if let threadId, pending.threadId == threadId {
                return true
            }
            return false
        }
        pendingUserInputRequests.removeAll { request in
            guard request.serverId == serverId else { return false }
            if let requestId, request.requestId == requestId {
                return true
            }
            if let threadId, request.threadId == threadId {
                return true
            }
            return false
        }
    }

    // MARK: - Send / Interrupt

    func send(
        _ text: String,
        attachmentImage: UIImage? = nil,
        skillMentions: [SkillMentionSelection] = [],
        cwd: String,
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async {
        let preparedAttachment = attachmentImage.flatMap(ConversationAttachmentSupport.prepareImage)
        let images = preparedAttachment.map { [$0.chatImage] } ?? []
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !images.isEmpty || !skillMentions.isEmpty else { return }
        var key = activeThreadKey
        if key == nil {
            guard let serverId = connections.values.first(where: { $0.isConnected })?.id else { return }
            do {
                key = try await startThread(
                    serverId: serverId,
                    cwd: cwd,
                    model: model,
                    approvalPolicy: approvalPolicy,
                    sandboxMode: sandboxMode,
                    dynamicTools: ExperimentalFeatures.shared.isEnabled(.generativeUI) ? GenerativeUITools.buildDynamicToolSpecs() : nil
                )
            } catch {
                let conn = connections[serverId]
                let errorKey = ThreadKey(serverId: serverId, threadId: "error-\(UUID().uuidString)")
                let state = ThreadState(
                    serverId: serverId,
                    threadId: errorKey.threadId,
                    serverName: conn?.server.name ?? "Server",
                    serverSource: conn?.server.source ?? .local
                )
                state.items.append(makeUserItem(text: text, images: images, sourceTurnId: nil, sourceTurnIndex: nil, isBoundary: true))
                state.items.append(makeErrorItem(message: error.localizedDescription, sourceTurnId: nil, sourceTurnIndex: nil))
                state.status = .error(error.localizedDescription)
                threads[errorKey] = state
                activeThreadKey = errorKey
                return
            }
        }
        guard let key, let thread = threads[key], let conn = connections[key.serverId] else { return }
        let nextTurnIndex = threadTurnCounts[key] ?? inferredTurnCount(from: thread.items)
        thread.items.append(makeUserItem(text: text, images: images, sourceTurnId: nil, sourceTurnIndex: nextTurnIndex, isBoundary: true))
        thread.status = .thinking
        thread.updatedAt = Date()
        requestNotificationPermissionIfNeeded()
        startLiveActivity(
            key: key,
            model: thread.model,
            cwd: thread.cwd,
            prompt: !trimmedText.isEmpty ? text : (!images.isEmpty ? "Shared image" : text)
        )
        do {
            var additionalInputs = skillMentions.map { mention in
                UserInput.skill(name: mention.name, path: AbsolutePath(value: mention.path))
            }
            if let preparedAttachment {
                additionalInputs.append(preparedAttachment.userInput)
            }
            try await conn.sendTurn(
                threadId: key.threadId,
                text: text,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode,
                model: model,
                effort: effort,
                serviceTier: serviceTier,
                additionalInput: additionalInputs
            )
            NSLog("[send] sendTurn succeeded")
        } catch {
            thread.status = .error(error.localizedDescription)
            endLiveActivity(key: key, phase: .failed)
        }
    }

    func startReviewOnActiveThread() async throws {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1001, userInfo: [NSLocalizedDescriptionKey: "No active thread to review"])
        }
        thread.status = .thinking
        do {
            _ = try await conn.startReview(threadId: key.threadId)
        } catch {
            thread.status = .error(error.localizedDescription)
            throw error
        }
    }

    func renameActiveThread(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Litter", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Thread name cannot be empty"])
        }
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1003, userInfo: [NSLocalizedDescriptionKey: "No active thread to rename"])
        }
        try await conn.setThreadName(threadId: key.threadId, name: trimmed)
        thread.preview = trimmed
        thread.updatedAt = Date()
    }

    func renameThread(_ key: ThreadKey, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Litter", code: 1030, userInfo: [NSLocalizedDescriptionKey: "Thread name cannot be empty"])
        }
        guard let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1031, userInfo: [NSLocalizedDescriptionKey: "Thread unavailable"])
        }
        try await conn.setThreadName(threadId: key.threadId, name: trimmed)
        thread.preview = trimmed
        thread.updatedAt = Date()
    }

    func archiveThread(_ key: ThreadKey) async throws {
        guard let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1032, userInfo: [NSLocalizedDescriptionKey: "Server unavailable"])
        }
        try await conn.archiveThread(threadId: key.threadId)
        clearPersistedLocalVoiceThreadIfNeeded(key)
        cancelThreadMetadataRefresh(for: key)
        threads.removeValue(forKey: key)
        threadTurnCounts.removeValue(forKey: key)
        liveItemMessageIndices.removeValue(forKey: key)
        liveTurnDiffMessageIndices.removeValue(forKey: key)
        if activeThreadKey == key {
            activeThreadKey = sortedThreads.first?.key
        }
    }

    func interrupt() async {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else { return }
        guard let turnId = thread.activeTurnId else { return }
        await conn.interrupt(threadId: key.threadId, turnId: turnId)
    }

    // MARK: - Session Refresh

    func refreshAllSessions() async {
        await withTaskGroup(of: Void.self) { group in
            for serverId in connections.keys {
                group.addTask { @MainActor in
                    await self.refreshSessions(for: serverId)
                }
            }
        }
    }

    func refreshSessions(for serverId: String) async {
        guard let conn = connections[serverId], conn.isConnected else { return }
        do {
            let threadList = try await conn.listThreads()
            var recentDirectoryEntries: [RecentDirectoryEntry] = []
            for summary in threadList {
                let key = ThreadKey(serverId: serverId, threadId: summary.id)
                let updatedAt = summary.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let normalizedPath = (summary.cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedPath.isEmpty {
                    recentDirectoryEntries.append(
                        RecentDirectoryEntry(
                            serverId: serverId,
                            path: normalizedPath,
                            lastUsedAt: updatedAt ?? Date(),
                            useCount: 0
                        )
                    )
                }
                if let existing = threads[key] {
                    if let preview = summary.preview, existing.preview != preview {
                        existing.preview = preview
                    }
                    if let cwd = summary.cwd, existing.cwd != cwd {
                        existing.cwd = cwd
                    }
                    let nextRolloutPath = summary.path ?? existing.rolloutPath
                    if existing.rolloutPath != nextRolloutPath {
                        existing.rolloutPath = nextRolloutPath
                    }
                    if let mp = summary.modelProvider, existing.modelProvider != mp {
                        existing.modelProvider = mp
                    }
                    let nextAgentNickname = sanitizedLineageId(summary.agentNickname) ?? existing.agentNickname
                    if existing.agentNickname != nextAgentNickname {
                        existing.agentNickname = nextAgentNickname
                    }
                    let nextAgentRole = sanitizedLineageId(summary.agentRole) ?? existing.agentRole
                    if existing.agentRole != nextAgentRole {
                        existing.agentRole = nextAgentRole
                    }
                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: summary.id,
                        agentId: nil,
                        nickname: existing.agentNickname,
                        role: existing.agentRole
                    )
                    if let updatedAt, existing.updatedAt != updatedAt {
                        existing.updatedAt = updatedAt
                    }
                } else {
                    let state = ThreadState(
                        serverId: serverId,
                        threadId: summary.id,
                        serverName: conn.server.name,
                        serverSource: conn.server.source
                    )
                    state.preview = summary.preview ?? ""
                    state.cwd = summary.cwd ?? ""
                    state.rolloutPath = summary.path
                    state.modelProvider = summary.modelProvider ?? ""
                    state.agentNickname = sanitizedLineageId(summary.agentNickname)
                    state.agentRole = sanitizedLineageId(summary.agentRole)
                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: summary.id,
                        agentId: nil,
                        nickname: state.agentNickname,
                        role: state.agentRole
                    )
                    if let updatedAt {
                        state.updatedAt = updatedAt
                    }
                    threads[key] = state
                    threadTurnCounts[key] = threadTurnCounts[key] ?? 0
                }
            }
            _ = RecentDirectoryStore.shared.mergeSessionDirectories(recentDirectoryEntries, for: serverId)
        } catch {}
    }

    /// Create a minimal ThreadState for a thread ID we haven't seen yet.
    /// Called from turn/started, thread/status/changed, etc. to ensure items
    /// for subagent threads are not silently dropped.
    private func ensureThreadExistsByKey(serverId: String, threadId: String) {
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        guard threads[key] == nil, let conn = connections[serverId] else { return }
        let state = ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.requiresOpenHydration = true
        threads[key] = state
        threadTurnCounts[key] = 0
    }

    private func scheduleSubagentIdentityHydrationIfNeeded(serverId: String, item: ThreadItem) {
        guard case .collabAgentToolCall(_, _, _, _, let receiverThreadIds, _, _, _, _) = item else {
            return
        }

        var seen = Set<String>()
        let childThreadIds: [String] = receiverThreadIds.compactMap { rawId in
            let normalized = sanitizedLineageId(rawId)
            guard let normalized, seen.insert(normalized).inserted else { return nil }
            return normalized
        }

        for childThreadId in childThreadIds {
            let key = ThreadKey(serverId: serverId, threadId: childThreadId)
            ensureThreadExistsByKey(serverId: serverId, threadId: childThreadId)
            guard needsSubagentIdentityHydration(for: key),
                  deferredSubagentIdentityHydrationTasks[key] == nil else {
                continue
            }

            deferredSubagentIdentityHydrationTasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.deferredSubagentIdentityHydrationTasks[key] = nil }

                for attempt in 0..<4 {
                    if Task.isCancelled { return }
                    guard let conn = self.connections[serverId], conn.isConnected else { return }

                    if let response = try? await conn.readThread(threadId: childThreadId) {
                        self.applySubagentIdentityMetadata(response, to: key)
                        if !self.needsSubagentIdentityHydration(for: key) {
                            return
                        }
                    }

                    if attempt < 3 {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        }
    }

    private func needsSubagentIdentityHydration(for key: ThreadKey) -> Bool {
        if let thread = threads[key], thread.agentDisplayLabel != nil {
            return false
        }

        let entry = mergedAgentDirectoryEntry(
            serverId: key.serverId,
            threadId: key.threadId,
            agentId: key.threadId
        )
        return AgentLabelFormatter.format(
            nickname: entry?.nickname,
            role: entry?.role,
            fallbackIdentifier: nil
        ) == nil
    }

    private func applySubagentIdentityMetadata(_ response: ThreadResponseWithHydration, to key: ThreadKey) {
        guard let state = threads[key] else { return }

        if let parentThreadId = sanitizedLineageId(response.parentThreadId) {
            state.parentThreadId = parentThreadId
        }
        if let rootThreadId = sanitizedLineageId(response.rootThreadId) {
            state.rootThreadId = rootThreadId
        }
        if let agentNickname = sanitizedLineageId(response.agentNickname) {
            state.agentNickname = agentNickname
        }
        if let agentRole = sanitizedLineageId(response.agentRole) {
            state.agentRole = agentRole
        }
        if let cwd = response.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            state.cwd = cwd
        }
        if let model = response.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            state.model = model
        }
        if let modelProvider = response.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !modelProvider.isEmpty {
            state.modelProvider = modelProvider
        }

        upsertAgentDirectory(
            serverId: key.serverId,
            threadId: response.threadId,
            agentId: response.agentId,
            nickname: state.agentNickname,
            role: state.agentRole
        )
    }


    private func applyResumedThreadResponse(
        _ resp: ThreadResponseWithHydration,
        to state: ThreadState,
        key: ThreadKey,
        serverId: String
    ) async {
        state.cwd = resp.cwd ?? state.cwd
        state.model = resp.model ?? state.model
        state.modelProvider = resp.modelProvider ?? resp.model ?? state.modelProvider
        state.reasoningEffort = resp.reasoningEffort ?? state.reasoningEffort
        state.rolloutPath = resp.threadPath ?? state.rolloutPath
        state.parentThreadId = sanitizedLineageId(resp.parentThreadId)
        state.rootThreadId = sanitizedLineageId(resp.rootThreadId)
        state.agentNickname = sanitizedLineageId(resp.agentNickname)
        state.agentRole = sanitizedLineageId(resp.agentRole)
        upsertAgentDirectory(
            serverId: serverId,
            threadId: key.threadId,
            agentId: resp.agentId,
            nickname: state.agentNickname,
            role: state.agentRole
        )
        await Task.yield()
        installRestoredMessages(
            resp.hydratedItems,
            on: state,
            key: key,
            staged: true,
            preferLocalMessages: true
        )
        state.requiresOpenHydration = false
        threadTurnCounts[key] = Int(resp.turnCount)
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
        state.status = .ready
        state.updatedAt = Date()
        if let cwd = resp.cwd, !cwd.isEmpty {
            _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        }
        scheduleThreadMetadataRefresh(for: key, cwd: resp.cwd ?? state.cwd)
    }

    private func handleVoiceSessionCoordinatorEvent(_ event: VoiceSessionCoordinator.Event) {
        guard var session = activeVoiceSession else { return }

        switch event {
        case .inputLevel(let level):
            session.inputLevel = level
            session.isListening = true
            if level > 0.05, !session.isSpeaking {
                session.phase = .listening
            }
            activeVoiceSession = session
            syncVoiceCallActivity()

            let token = UUID()
            voiceInputDecayToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self,
                      self.voiceInputDecayToken == token,
                      var current = self.activeVoiceSession,
                      current.threadKey == session.threadKey else {
                    return
                }
                current.inputLevel = 0
                if !current.isSpeaking && current.phase != .error {
                    current.phase = .thinking
                }
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .outputLevel(let level):
            session.outputLevel = level
            session.isSpeaking = level > 0.02
            if session.isSpeaking {
                session.phase = .speaking
            }
            activeVoiceSession = session
            syncVoiceCallActivity()

            let token = UUID()
            voiceOutputDecayToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self,
                      self.voiceOutputDecayToken == token,
                      var current = self.activeVoiceSession,
                      current.threadKey == session.threadKey else {
                    return
                }
                current.outputLevel = 0
                current.isSpeaking = false
                if current.phase != .error {
                    current.phase = .listening
                }
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .routeChanged(let route):
            session.route = route
            activeVoiceSession = session
            syncVoiceCallActivity()

        case .interrupted:
            session.phase = .thinking
            activeVoiceSession = session
            syncVoiceCallActivity()

        case .failure(let message):
            appendVoiceSessionSystemMessage(message, to: session.threadKey)
            failVoiceSession(message)
        }
    }

    private func appendRealtimeAudioChunk(_ chunk: ThreadRealtimeAudioChunk, for key: ThreadKey) async {
        guard activeVoiceSession?.threadKey == key,
              let connection = connections[key.serverId],
              connection.isConnected else {
            return
        }
        do {
            try await connection.appendRealtimeAudio(threadId: key.threadId, audio: chunk)
        } catch {
            appendVoiceSessionSystemMessage("Realtime voice audio failed: \(error.localizedDescription)", to: key)
            failVoiceSession(error.localizedDescription)
        }
    }

    private func appendVoiceSessionSystemMessage(_ message: String, to key: ThreadKey) {
        guard let thread = threads[key] else { return }
        thread.items.append(
            ConversationItem(
                id: UUID().uuidString,
                content: .note(
                    ConversationNoteData(title: "Voice", body: message)
                ),
                timestamp: Date()
            )
        )
        thread.updatedAt = Date()
    }

    private func failVoiceSession(_ message: String) {
        voiceSessionCoordinator.stop()
        voiceInputDecayToken = nil
        voiceOutputDecayToken = nil

        guard var session = activeVoiceSession else {
            endVoiceSessionImmediately()
            return
        }

        session.phase = .error
        session.lastError = message
        session.isListening = false
        session.isSpeaking = false
        session.inputLevel = 0
        session.outputLevel = 0
        session.transcriptLiveMessageID = nil
        appendVoiceSessionDebug("phase error \(message)", to: &session)
        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func endVoiceSessionImmediately() {
        let activeKey = activeVoiceSession?.threadKey
        voiceInputDecayToken = nil
        voiceOutputDecayToken = nil
        voiceStopRequestedThreadKey = nil
        voiceSessionCoordinator.stop()
        if let previousKey = voicePreviousActiveThreadKey,
           threads[previousKey] != nil {
            activeThreadKey = previousKey
        } else if activeVoiceSession != nil {
            activeThreadKey = nil
        }
        voicePreviousActiveThreadKey = nil
        if let activeKey {
            pendingRealtimeMessageIDs.removeValue(forKey: activeKey)
            lastRealtimeTranscriptDelta.removeValue(forKey: activeKey)
        }
        activeVoiceSession = nil
        endVoiceCallActivity()
    }

    private func syncVoiceCallActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let session = activeVoiceSession else {
            endVoiceCallActivity()
            return
        }

        if voiceCallActivity == nil {
            let attributes = CodexVoiceCallAttributes(
                threadId: session.threadKey.threadId,
                threadTitle: session.threadTitle,
                model: session.model,
                startDate: session.startedAt
            )
            do {
                voiceCallActivity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: session.activityContentState, staleDate: nil)
                )
            } catch {
                NSLog("[%@ voice-la] failed to start: %@", ts, error.localizedDescription)
            }
            return
        }

        guard let activity = voiceCallActivity else { return }
        Task {
            await activity.update(
                .init(
                    state: session.activityContentState,
                    staleDate: Date(timeIntervalSinceNow: 120)
                )
            )
        }
    }

    private func endVoiceCallActivity() {
        guard let activity = voiceCallActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .after(.now + 2))
        }
        voiceCallActivity = nil
    }

    private func recordVoiceSessionDebug(_ line: String, for key: ThreadKey) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }
        appendVoiceSessionDebug(line, to: &session)
        activeVoiceSession = session
    }

    private func debugJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "<encode-failed>"
        }
        return string
    }

    private func debugJSONString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "<encode-failed>"
        }
        return string
    }

    private func appendVoiceSessionDebug(_ line: String, to session: inout VoiceSessionState) {
        session.debugEntries.append(VoiceSessionDebugEntry(line: line))
        if session.debugEntries.count > 40 {
            session.debugEntries.removeFirst(session.debugEntries.count - 40)
        }
    }

    private func debugAuthStatus(_ status: AuthStatus) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .notLoggedIn:
            return "notLoggedIn"
        case .apiKey:
            return "apiKey"
        case .chatgpt(let email):
            return "chatgpt(\(email))"
        }
    }

    private func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                return value
            }
            if let value = dict[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private func pendingUserInputQuestions(from raw: Any?) -> [PendingUserInputQuestion] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { rawQuestion in
            guard let dict = rawQuestion as? [String: Any],
                  let id = extractString(dict, keys: ["id"]),
                  let header = extractString(dict, keys: ["header"]),
                  let question = extractString(dict, keys: ["question"]) else {
                return nil
            }
            let options = (dict["options"] as? [Any] ?? []).compactMap { rawOption -> PendingUserInputOption? in
                guard let optionDict = rawOption as? [String: Any],
                      let label = extractString(optionDict, keys: ["label"]),
                      let description = extractString(optionDict, keys: ["description"]) else {
                    return nil
                }
                return PendingUserInputOption(label: label, description: description)
            }
            return PendingUserInputQuestion(
                id: id,
                header: header,
                question: question,
                isOther: (dict["isOther"] as? Bool) ?? (dict["is_other"] as? Bool) ?? false,
                isSecret: (dict["isSecret"] as? Bool) ?? (dict["is_secret"] as? Bool) ?? false,
                options: options
            )
        }
    }

    private func extractInt64(_ dict: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = extractInt64Value(dict[key]) {
                return value
            }
        }
        return nil
    }

    private func extractRealtimeAudioChunk(params: [String: Any]) -> ThreadRealtimeAudioChunk? {
        guard let audio = params["audio"] as? [String: Any],
              let data = extractString(audio, keys: ["data"]) else {
            return nil
        }
        let sampleRate = UInt32(extractInt64(audio, keys: ["sampleRate", "sample_rate"]) ?? 24_000)
        let numChannels = UInt32(extractInt64(audio, keys: ["numChannels", "num_channels"]) ?? 1)
        let samplesPerChannel = extractInt64(audio, keys: ["samplesPerChannel", "samples_per_channel"])
            .map(UInt32.init)
        return ThreadRealtimeAudioChunk(
            data: data,
            sampleRate: sampleRate,
            numChannels: numChannels,
            samplesPerChannel: samplesPerChannel
        )
    }

    private func extractInt64Value(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func extractStringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func extractStringArray(_ dict: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let strings = raw as? [String] {
                return strings.compactMap { sanitizedLineageId($0) }
            }
            if let values = raw as? [Any] {
                return values.compactMap { extractStringValue($0) }.compactMap { sanitizedLineageId($0) }
            }
        }
        return []
    }

    private struct AgentIdentity {
        var threadId: String?
        var agentId: String?
        var nickname: String?
        var role: String?

        var hasMetadata: Bool {
            agentId != nil || nickname != nil || role != nil
        }
    }

    private func extractAgentMetadata(_ dict: [String: Any]) -> AgentIdentity {
        let directThreadId = extractString(dict, keys: [
            "threadId", "thread_id",
            "conversationId", "conversation_id",
            "receiverThreadId", "receiver_thread_id"
        ])
        let directAgentId = extractString(dict, keys: ["agentId", "agent_id", "id"])
        let directNickname = extractString(dict, keys: ["agentNickname", "agent_nickname", "nickname", "name"])
        let directRole = extractString(dict, keys: ["agentRole", "agent_role", "agentType", "agent_type"])

        let source = dict["source"] as? [String: Any]
        let subAgent = (source?["subAgent"] as? [String: Any]) ?? (source?["sub_agent"] as? [String: Any])
        let threadSpawn = (subAgent?["thread_spawn"] as? [String: Any]) ?? (subAgent?["threadSpawn"] as? [String: Any])
        let nestedThreadId = threadSpawn.flatMap { extractString($0, keys: ["thread_id", "threadId"]) }
        let nestedAgentId = threadSpawn.flatMap { extractString($0, keys: ["agent_id", "agentId"]) }
        let nestedSpawnId = threadSpawn.flatMap { extractString($0, keys: ["id"]) }
        let nestedSubAgentId = subAgent.flatMap { extractString($0, keys: ["agent_id", "agentId", "id"]) }
        let nestedNickname = threadSpawn.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) }
        let nestedRole = threadSpawn.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType"]) }
        let nestedSubAgentNickname = subAgent.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) }
        let nestedSubAgentRole = subAgent.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType"]) }

        return AgentIdentity(
            threadId: sanitizedLineageId(directThreadId) ?? sanitizedLineageId(nestedThreadId),
            agentId: sanitizedLineageId(directAgentId)
                ?? sanitizedLineageId(nestedAgentId)
                ?? sanitizedLineageId(nestedSubAgentId)
                ?? sanitizedLineageId(nestedSpawnId),
            nickname: sanitizedLineageId(directNickname)
                ?? sanitizedLineageId(nestedNickname)
                ?? sanitizedLineageId(nestedSubAgentNickname),
            role: sanitizedLineageId(directRole)
                ?? sanitizedLineageId(nestedRole)
                ?? sanitizedLineageId(nestedSubAgentRole)
        )
    }

    private func resolveAgentIdentity(
        serverId: String,
        threadId: String?,
        params: [String: Any] = [:]
    ) -> AgentIdentity {
        let normalizedThreadId = sanitizedLineageId(threadId)
        var fromParams = extractAgentMetadata(params)
        fromParams.threadId = fromParams.threadId ?? normalizedThreadId

        if fromParams.hasMetadata {
            upsertAgentDirectory(
                serverId: serverId,
                threadId: fromParams.threadId,
                agentId: fromParams.agentId,
                nickname: fromParams.nickname,
                role: fromParams.role
            )
        }

        let fromDirectory = mergedAgentDirectoryEntry(
            serverId: serverId,
            threadId: fromParams.threadId,
            agentId: fromParams.agentId
        )
        let resolvedThreadId = fromParams.threadId ?? fromDirectory?.threadId
        let fromThreadState = resolvedThreadId
            .map { ThreadKey(serverId: serverId, threadId: $0) }
            .flatMap { threads[$0] }

        let resolved = AgentIdentity(
            threadId: resolvedThreadId,
            agentId: fromParams.agentId ?? fromDirectory?.agentId,
            nickname: fromParams.nickname ?? fromDirectory?.nickname ?? fromThreadState?.agentNickname,
            role: fromParams.role ?? fromDirectory?.role ?? fromThreadState?.agentRole
        )

        if resolved.hasMetadata {
            upsertAgentDirectory(
                serverId: serverId,
                threadId: resolved.threadId,
                agentId: resolved.agentId,
                nickname: resolved.nickname,
                role: resolved.role
            )
        }
        return resolved
    }

    private func mergedAgentDirectoryEntry(serverId: String?, threadId: String?, agentId: String?) -> AgentDirectoryEntry? {
        guard let serverScope = agentDirectoryServerScope(serverId) else {
            return nil
        }
        let normalizedThreadId = sanitizedLineageId(threadId)
        let normalizedAgentId = sanitizedLineageId(agentId)
        let threadEntry = normalizedThreadId.flatMap {
            agentDirectory.byThreadId[agentDirectoryScopedKey(serverId: serverScope, id: $0)]
        }
        let agentEntry = normalizedAgentId.flatMap {
            agentDirectory.byAgentId[agentDirectoryScopedKey(serverId: serverScope, id: $0)]
        }
        guard threadEntry != nil || agentEntry != nil else { return nil }

        let preferred = agentEntry ?? threadEntry
        return AgentDirectoryEntry(
            nickname: preferred?.nickname ?? threadEntry?.nickname ?? agentEntry?.nickname,
            role: preferred?.role ?? threadEntry?.role ?? agentEntry?.role,
            threadId: normalizedThreadId ?? threadEntry?.threadId ?? agentEntry?.threadId,
            agentId: normalizedAgentId ?? agentEntry?.agentId ?? threadEntry?.agentId
        )
    }

    private func upsertAgentDirectory(
        serverId: String?,
        threadId: String?,
        agentId: String?,
        nickname: String?,
        role: String?
    ) {
        guard let serverScope = agentDirectoryServerScope(serverId) else {
            debugAgentDirectoryLog(
                "upsert skipped threadId=\(threadId ?? "<nil>") agentId=\(agentId ?? "<nil>") reason=missing-server-scope"
            )
            return
        }
        let normalizedThreadId = sanitizedLineageId(threadId)
        let normalizedAgentId = sanitizedLineageId(agentId)
        let normalizedNickname = sanitizedLineageId(nickname)
        let normalizedRole = sanitizedLineageId(role)
        guard normalizedThreadId != nil || normalizedAgentId != nil || normalizedNickname != nil || normalizedRole != nil else {
            debugAgentDirectoryLog(
                "upsert skipped server=\(serverScope) threadId=\(threadId ?? "<nil>") agentId=\(agentId ?? "<nil>") reason=empty-identifiers-and-metadata"
            )
            return
        }

        let scopedThreadKey = normalizedThreadId.map { agentDirectoryScopedKey(serverId: serverScope, id: $0) }
        let scopedAgentKey = normalizedAgentId.map { agentDirectoryScopedKey(serverId: serverScope, id: $0) }

        var merged = AgentDirectoryEntry(
            nickname: normalizedNickname,
            role: normalizedRole,
            threadId: normalizedThreadId,
            agentId: normalizedAgentId
        )

        if let scopedThreadKey, let existing = agentDirectory.byThreadId[scopedThreadKey] {
            merged = merged.merged(over: existing)
        }
        if let scopedAgentKey, let existing = agentDirectory.byAgentId[scopedAgentKey] {
            merged = merged.merged(over: existing)
        }

        var didChange = false
        if let scopedThreadKey, agentDirectory.byThreadId[scopedThreadKey] != merged {
            agentDirectory.byThreadId[scopedThreadKey] = merged
            didChange = true
        }
        if let scopedAgentKey, agentDirectory.byAgentId[scopedAgentKey] != merged {
            agentDirectory.byAgentId[scopedAgentKey] = merged
            didChange = true
        }
        if let linkedThreadId = merged.threadId,
           let linkedAgentId = merged.agentId {
            let linkedThreadKey = agentDirectoryScopedKey(serverId: serverScope, id: linkedThreadId)
            let linkedAgentKey = agentDirectoryScopedKey(serverId: serverScope, id: linkedAgentId)
            if agentDirectory.byThreadId[linkedThreadKey] != merged {
                agentDirectory.byThreadId[linkedThreadKey] = merged
                didChange = true
            }
            if agentDirectory.byAgentId[linkedAgentKey] != merged {
                agentDirectory.byAgentId[linkedAgentKey] = merged
                didChange = true
            }
        }
        let mergedLabel = formatAgentLabel(
            nickname: merged.nickname,
            role: merged.role,
            fallbackThreadId: merged.threadId ?? merged.agentId
        ) ?? "<nil>"
        if didChange {
            agentDirectoryVersion = agentDirectoryVersion &+ 1
            debugAgentDirectoryLog(
                "upsert updated server=\(serverScope) threadId=\(merged.threadId ?? "<nil>") agentId=\(merged.agentId ?? "<nil>") label=\(mergedLabel)"
            )
        } else if merged.nickname != nil || merged.role != nil || merged.agentId != nil {
            debugAgentDirectoryLog(
                "upsert no-op server=\(serverScope) threadId=\(merged.threadId ?? "<nil>") agentId=\(merged.agentId ?? "<nil>") label=\(mergedLabel)"
            )
        }
    }

    private func formatAgentLabel(nickname: String?, role: String?, fallbackThreadId: String? = nil) -> String? {
        AgentLabelFormatter.format(
            nickname: nickname,
            role: role,
            fallbackIdentifier: fallbackThreadId
        )
    }

    private func sanitizedLineageId(_ raw: String?) -> String? {
        AgentLabelFormatter.sanitized(raw)
    }

    private func upsertLiveItemMessage(_ message: ConversationItem, itemId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveItemMessageIndices[key]?[itemId],
           thread.items.indices.contains(index) {
            thread.items[index] = message
        } else {
            let index = thread.items.count
            thread.items.append(message)
            liveItemMessageIndices[key, default: [:]][itemId] = index
        }
    }

    private func completeLiveItemMessage(_ message: ConversationItem, itemId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveItemMessageIndices[key]?[itemId],
           thread.items.indices.contains(index) {
            thread.items[index] = message
        } else {
            thread.items.append(message)
        }
        liveItemMessageIndices[key]?[itemId] = nil
    }

    private func appendCommandOutputDelta(_ delta: String, itemId: String, key: ThreadKey, thread: ThreadState) -> Bool {
        guard let index = liveItemMessageIndices[key]?[itemId],
              thread.items.indices.contains(index) else {
            return false
        }
        guard case .commandExecution(var data) = thread.items[index].content else {
            return false
        }
        data.output = mergeCommandOutput(data.output ?? "", delta: delta)
        thread.items[index].content = .commandExecution(data)
        return true
    }

    private func appendMcpProgress(_ progress: String, itemId: String, key: ThreadKey, thread: ThreadState) -> Bool {
        guard let index = liveItemMessageIndices[key]?[itemId],
              thread.items.indices.contains(index) else {
            return false
        }
        guard case .mcpToolCall(var data) = thread.items[index].content else {
            return false
        }
        data.progressMessages = mergeProgress(data.progressMessages, progress: progress)
        thread.items[index].content = .mcpToolCall(data)
        return true
    }

    private func appendProposedPlanDelta(_ delta: String, itemId: String, turnId: String?, key: ThreadKey, thread: ThreadState) -> Bool {
        if let mappedIndex = liveItemMessageIndices[key]?[itemId],
           thread.items.indices.contains(mappedIndex),
           case .proposedPlan(var data) = thread.items[mappedIndex].content {
            data.content = mergePlanText(data.content, delta: delta)
            thread.items[mappedIndex].content = .proposedPlan(data)
            if let turnId, thread.items[mappedIndex].sourceTurnId == nil {
                thread.items[mappedIndex].sourceTurnId = turnId
            }
            thread.items[mappedIndex].timestamp = Date()
            return true
        }

        if let turnId,
           let index = proposedPlanItemIndex(for: turnId, in: thread),
           thread.items.indices.contains(index),
           case .proposedPlan(var data) = thread.items[index].content {
            data.content = mergePlanText(data.content, delta: delta)
            thread.items[index].content = .proposedPlan(data)
            thread.items[index].timestamp = Date()
            return true
        }

        let seedId = itemId.isEmpty ? "proposed-plan-\(turnId ?? UUID().uuidString)" : itemId
        let item = ConversationItem(
            id: seedId,
            content: .proposedPlan(ConversationProposedPlanData(content: delta.trimmingCharacters(in: .newlines))),
            sourceTurnId: turnId,
            timestamp: Date()
        )
        if !itemId.isEmpty {
            upsertLiveItemMessage(item, itemId: itemId, key: key, thread: thread)
        } else {
            thread.items.append(item)
        }
        return true
    }

    private func mergeCommandOutput(_ current: String, delta: String) -> String {
        let outputPrefix = "\n\nOutput:\n```text\n"
        let closingFence = "\n```"

        if let outputRange = current.range(of: outputPrefix),
           let closeRange = current.range(of: closingFence, options: .backwards),
           closeRange.lowerBound >= outputRange.upperBound {
            var updated = current
            updated.insert(contentsOf: delta, at: closeRange.lowerBound)
            return updated
        }

        var chunk = delta
        if !chunk.hasSuffix("\n") {
            chunk += "\n"
        }
        return current + outputPrefix + chunk + "```"
    }

    private func mergePlanText(_ current: String, delta: String) -> String {
        (current + delta).trimmingCharacters(in: .newlines)
    }

    private func mergeProgress(_ current: [String], progress: String) -> [String] {
        var next = current
        next.append(progress)
        return next
    }

    private func proposedPlanItemIndex(for turnId: String, in thread: ThreadState) -> Int? {
        for index in thread.items.indices.reversed() {
            guard case .proposedPlan = thread.items[index].content else { continue }
            let itemTurnId = thread.items[index].sourceTurnId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if itemTurnId == turnId {
                return index
            }
        }

        if thread.activeTurnId == turnId {
            for index in thread.items.indices.reversed() {
                guard case .proposedPlan = thread.items[index].content else { continue }
                if thread.items[index].sourceTurnId == nil {
                    return index
                }
            }
        }

        return nil
    }

    private func todoListItemIndex(for turnId: String, in thread: ThreadState) -> Int? {
        for index in thread.items.indices.reversed() {
            guard case .todoList = thread.items[index].content else { continue }
            let itemTurnId = thread.items[index].sourceTurnId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if itemTurnId == turnId {
                return index
            }
        }
        return nil
    }

    private func upsertTurnTodoList(turnId: String, steps: [ConversationPlanStep], thread: ThreadState) {
        guard !steps.isEmpty else { return }

        if let index = todoListItemIndex(for: turnId, in: thread),
           thread.items.indices.contains(index) {
            thread.items[index].content = .todoList(ConversationTodoListData(steps: steps))
            thread.items[index].sourceTurnId = turnId
            thread.items[index].timestamp = Date()
            return
        }

        thread.items.append(
            ConversationItem(
                id: "turn-todo-\(turnId)",
                content: .todoList(ConversationTodoListData(steps: steps)),
                sourceTurnId: turnId,
                timestamp: Date()
            )
        )
    }

    private func planSteps(from rawValue: Any?) -> [ConversationPlanStep] {
        guard let values = rawValue as? [Any] else { return [] }
        return values.compactMap { rawStep in
            guard let stepDict = rawStep as? [String: Any],
                  let step = extractString(stepDict, keys: ["step"]),
                  !step.isEmpty else {
                return nil
            }
            let rawStatus = extractString(stepDict, keys: ["status"]) ?? ConversationPlanStepStatus.pending.rawValue
            return ConversationPlanStep(step: step, status: planStepStatus(from: rawStatus))
        }
    }

    private func planStepStatus(from raw: String) -> ConversationPlanStepStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed":
            return .completed
        case "inprogress", "in_progress":
            return .inProgress
        default:
            return .pending
        }
    }


    private func upsertLiveTurnDiffMessage(_ message: ConversationItem, turnId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveTurnDiffMessageIndices[key]?[turnId],
           thread.items.indices.contains(index) {
            thread.items[index] = message
        } else {
            let index = thread.items.count
            thread.items.append(message)
            liveTurnDiffMessageIndices[key, default: [:]][turnId] = index
        }
    }

    private func extractCommandText(_ eventPayload: [String: Any]) -> String {
        if let parts = eventPayload["command"] as? [String], !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return extractString(eventPayload, keys: ["command"]) ?? ""
    }

    private func extractCommandOutput(_ eventPayload: [String: Any]) -> String {
        let candidateKeys = ["aggregated_output", "formatted_output", "stdout", "stderr"]
        let chunks = candidateKeys.compactMap { extractString(eventPayload, keys: [$0]) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return chunks.joined(separator: "\n")
    }

    private func durationMillis(from rawDuration: Any?) -> Int? {
        if let value = rawDuration as? NSNumber {
            return value.intValue
        }
        if let dict = rawDuration as? [String: Any],
           let secsValue = dict["secs"] as? NSNumber {
            let nanosValue = (dict["nanos"] as? NSNumber)?.int64Value ?? 0
            let millis = secsValue.int64Value * 1_000 + nanosValue / 1_000_000
            return Int(millis)
        }
        return nil
    }

    private func legacyPatchChangeBody(from rawChanges: Any?) -> String {
        guard let changes = rawChanges as? [String: Any], !changes.isEmpty else { return "" }
        var sections: [String] = []
        for path in changes.keys.sorted() {
            guard let change = changes[path] as? [String: Any] else { continue }
            let kind = extractString(change, keys: ["type"]) ?? "update"
            var section = "Path: \(path)\nKind: \(kind)"
            if kind == "update",
               let diff = extractString(change, keys: ["unified_diff"]),
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section += "\n\n```diff\n\(diff)\n```"
            } else if (kind == "add" || kind == "delete"),
                      let content = extractString(change, keys: ["content"]),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section += "\n\n```text\n\(content)\n```"
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    private func legacyPatchChanges(from rawChanges: Any?) -> [ConversationFileChangeEntry] {
        guard let changes = rawChanges as? [String: Any], !changes.isEmpty else { return [] }
        return changes.keys.sorted().compactMap { path in
            guard let change = changes[path] as? [String: Any] else { return nil }
            let kind = extractString(change, keys: ["type"]) ?? "update"
            let diff = extractString(change, keys: ["unified_diff", "content"]) ?? ""
            return ConversationFileChangeEntry(path: path, kind: kind, diff: diff)
        }
    }


    func syncActiveThreadFromServer() async {
        guard let key = activeThreadKey else { return }
        await syncThreadFromServer(key)
    }

    private func syncThreadFromServer(_ key: ThreadKey, force: Bool = false) async {
        guard let conn = connections[key.serverId], conn.isConnected,
              let thread = threads[key] else {
            if force {
                NSLog("[%@ sync] bail: server %@ connected=%d thread=%d", ts, key.serverId, connections[key.serverId]?.isConnected == true ? 1 : 0, threads[key] != nil ? 1 : 0)
                // Can't reach server — reset stuck thinking state so UI isn't frozen
                if let thread = threads[key], thread.hasTurnActive {
                    NSLog("[%@ sync] resetting %@ to ready (can't reach server)", ts, key.threadId)
                    thread.status = .ready
                    thread.activeTurnId = nil
                }
            }
            return
        }
        let wasActive = thread.hasTurnActive
        if !force && wasActive { return }

        let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd
        if force { NSLog("[%@ sync] resumeThread %@ (wasActive=%d)", ts, key.threadId, wasActive ? 1 : 0) }
        guard let response = try? await conn.resumeThread(
            threadId: key.threadId,
            cwd: cwd,
            approvalPolicy: "never",
            sandboxMode: "workspace-write"
        ) else {
            if force {
                NSLog("[%@ sync] resumeThread FAILED for %@, resetting to ready", ts, key.threadId)
                if wasActive {
                    thread.status = .ready
                    thread.activeTurnId = nil
                }
            }
            return
        }
        if force { NSLog("[%@ sync] resumeThread OK for %@, turns=%d", ts, key.threadId, Int(response.turnCount)) }

        // resumeThread re-subscribes to events. If a turn is still active,
        // the server will keep sending notifications. Don't reset status.
        if force {
            NSLog("[%@ sync] after resume: wasActive=%d hasTurnActive=%d", ts, wasActive ? 1 : 0, thread.hasTurnActive ? 1 : 0)
        }

        let restored = response.hydratedItems

        thread.cwd = response.cwd ?? thread.cwd
        thread.model = response.model ?? thread.model
        thread.modelProvider = response.modelProvider ?? response.model ?? thread.modelProvider
        thread.reasoningEffort = response.reasoningEffort ?? thread.reasoningEffort
        thread.rolloutPath = response.threadPath ?? thread.rolloutPath
        thread.parentThreadId = sanitizedLineageId(response.parentThreadId) ?? thread.parentThreadId
        thread.rootThreadId = sanitizedLineageId(response.rootThreadId) ?? thread.rootThreadId
        thread.agentNickname = sanitizedLineageId(response.agentNickname) ?? thread.agentNickname
        thread.agentRole = sanitizedLineageId(response.agentRole) ?? thread.agentRole
        scheduleThreadMetadataRefresh(for: key, cwd: response.cwd ?? thread.cwd)

        if !messagesEquivalent(thread.items, restored),
           !shouldPreferLocalMessages(current: thread.items, restored: restored) {
            let prepared = preparedRestoredMessages(
                restored,
                preservingIdentityFrom: thread.items
            )
            thread.items = prepared
            threadTurnCounts[key] = Int(response.turnCount)
        }

        upsertAgentDirectory(
            serverId: key.serverId,
            threadId: response.threadId,
            agentId: response.agentId,
            nickname: thread.agentNickname,
            role: thread.agentRole
        )
        thread.updatedAt = Date()
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
    }

    private func refreshThreadContextWindow(for key: ThreadKey, cwd: String) async {
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty,
              let conn = connections[key.serverId],
              conn.isConnected,
              let response = try? await conn.readConfig(cwd: normalizedCwd),
              let modelContextWindow = response.config.modelContextWindow,
              let thread = threads[key] else {
            return
        }

        thread.modelContextWindow = modelContextWindow
    }

    private func refreshPersistedContextUsage(for key: ThreadKey) async {
        guard let thread = threads[key],
              let conn = connections[key.serverId],
              conn.isConnected,
              conn.server.source != .local else {
            return
        }

        let rolloutPath = thread.rolloutPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rolloutPath.isEmpty else { return }

        let rolloutDirectory = URL(fileURLWithPath: rolloutPath).deletingLastPathComponent().path
        let shellScript = """
        line=$(awk '/"type":"token_count","info":\\{/{line=$0} END { if (line) print line }' "$1")
        [ -n "$line" ] || exit 0
        context=$(printf '%s\n' "$line" | sed -nE 's/.*"last_token_usage":\\{[^}]*"total_tokens":([0-9]+).*/\\1/p')
        if [ -z "$context" ]; then
            context=$(printf '%s\n' "$line" | sed -nE 's/.*"total_token_usage":\\{[^}]*"total_tokens":([0-9]+).*/\\1/p')
        fi
        window=$(printf '%s\n' "$line" | sed -nE 's/.*"model_context_window":([0-9]+).*/\\1/p')
        [ -n "$context$window" ] || exit 0
        printf '{"contextTokens":%s,"modelContextWindow":%s}\n' "${context:-null}" "${window:-null}"
        """

        guard let response = try? await conn.execCommand(
            ["/bin/sh", "-c", shellScript, "litter-rollout-usage", rolloutPath],
            cwd: rolloutDirectory
        ),
        response.exitCode == 0 else {
            return
        }

        let stdout = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty,
              let data = stdout.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(PersistedContextUsageSnapshot.self, from: data) else {
            return
        }

        if let modelContextWindow = snapshot.modelContextWindow {
            thread.modelContextWindow = modelContextWindow
        }
        if let contextTokens = snapshot.contextTokens {
            thread.contextTokensUsed = contextTokens
        }
    }

    private func scheduleThreadMetadataRefresh(
        for key: ThreadKey,
        cwd: String,
        delayNanoseconds: UInt64 = 250_000_000
    ) {
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty else {
            cancelThreadMetadataRefresh(for: key)
            return
        }

        cancelThreadMetadataRefresh(for: key)
        let token = UUID()
        deferredThreadMetadataRefreshTokens[key] = token
        deferredThreadMetadataRefreshTasks[key] = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }

            await self.refreshThreadContextWindow(for: key, cwd: normalizedCwd)
            guard !Task.isCancelled else { return }

            await self.refreshPersistedContextUsage(for: key)
            guard self.deferredThreadMetadataRefreshTokens[key] == token else { return }

            self.deferredThreadMetadataRefreshTasks[key] = nil
            self.deferredThreadMetadataRefreshTokens[key] = nil
        }
    }

    private func cancelThreadMetadataRefresh(for key: ThreadKey) {
        deferredThreadMetadataRefreshTasks[key]?.cancel()
        deferredThreadMetadataRefreshTasks[key] = nil
        deferredThreadMetadataRefreshTokens[key] = nil
    }

    private func rollbackDepthForItem(_ item: ConversationItem, in key: ThreadKey) throws -> Int {
        guard let selectedTurnIndex = item.sourceTurnIndex else {
            throw NSError(domain: "Litter", code: 1021, userInfo: [NSLocalizedDescriptionKey: "Message is missing turn metadata"])
        }
        let totalTurns = threadTurnCounts[key] ?? inferredTurnCount(from: threads[key]?.items ?? [])
        guard totalTurns > 0 else {
            throw NSError(domain: "Litter", code: 1022, userInfo: [NSLocalizedDescriptionKey: "No turn history available"])
        }
        guard selectedTurnIndex >= 0, selectedTurnIndex < totalTurns else {
            throw NSError(domain: "Litter", code: 1023, userInfo: [NSLocalizedDescriptionKey: "Message is outside available turn history"])
        }
        return max(totalTurns - selectedTurnIndex - 1, 0)
    }

    private func inferredTurnCount(from items: [ConversationItem]) -> Int {
        if let maxTurnIndex = items.compactMap(\.sourceTurnIndex).max() {
            return maxTurnIndex + 1
        }
        return items.filter { $0.isUserItem && $0.isFromUserTurnBoundary }.count
    }

    private func shouldPreferLocalMessages(current: [ConversationItem], restored: [ConversationItem]) -> Bool {
        // Only protect against fully empty/stale snapshots. Finalized local
        // realtime utterances are merged onto restored history separately.
        !current.isEmpty && restored.isEmpty
    }

    private func isMissingRolloutError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("no rollout found for thread id")
    }

    private func containsLocalRealtimeItems(_ items: [ConversationItem]) -> Bool {
        items.contains(where: isLocalRealtimeItem)
    }

    private func isLocalRealtimeItem(_ item: ConversationItem) -> Bool {
        item.id.hasPrefix("rtv-") || item.id.hasPrefix("rtv-handoff-") || item.id.hasPrefix("rtv-flush-")
    }

    private func mergeLocalRealtimeItems(current: [ConversationItem], restored: [ConversationItem]) -> [ConversationItem] {
        guard containsLocalRealtimeItems(current) else { return restored }

        var merged = restored
        var existingIDs = Set(restored.map(\.id))
        for item in current where isLocalRealtimeItem(item) {
            guard !existingIDs.contains(item.id) else { continue }
            merged.append(item)
            existingIDs.insert(item.id)
        }
        return merged
    }

    private func messagesEquivalent(_ lhs: [ConversationItem], _ rhs: [ConversationItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard sameRenderableMessage(left, right) else { return false }
        }
        return true
    }

    private func sameRenderableMessage(_ lhs: ConversationItem, _ rhs: ConversationItem) -> Bool {
        lhs.renderDigest == rhs.renderDigest
    }

    private func preparedRestoredMessages(
        _ restored: [ConversationItem],
        preservingIdentityFrom existing: [ConversationItem]
    ) -> [ConversationItem] {
        var prepared = restored
        for index in prepared.indices {
            guard index < existing.count,
                  sameRenderableMessage(existing[index], prepared[index]) else { continue }
            prepared[index] = existing[index]
        }
        return prepared
    }

    private func cancelDeferredMessageHydration(for key: ThreadKey) {
        deferredThreadMessageHydrationTasks[key]?.cancel()
        deferredThreadMessageHydrationTasks[key] = nil
    }

    private func installRestoredMessages(
        _ restored: [ConversationItem],
        on thread: ThreadState,
        key: ThreadKey,
        staged: Bool,
        preferLocalMessages: Bool = false
    ) {
        cancelDeferredMessageHydration(for: key)
        thread.requiresOpenHydration = false

        let effectiveRestored = preferLocalMessages
            ? mergeLocalRealtimeItems(current: thread.items, restored: restored)
            : restored

        if preferLocalMessages,
           shouldPreferLocalMessages(current: thread.items, restored: effectiveRestored) {
            return
        }

        let prepared = preparedRestoredMessages(
            effectiveRestored,
            preservingIdentityFrom: thread.items
        )

        guard staged, prepared.count > initialHydratedMessageCount else {
            thread.items = prepared
            return
        }

        let splitIndex = max(0, prepared.count - initialHydratedMessageCount)
        let olderMessages = Array(prepared[..<splitIndex])
        thread.items = Array(prepared[splitIndex...])

        guard !olderMessages.isEmpty else { return }

        deferredThreadMessageHydrationTasks[key] = Task { @MainActor [weak self, weak thread] in
            guard let self, let thread else { return }

            var nextEnd = olderMessages.count
            while nextEnd > 0 {
                if Task.isCancelled || self.threads[key] !== thread {
                    break
                }

                let nextStart = max(0, nextEnd - hydrationChunkSize)
                let chunk = Array(olderMessages[nextStart..<nextEnd])
                thread.items.insert(contentsOf: chunk, at: 0)
                nextEnd = nextStart

                if nextEnd > 0 {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }

            if self.deferredThreadMessageHydrationTasks[key]?.isCancelled == false {
                self.deferredThreadMessageHydrationTasks[key] = nil
            }
        }
    }

    private func resolveThreadKey(serverId: String, threadId: String?) -> ThreadKey {
        if let threadId {
            return ThreadKey(serverId: serverId, threadId: threadId)
        }
        if let active = activeThreadKey, active.serverId == serverId {
            return active
        }
        return threads.values
            .first { $0.serverId == serverId && $0.hasTurnActive }?
            .key ?? ThreadKey(serverId: serverId, threadId: "")
    }

    // MARK: - Background / Foreground Lifecycle

    func appDidEnterBackground() {
        guard activeVoiceSession == nil else { return }
        let activeTurnKeys = threads.compactMap { (key, thread) -> ThreadKey? in
            thread.hasTurnActive ? key : nil
        }
        NSLog("[%@ bg] entering background, activeTurnKeys=%d liveActivities=%d", ts, activeTurnKeys.count, liveActivities.count)

        guard !activeTurnKeys.isEmpty else { return }
        backgroundedTurnKeys = Set(activeTurnKeys)
        bgWakeCount = 0

        for key in activeTurnKeys {
            if liveActivities[key] == nil, let thread = threads[key] {
                startLiveActivity(key: key, model: thread.model, cwd: thread.cwd, prompt: thread.preview)
            }
        }

        registerPushProxy()

        let bgID = UIApplication.shared.beginBackgroundTask { [weak self] in
            NSLog("[bg] background task expiring")
            guard let self else { return }
            let expiredID = self.backgroundTaskID
            self.backgroundTaskID = .invalid
            UIApplication.shared.endBackgroundTask(expiredID)
        }
        backgroundTaskID = bgID
    }

    private func registerPushProxy() {
        guard let tokenData = devicePushToken else {
            NSLog("[%@ push] no device push token, skipping proxy register", ts)
            return
        }
        guard pushProxyRegistrationId == nil else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                let regId = try await pushProxy.register(pushToken: token, interval: 30, ttl: 7200)
                pushProxyRegistrationId = regId
                NSLog("[%@ push] registered → %@", ts, regId)
            } catch {
                NSLog("[%@ push] register failed: %@", ts, error.localizedDescription)
            }
        }
    }

    private func deregisterPushProxy() {
        guard let regId = pushProxyRegistrationId else { return }
        pushProxyRegistrationId = nil
        Task { try? await pushProxy.deregister(registrationId: regId) }
    }

    func appDidBecomeActive() {
        handlePendingVoiceSessionEndRequestIfNeeded()
        if activeVoiceSession != nil {
            deregisterPushProxy()
            endBackgroundTaskIfNeeded()
            return
        }
        NSLog("[%@ bg] becoming active, backgroundedTurnKeys=%d liveActivities=%d bgWakes=%d", ts, backgroundedTurnKeys.count, liveActivities.count, bgWakeCount)
        deregisterPushProxy()
        endBackgroundTaskIfNeeded()

        let keysToSync = backgroundedTurnKeys.union(
            threads.compactMap { $0.value.hasTurnActive ? $0.key : nil }
        )
        backgroundedTurnKeys.removeAll()

        Task {
            for (serverId, conn) in connections {
                // Skip connections that are still healthy (channel or WebSocket).
                if conn.connectionHealth == .connected {
                    NSLog("[%@ bg] skipping reconnect for healthy %@", ts, serverId)
                    continue
                }
                if conn.connectionHealth == .connecting {
                    NSLog("[%@ bg] skipping reconnect for connecting %@", ts, serverId)
                    continue
                }
                conn.connectionHealth = .connecting
                NSLog("[%@ bg] reconnecting server %@", ts, serverId)
                conn.disconnect()
                await conn.connect()
                if conn.connectionHealth == .connecting {
                    conn.connectionHealth = .disconnected
                }
            }

            // First pass: read-only sync to get clean state without event subscription
            for key in keysToSync {
                guard let conn = connections[key.serverId], conn.isConnected,
                      let thread = threads[key] else { continue }
                if let response = try? await conn.readThread(threadId: key.threadId) {
                    let restored = response.hydratedItems
                    installRestoredMessages(
                        restored,
                        on: thread,
                        key: key,
                        staged: false,
                        preferLocalMessages: true
                    )
                    if let cwd = response.cwd, !cwd.isEmpty { thread.cwd = cwd }
                    let turnDone = response.lastTurnStatus == "completed"
                        || response.lastTurnStatus == "failed"
                        || response.lastTurnStatus == "interrupted"
                    if turnDone {
                        thread.status = .ready
                        thread.activeTurnId = nil
                    }
                    NSLog("[%@ bg] read %@ msgs=%d lastStatus=%@", ts, key.threadId, restored.count, response.lastTurnStatus ?? "nil")
                }
            }

            // Second pass: resume threads that are still active to get live updates
            suppressNotifications = true
            for key in keysToSync where threads[key]?.hasTurnActive == true {
                await syncThreadFromServer(key, force: true)
            }
            if let activeKey = activeThreadKey, !keysToSync.contains(activeKey) {
                await syncThreadFromServer(activeKey, force: true)
            }
            suppressNotifications = false

            for key in liveActivities.keys {
                if threads[key]?.hasTurnActive != true {
                    endLiveActivity(key: key, phase: .completed)
                }
            }
        }
    }

    func handleBackgroundPush() async {
        bgWakeCount += 1
        let keys = backgroundedTurnKeys
        NSLog("[%@ push-wake] #%d keys=%d", ts, bgWakeCount, keys.count)
        guard !keys.isEmpty else { return }

        let serverIds = Set(keys.map(\.serverId))
        for serverId in serverIds {
            guard let conn = connections[serverId] else {
                NSLog("[%@ push-wake] no connection object for %@", ts, serverId)
                continue
            }
            if conn.connectionHealth == .connecting {
                NSLog("[%@ push-wake] server %@ already connecting, skipping reconnect", ts, serverId)
                continue
            }
            NSLog("[%@ push-wake] server %@ isConnected=%d, reconnecting", ts, serverId, conn.isConnected ? 1 : 0)
            conn.disconnect()
            await conn.connect()
            NSLog("[%@ push-wake] server %@ after connect: isConnected=%d", ts, serverId, conn.isConnected ? 1 : 0)
        }

        for key in keys {
            guard let conn = connections[key.serverId], conn.isConnected,
                  let thread = threads[key] else { continue }
            do {
                let response = try await conn.readThread(threadId: key.threadId)
                let restored = response.hydratedItems
                installRestoredMessages(
                    restored,
                    on: thread,
                    key: key,
                    staged: false,
                    preferLocalMessages: true
                )
                if let cwd = response.cwd, !cwd.isEmpty { thread.cwd = cwd }
                let lastTurnStatus = response.lastTurnStatus
                let turnCount = Int(response.turnCount)
                NSLog("[%@ push-wake] read %@ turns=%d lastStatus=%@ msgs=%d", ts, key.threadId, turnCount, lastTurnStatus ?? "nil", restored.count)
                let turnDone = lastTurnStatus == "completed" || lastTurnStatus == "failed" || lastTurnStatus == "interrupted"
                if turnDone {
                    thread.status = .ready
                    thread.activeTurnId = nil
                }

                if turnDone {
                    backgroundedTurnKeys.remove(key)
                    endLiveActivity(key: key, phase: .completed)
                    postLocalNotificationIfNeeded(model: thread.model, threadPreview: thread.preview)
                } else {
                    updateLiveActivityBGWake(key: key)
                }
            } catch {
                NSLog("[%@ push-wake] readThread failed for %@: %@", ts, key.threadId, error.localizedDescription)
            }
        }

        for serverId in serverIds {
            connections[serverId]?.disconnect()
        }

        if backgroundedTurnKeys.isEmpty {
            deregisterPushProxy()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Live Activity

    private func startLiveActivity(key: ThreadKey, model: String, cwd: String, prompt: String) {
        guard liveActivities[key] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[%@ la] start SKIP key=%@ (exists=%d enabled=%d)", ts, key.threadId, liveActivities[key] != nil ? 1 : 0, ActivityAuthorizationInfo().areActivitiesEnabled ? 1 : 0)
            return
        }
        let now = Date()
        let attributes = CodexTurnAttributes(threadId: key.threadId, model: model, cwd: cwd, startDate: now, prompt: String(prompt.prefix(120)))
        let state = CodexTurnAttributes.ContentState(phase: .thinking, elapsedSeconds: 0, toolCallCount: 0, activeThreadCount: 0, fileChangeCount: 0, contextPercent: 0)
        liveActivityStartDates[key] = now
        liveActivityToolCallCounts[key] = 0
        liveActivityFileChangeCounts[key] = 0
        do {
            liveActivities[key] = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            NSLog("[%@ la] STARTED key=%@ activityId=%@", ts, key.threadId, liveActivities[key]?.id ?? "nil")
        } catch {
            NSLog("[%@ la] FAILED to start: %@", ts, error.localizedDescription)
        }
    }

    private func updateLiveActivity(key: ThreadKey, phase: CodexTurnAttributes.ContentState.Phase, toolName: String? = nil) {
        guard let activity = liveActivities[key] else {
            NSLog("[%@ la] updatePhase SKIP key=%@ (no activity)", ts, key.threadId)
            return
        }
        if phase == .toolCall {
            liveActivityToolCallCounts[key, default: 0] += 1
        }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastUpdate = now - (liveActivityLastUpdateTimes[key] ?? 0)
        guard sinceLastUpdate > 2.0 else { return }
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: phase, toolName: toolName, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count, outputSnippet: liveActivityOutputSnippets[key], fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        liveActivityLastUpdateTimes[key] = now
        NSLog("[%@ la] UPDATE phase=%@ tool=%@ elapsed=%d", ts, phase.rawValue, toolName ?? "-", elapsed)
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func updateLiveActivityOutput(key: ThreadKey, thread: ThreadState) {
        guard let activity = liveActivities[key] else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastUpdate = now - (liveActivityLastUpdateTimes[key] ?? 0)
        guard sinceLastUpdate > 2.0 else { return }
        guard let lastAssistant = thread.items.last(where: \.isAssistantItem),
              let text = lastAssistant.assistantText else { return }
        let snippet = snippetText(text)
        guard !snippet.isEmpty, snippet != liveActivityOutputSnippets[key] else { return }
        liveActivityOutputSnippets[key] = snippet
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: .thinking, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count, outputSnippet: snippet, fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        liveActivityLastUpdateTimes[key] = now
        NSLog("[%@ la] UPDATE output elapsed=%d snippet=%@", ts, elapsed, String(snippet.prefix(40)))
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func endLiveActivity(key: ThreadKey, phase: CodexTurnAttributes.ContentState.Phase) {
        guard let activity = liveActivities[key] else {
            NSLog("[%@ la] END SKIP key=%@ (no activity)", ts, key.threadId)
            return
        }
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        NSLog("[%@ la] END key=%@ phase=%@ elapsed=%d activityId=%@", ts, key.threadId, phase.rawValue, elapsed, activity.id)
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: phase, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count - 1, fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 60))
        Task { await activity.end(content, dismissalPolicy: .after(.now + 4)) }
        liveActivities.removeValue(forKey: key)
        liveActivityStartDates.removeValue(forKey: key)
        liveActivityToolCallCounts.removeValue(forKey: key)
        liveActivityOutputSnippets.removeValue(forKey: key)
        liveActivityLastUpdateTimes.removeValue(forKey: key)
        liveActivityFileChangeCounts.removeValue(forKey: key)
    }

    private func updateLiveActivityBGWake(key: ThreadKey) {
        guard let activity = liveActivities[key] else { return }
        let thread = threads[key]
        // If session already completed, don't update the background timer.
        guard thread?.hasTurnActive == true else { return }
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))

        let toolCount = liveActivityToolCallCounts[key, default: 0]

        if let lastAssistant = thread?.items.last(where: { $0.isAssistantItem && !($0.assistantText ?? "").isEmpty }),
           let text = lastAssistant.assistantText {
            liveActivityOutputSnippets[key] = snippetText(text)
        }

        let phase: CodexTurnAttributes.ContentState.Phase = thread?.hasTurnActive == true ? .thinking : .completed
        let ctxPercent = contextPercent(for: key)

        let state = CodexTurnAttributes.ContentState(
            phase: phase,
            elapsedSeconds: elapsed,
            toolCallCount: toolCount,
            activeThreadCount: liveActivities.count,
            outputSnippet: liveActivityOutputSnippets[key],
            pushCount: bgWakeCount,
            fileChangeCount: liveActivityFileChangeCounts[key, default: 0],
            contextPercent: ctxPercent
        )
        NSLog("[%@ la] BG WAKE UPDATE #%d elapsed=%d tools=%d snippet=%@", ts, bgWakeCount, elapsed, toolCount, liveActivityOutputSnippets[key] ?? "nil")
        liveActivityLastUpdateTimes[key] = CFAbsoluteTimeGetCurrent()
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func snippetText(_ text: String) -> String {
        String(text.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func contextPercent(for key: ThreadKey) -> Int {
        guard let t = threads[key],
              let window = t.modelContextWindow, window > 0,
              let used = t.contextTokensUsed else { return 0 }
        return min(100, Int(Double(used) / Double(window) * 100))
    }

    private func endAllLiveActivities(phase: CodexTurnAttributes.ContentState.Phase) {
        for key in liveActivities.keys {
            endLiveActivity(key: key, phase: phase)
        }
    }

    // MARK: - Local Notifications

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postLocalNotificationIfNeeded(model: String, threadPreview: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Turn completed"
        var bodyParts: [String] = []
        if let preview = threadPreview, !preview.isEmpty { bodyParts.append(preview) }
        if !model.isEmpty { bodyParts.append(model) }
        content.body = bodyParts.joined(separator: " - ")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    func saveServerList() {
        let saved = connections.values.map { SavedServer.from($0.server) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedServersKey)
        }
    }

    func loadSavedServers() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }


    // MARK: - Conversation Restoration (now in RustConversationBridge)
    // restoredMessages/conversationItem/renderUserInput/decodeBase64DataURI/todoListSteps removed

    private func makeUserItem(
        text: String,
        images: [ChatImage] = [],
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        isBoundary: Bool,
        timestamp: Date = Date()
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            content: .user(ConversationUserMessageData(text: text, images: images)),
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isBoundary
        )
    }

    private func makeAssistantItem(
        id: String = UUID().uuidString,
        text: String,
        agentNickname: String?,
        agentRole: String?,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        timestamp: Date = Date()
    ) -> ConversationItem {
        ConversationItem(
            id: id,
            content: .assistant(
                ConversationAssistantMessageData(
                    text: text,
                    agentNickname: agentNickname,
                    agentRole: agentRole
                )
            ),
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp
        )
    }

    private func makeErrorItem(
        title: String = "Error",
        message: String,
        details: String? = nil,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        timestamp: Date = Date()
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            content: .error(ConversationSystemErrorData(title: title, message: message, details: details)),
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp
        )
    }

    private func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    private func stringifyValue(_ value: Any) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let json = prettyJSON(value) {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
