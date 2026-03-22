import Foundation
import Observation
import SwiftUI

enum ConnectionHealth: Equatable {
    case disconnected
    case connecting
    case connected
    case unresponsive

    var settingsLabel: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unresponsive: "Unresponsive"
        }
    }

    var settingsColor: Color {
        switch self {
        case .connected: LitterTheme.accent
        case .connecting, .unresponsive: .orange
        case .disconnected: LitterTheme.textSecondary
        }
    }
}

@MainActor
@Observable
final class ServerConnection: Identifiable {
    private static let defaultSandboxMode = "workspace-write"
    private static let localSandboxMode = "danger-full-access"
    private static let fallbackSandboxMode = "danger-full-access"

    let id: String
    let server: DiscoveredServer
    let target: ConnectionTarget

    var connectionHealth: ConnectionHealth = .disconnected
    var isConnected: Bool { connectionHealth == .connected }
    var connectionPhase: String = ""
    var authStatus: AuthStatus = .unknown
    var hasOpenAIApiKey = false
    var oauthURL: URL? = nil
    var lastAuthError: String?
    var isChatGPTLoginInProgress = false
    var loginCompleted = false {
        didSet {
            guard loginCompleted else { return }
            onLoginCompleted?()
        }
    }
    var models: [Model] = []
    var modelsLoaded = false
    var rateLimits: RateLimitSnapshot?

    @ObservationIgnored private(set) var codexClient: CodexClient? = CodexSharedClient.shared
    @ObservationIgnored private var rustServerId: String?
    @ObservationIgnored private var sshSessionId: String?
    @ObservationIgnored private var serverURL: URL?
    @ObservationIgnored private var pendingLoginId: String?

    @ObservationIgnored var onTypedEvent: ((UiEvent) -> Void)?
    @ObservationIgnored var onServerRequest: ((_ requestId: String, _ method: String, _ data: Data) -> Bool)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var onLoginCompleted: (() -> Void)?

    init(server: DiscoveredServer, target: ConnectionTarget) {
        self.id = server.id
        self.server = server
        self.target = target
        self.hasOpenAIApiKey = Self.localRealtimeAPIKeyIsSaved(for: target)
    }

    private struct ConnectionRetryPolicy {
        let maxAttempts: Int
        let retryDelay: Duration
        let initializeTimeout: Duration
        let attemptTimeout: Duration
    }

    func connect() async {
        guard connectionHealth != .connected, connectionHealth != .connecting else { return }
        connectionHealth = .connecting
        connectionPhase = "start"
        do {
            guard let client = codexClient else {
                connectionPhase = "client-init-failed"
                connectionHealth = .disconnected
                return
            }

            switch target {
            case .local:
                connectionPhase = "local-channel-starting"
                let assignedId = try await client.connectLocal(serverId: id, displayName: server.name, host: "127.0.0.1", port: 0)
                rustServerId = assignedId
                connectionPhase = "local-channel-setup"
                startEventPolling(client)
                connectionHealth = .connected
                connectionPhase = "ready"
                return
            case .remote(let host, let port):
                guard let url = websocketURL(host: host, port: port) else {
                    connectionPhase = "invalid-url"
                    connectionHealth = .disconnected
                    return
                }
                serverURL = url
                connectionPhase = "remote-url"
            case .remoteURL(let url):
                serverURL = url
                connectionPhase = "remote-url"
            case .sshThenRemote(let host, let credentials):
                connectionPhase = "ssh-bootstrap"
                let bootstrap = try await sshConnectAndBootstrap(
                    client: client,
                    host: host,
                    credentials: credentials
                )
                sshSessionId = bootstrap.sessionId
                let targetHost = server.sshPortForwardingEnabled
                    ? "127.0.0.1"
                    : bootstrap.normalizedHost
                let targetPort = server.sshPortForwardingEnabled
                    ? bootstrap.tunnelLocalPort ?? bootstrap.serverPort
                    : bootstrap.serverPort
                guard let url = websocketURL(host: targetHost, port: targetPort) else {
                    connectionPhase = "invalid-url"
                    connectionHealth = .disconnected
                    return
                }
                serverURL = url
                connectionPhase = "remote-url"
            }
            guard serverURL != nil else {
                connectionPhase = "no-url"
                connectionHealth = .disconnected
                return
            }
            connectionPhase = "setup-events"
            startEventPolling(client)
            connectionPhase = "connect-and-initialize"
            try await connectAndInitialize(client: client)
            connectionHealth = .connected
            connectionPhase = "ready"
            Task { [weak self] in
                await self?.checkAuth()
                await self?.fetchRateLimits()
            }
        } catch {
            eventPollTask?.cancel()
            eventPollTask = nil
            eventSubscription = nil
            if let serverId = rustServerId, let client = codexClient {
                client.disconnectServer(serverId: serverId)
            }
            if let sessionId = sshSessionId, let client = codexClient {
                try? await client.sshClose(sessionId: sessionId)
            }
            rustServerId = nil
            sshSessionId = nil
            connectionPhase = "error: \(error.localizedDescription)"
            connectionHealth = .disconnected
            serverURL = nil
        }
    }

    func disconnect() {
        eventPollTask?.cancel()
        eventPollTask = nil
        eventSubscription = nil
        if let client = codexClient {
            let serverId = rustServerId
            let sshSessionId = sshSessionId
            if let serverId {
                client.disconnectServer(serverId: serverId)
            }
            if let sshSessionId {
                Task { try? await client.sshClose(sessionId: sshSessionId) }
            }
        }
        rustServerId = nil
        sshSessionId = nil
        connectionHealth = .disconnected
        serverURL = nil
        rateLimits = nil
        oauthURL = nil
        pendingLoginId = nil
        lastAuthError = nil
        isChatGPTLoginInProgress = false
    }

    func forwardOAuthCallback(_ url: URL) {
        switch target {
        case .local:
            Task { _ = try? await URLSession.shared.data(from: url) }
        case .remote, .remoteURL, .sshThenRemote:
            Task {
                _ = try? await execCommand(["curl", "-s", "-4", "-L", "--max-time", "10", url.absoluteString])
            }
        }
    }

    // MARK: - RPC Methods

    private func requireRustServerId(_ explicitServerId: String? = nil) throws -> String {
        if let explicitServerId, !explicitServerId.isEmpty {
            return explicitServerId
        }
        guard let rustServerId, !rustServerId.isEmpty else {
            throw ClientError.Transport("Server session unavailable")
        }
        return rustServerId
    }

    func listThreads(cwd: String? = nil, cursor: String? = nil, limit: Int? = 20) async throws -> [ThreadInfo] {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.listThreads(serverId: try requireRustServerId())
    }

    func startThread(
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil,
        dynamicTools: [DynamicToolSpecParams]? = nil
    ) async throws -> ThreadKey {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await startThread(
                cwd: cwd,
                model: model,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox,
                dynamicTools: dynamicTools
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await startThread(
                cwd: cwd,
                model: model,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode,
                dynamicTools: dynamicTools
            )
        }
    }

    func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadResponseWithHydration {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode
            )
        }
    }

    func forkThread(
        threadId: String,
        cwd: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadResponseWithHydration {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await forkThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await forkThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode
            )
        }
    }

    private func startThread(cwd: String, model: String?, approvalPolicy: String, sandbox: String, dynamicTools: [DynamicToolSpecParams]? = nil) async throws -> ThreadKey {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        let instructions = target == .local ? Self.localSystemInstructions : nil
        let typedTools: [DynamicToolSpec]? = try dynamicTools?.map { spec in
            DynamicToolSpec(
                name: spec.name,
                description: spec.description,
                inputSchema: try JsonValue(encodable: spec.inputSchema),
                deferLoading: false
            )
        }
        return try await client.rpcThreadStart(
            serverId: try requireRustServerId(),
            model: model, cwd: cwd,
            approvalPolicy: AskForApproval(wireValue: approvalPolicy),
            sandbox: SandboxMode(wireValue: sandbox),
            developerInstructions: instructions,
            dynamicTools: typedTools,
            persistExtendedHistory: true
        )
    }

    func readThread(threadId: String) async throws -> ThreadResponseWithHydration {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcThreadReadHydrated(
            serverId: try requireRustServerId(),
            threadId: threadId
        )
    }

    private func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String,
        sandbox: String
    ) async throws -> ThreadResponseWithHydration {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        let instructions = target == .local ? Self.localSystemInstructions : nil
        return try await client.rpcThreadResumeHydrated(
            serverId: try requireRustServerId(),
            threadId: threadId, cwd: cwd,
            approvalPolicy: AskForApproval(wireValue: approvalPolicy),
            sandbox: SandboxMode(wireValue: sandbox),
            developerInstructions: instructions
        )
    }

    private func forkThread(
        threadId: String,
        cwd: String?,
        approvalPolicy: String,
        sandbox: String
    ) async throws -> ThreadResponseWithHydration {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        let instructions = target == .local ? Self.localSystemInstructions : nil
        return try await client.rpcThreadForkHydrated(
            serverId: try requireRustServerId(),
            threadId: threadId, cwd: cwd,
            approvalPolicy: AskForApproval(wireValue: approvalPolicy),
            sandbox: SandboxMode(wireValue: sandbox),
            developerInstructions: instructions
        )
    }

    private func shouldRetryWithoutLinuxSandbox(_ error: Error) -> Bool {
        let message: String
        if case ClientError.Rpc(let msg) = error {
            message = msg
        } else {
            return false
        }
        let lower = message.lowercased()
        return lower.contains("codex-linux-sandbox was required but not provided") ||
            lower.contains("missing codex-linux-sandbox executable path")
    }

    func sendTurn(
        threadId: String,
        text: String,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil,
        additionalInput: [UserInput] = []
    ) async throws -> Void {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        let inputs = ConversationAttachmentSupport.buildTurnInputs(text: text, additionalInput: additionalInput)
        guard !inputs.isEmpty else {
            throw NSError(
                domain: "Litter",
                code: 1020,
                userInfo: [NSLocalizedDescriptionKey: "Cannot send an empty turn"]
            )
        }
        let sandboxPolicyJson: String? = TurnSandboxPolicy(mode: sandboxMode).flatMap { policy in
            try? String(data: JSONEncoder().encode(policy), encoding: .utf8)
        }
        return try await client.rpcTurnStart(
            serverId: try requireRustServerId(),
            threadId: threadId, input: inputs,
            approvalPolicy: approvalPolicy.flatMap(AskForApproval.init(wireValue:)),
            sandboxPolicyJson: sandboxPolicyJson,
            model: model,
            effort: effort.flatMap(ReasoningEffort.init(wireValue:)),
            serviceTier: serviceTier.flatMap(ServiceTier.init(wireValue:))
        )
    }

    func interrupt(threadId: String, turnId: String) async {
        guard let client = codexClient else { return }
        try? await client.rpcTurnInterrupt(
            serverId: try requireRustServerId(),
            threadId: threadId, turnId: turnId
        )
    }

    func startRealtimeConversation(threadId: String, prompt: String, sessionId: String? = nil, clientControlledHandoff: Bool = false) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeStart(
            serverId: try requireRustServerId(),
            threadId: threadId, prompt: prompt,
            sessionId: sessionId, clientControlledHandoff: clientControlledHandoff
        )
    }

    func appendRealtimeAudio(threadId: String, audio: ThreadRealtimeAudioChunk) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeAppendAudio(
            serverId: try requireRustServerId(),
            threadId: threadId, audioData: audio.data,
            sampleRate: audio.sampleRate, numChannels: audio.numChannels,
            samplesPerChannel: audio.samplesPerChannel
        )
    }

    func appendRealtimeText(threadId: String, text: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeAppendText(
            serverId: try requireRustServerId(),
            threadId: threadId, text: text
        )
    }

    func stopRealtimeConversation(threadId: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeStop(
            serverId: try requireRustServerId(),
            threadId: threadId
        )
    }

    func resolveRealtimeHandoff(threadId: String, handoffId: String, outputText: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeResolveHandoff(
            serverId: try requireRustServerId(),
            threadId: threadId, handoffId: handoffId, outputText: outputText
        )
    }

    func finalizeRealtimeHandoff(threadId: String, handoffId: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcRealtimeFinalizeHandoff(
            serverId: try requireRustServerId(),
            threadId: threadId, handoffId: handoffId
        )
    }

    func rollbackThread(threadId: String, numTurns: Int) async throws -> ThreadResponseWithHydration {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcThreadRollbackHydrated(
            serverId: try requireRustServerId(),
            threadId: threadId, numTurns: UInt32(numTurns)
        )
    }

    func archiveThread(threadId: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcThreadArchive(
            serverId: try requireRustServerId(),
            threadId: threadId
        )
    }

    func listModels() async throws -> ModelListResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcModelList(
            serverId: try requireRustServerId(),
            limit: 50, includeHidden: false
        )
    }

    func execCommand(_ command: [String], cwd: String? = nil) async throws -> CommandExecResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcCommandExec(
            serverId: try requireRustServerId(),
            command: command, cwd: cwd
        )
    }

    func fuzzyFileSearch(query: String, roots: [String], cancellationToken: String?) async throws -> FuzzyFileSearchResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcFuzzyFileSearch(
            serverId: try requireRustServerId(),
            query: query, roots: roots, cancellationToken: cancellationToken
        )
    }

    func listSkills(cwds: [String]?, forceReload: Bool = false) async throws -> SkillsListResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcSkillsList(
            serverId: try requireRustServerId(),
            cwds: cwds, forceReload: forceReload
        )
    }

    // respondToServerRequest is defined in the Transport section below

    func listExperimentalFeatures(serverId: String? = nil, cursor: String? = nil, limit: Int? = 100) async throws -> ExperimentalFeatureListResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcExperimentalFeatureList(
            serverId: try requireRustServerId(serverId),
            cursor: cursor, limit: limit.map { UInt32($0) }
        )
    }

    func readConfig(serverId: String? = nil, cwd: String?) async throws -> ConfigReadResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcConfigRead(
            serverId: try requireRustServerId(serverId),
            cwd: cwd
        )
    }

    func writeConfigValue<Value: Encodable>(
        serverId: String? = nil,
        keyPath: String,
        value: Value,
        mergeStrategy: MergeStrategy = .upsert
    ) async throws -> ConfigWriteResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcConfigValueWrite(
            serverId: try requireRustServerId(serverId),
            keyPath: keyPath,
            value: try JsonValue(encodable: value),
            mergeStrategy: mergeStrategy
        )
    }

    func writeConfigBatch(
        serverId: String? = nil,
        edits: [ConfigEdit],
        reloadUserConfig: Bool = false
    ) async throws -> ConfigWriteResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcConfigBatchWrite(
            serverId: try requireRustServerId(serverId),
            edits: edits,
            reloadUserConfig: reloadUserConfig
        )
    }

    @discardableResult
    func setExperimentalFeature(
        serverId: String? = nil,
        named featureName: String,
        enabled: Bool,
        reloadUserConfig: Bool = true
    ) async throws -> ConfigWriteResponse {
        return try await writeConfigBatch(
            serverId: serverId,
            edits: [
                ConfigEdit(
                    keyPath: "features.\(featureName)",
                    value: try JsonValue(encodable: enabled),
                    mergeStrategy: .upsert
                )
            ],
            reloadUserConfig: reloadUserConfig
        )
    }

    func setThreadName(threadId: String, name: String) async throws {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        try await client.rpcThreadSetName(
            serverId: try requireRustServerId(),
            threadId: threadId, name: name
        )
    }

    func startReview(threadId: String) async throws -> ReviewStartResponse {
        guard let client = codexClient else { throw ClientError.Transport("Not connected") }
        return try await client.rpcReviewStart(
            serverId: try requireRustServerId(),
            threadId: threadId
        )
    }

    // MARK: - Auth

    func checkAuth() async {
        guard let client = codexClient else {
            authStatus = .notLoggedIn
            return
        }
        do {
            let resp: GetAccountResponse = try await withThrowingTaskGroup(of: GetAccountResponse.self) { group in
                group.addTask {
                    try await client.rpcAccountRead(
                        serverId: try self.requireRustServerId(),
                        refreshToken: false
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            if let account = resp.account {
                switch account {
                case .chatgpt(let email, _):
                    authStatus = .chatgpt(email: email)
                case .apiKey:
                    authStatus = .apiKey
                }
            } else {
                authStatus = .notLoggedIn
            }
            hasOpenAIApiKey = Self.realtimeAPIKeyIsSaved(for: target)
        } catch {
            authStatus = .notLoggedIn
            hasOpenAIApiKey = Self.realtimeAPIKeyIsSaved(for: target)
        }
    }

    func getAuthToken() async -> (method: String?, token: String?) {
        guard let client = codexClient else { return (nil, nil) }
        do {
            let resp = try await client.rpcGetAuthStatus(
                serverId: try requireRustServerId(),
                includeToken: true, refreshToken: false
            )
            return (Self.authModeName(resp.authMethod), resp.authToken)
        } catch {
            return (nil, nil)
        }
    }

    func loginWithChatGPT() async {
        guard let client = codexClient else { return }
        guard !isChatGPTLoginInProgress else { return }
        isChatGPTLoginInProgress = true
        defer { isChatGPTLoginInProgress = false }

        await checkAuth()
        guard authStatus == .notLoggedIn else { return }

        do {
            lastAuthError = nil
            oauthURL = nil
            pendingLoginId = nil
            let tokens = try await ChatGPTOAuth.login()
            _ = try await client.rpcLoginStartChatgptAuthTokens(
                serverId: try requireRustServerId(),
                accessToken: tokens.accessToken,
                chatgptAccountId: tokens.accountID,
                chatgptPlanType: tokens.planType
            )
            await checkAuth()
        } catch ChatGPTOAuthError.cancelled {
            return
        } catch {
            lastAuthError = error.localizedDescription
            NSLog("[auth] ChatGPT login failed: %@", error.localizedDescription)
        }
    }

    func loginWithApiKey(_ key: String) async {
        guard let client = codexClient else { return }
        do {
            lastAuthError = nil
            _ = try await client.rpcLoginStartApiKey(
                serverId: try requireRustServerId(),
                apiKey: key
            )
            await checkAuth()
        } catch {
            lastAuthError = error.localizedDescription
        }
    }

    func logout() async {
        try? ChatGPTOAuthTokenStore.shared.clear()
        if let client = codexClient {
            try? await client.rpcAccountLogout(serverId: try requireRustServerId())
        }
        authStatus = .notLoggedIn
        lastAuthError = nil
        oauthURL = nil
        pendingLoginId = nil
        isChatGPTLoginInProgress = false
    }

    func cancelLogin() async {
        guard let loginId = pendingLoginId else { return }
        if let client = codexClient {
            try? await client.rpcAccountLoginCancel(
                serverId: try requireRustServerId(),
                loginId: loginId
            )
        }
        pendingLoginId = nil
        oauthURL = nil
    }

    // MARK: - Rate Limits

    func fetchRateLimits() async {
        guard let client = codexClient else { return }
        guard let resp = try? await client.rpcAccountRateLimitsRead(
            serverId: try requireRustServerId()
        ) else { return }
        rateLimits = resp.rateLimits
    }

    // MARK: - Account Notifications

    func handleAccountNotification(method: String, data: Data) {
        guard let params = try? JSONSerialization.jsonObject(with: extractParams(data)) else { return }
        handleAccountNotificationFromParams(method: method, params: params)
    }

    func handleAccountNotificationFromParams(method: String, params: Any) {
        switch method {
        case "account/login/completed":
            let paramsDict = params as? [String: Any] ?? [:]
            let success = (paramsDict["success"] as? Bool) ?? false
            handleAccountLoginCompleted(
                AccountLoginCompletedNotification(
                    loginId: paramsDict["loginId"] as? String,
                    success: success,
                    error: paramsDict["error"] as? String
                )
            )
        case "account/updated":
            handleAccountUpdated(
                AccountUpdatedNotification(
                    authMode: Self.authMode(from: (params as? [String: Any])?["authMode"] as? String),
                    planType: PlanType(wireValue: (params as? [String: Any])?["planType"] as? String)
                )
            )
        case "account/rateLimits/updated":
            if let rateLimits = extractRateLimitSnapshot(params: params) {
                handleAccountRateLimitsUpdated(AccountRateLimitsUpdatedNotification(rateLimits: rateLimits))
            }
        default:
            break
        }
    }

    func handleAccountLoginCompleted(_ notification: AccountLoginCompletedNotification) {
        oauthURL = nil
        pendingLoginId = nil
        isChatGPTLoginInProgress = false
        if notification.success {
            lastAuthError = nil
            loginCompleted = true
            Task { await self.checkAuth() }
        } else {
            lastAuthError = notification.error ?? "ChatGPT login failed."
        }
    }

    func handleAccountUpdated(_ notification: AccountUpdatedNotification) {
        _ = notification
        lastAuthError = nil
        Task { await self.checkAuth() }
    }

    func handleAccountRateLimitsUpdated(_ notification: AccountRateLimitsUpdatedNotification) {
        rateLimits = notification.rateLimits
    }

    private func extractRateLimitSnapshot(params: Any) -> RateLimitSnapshot? {
        guard let paramsDict = params as? [String: Any],
              let rateLimits = paramsDict["rateLimits"] as? [String: Any] else {
            return nil
        }

        func window(from value: Any?) -> RateLimitWindow? {
            guard let dict = value as? [String: Any] else { return nil }
            let usedPercent = Int32((dict["usedPercent"] as? NSNumber)?.int32Value ?? 0)
            let windowDurationMins = (dict["windowDurationMins"] as? NSNumber)?.int64Value
            let resetsAt = (dict["resetsAt"] as? NSNumber)?.int64Value
            return RateLimitWindow(
                usedPercent: usedPercent,
                windowDurationMins: windowDurationMins,
                resetsAt: resetsAt
            )
        }

        let credits: CreditsSnapshot? = {
            guard let dict = rateLimits["credits"] as? [String: Any] else { return nil }
            return CreditsSnapshot(
                hasCredits: (dict["hasCredits"] as? Bool) ?? false,
                unlimited: (dict["unlimited"] as? Bool) ?? false,
                balance: dict["balance"] as? String
            )
        }()

        return RateLimitSnapshot(
            limitId: rateLimits["limitId"] as? String,
            limitName: rateLimits["limitName"] as? String,
            primary: window(from: rateLimits["primary"]),
            secondary: window(from: rateLimits["secondary"]),
            credits: credits,
            planType: PlanType(wireValue: rateLimits["planType"] as? String)
        )
    }

    private static func authModeName(_ mode: AuthMode?) -> String? {
        switch mode {
        case .apiKey:
            return "apiKey"
        case .chatgpt:
            return "chatgpt"
        case .chatgptAuthTokens:
            return "chatgptAuthTokens"
        case nil:
            return nil
        }
    }

    private static func authMode(from raw: String?) -> AuthMode? {
        switch raw {
        case "apiKey":
            return .apiKey
        case "chatgpt":
            return .chatgpt
        case "chatgptAuthTokens":
            return .chatgptAuthTokens
        default:
            return nil
        }
    }

    // MARK: - Local System Instructions

    private static let localSystemInstructions = """
    You are running on an iOS device with limited shell capabilities via ios_system.

    Environment:
    - Working directory: /home/codex (inside the app's sandboxed filesystem — persistent across app launches)
    - Filesystem layout: ~/Documents acts as root with /home/codex, /tmp, /var/log, /etc
    - Shell: ios_system (in-process, not a full POSIX shell — no fork/exec)
    - If you need a shell wrapper, the executable itself must be `sh`.
    - Use `sh -c '...'` directly. Do NOT emit `/bin/bash`, `bash`, `/bin/zsh`, `zsh`, `/bin/sh -lc`, or nested wrappers like `/bin/bash -lc "sh -c '...'"`.
    - /bin/sh runs in-process — compound commands (&&, ||, pipes) work

    Available tools:
    - Shell: ls, cat, echo, touch, cp, mv, rm, mkdir, rmdir, pwd, chmod, ln, du, df, env, date, uname, whoami, which, true, false, yes, printenv, basename, dirname, realpath, readlink
    - Text: grep, sed, awk, wc, sort, uniq, head, tail, tr, tee, cut, paste, comm, diff, expand, unexpand, fold, fmt, nl, rev, strings
    - Files: find, stat, tar, xargs
    - Network: curl (full HTTP client), ssh, scp, sftp
    - Git: lg2 (libgit2 CLI — use `lg2` instead of `git`, supports clone, init, add, commit, push, pull, status, log, diff, branch, checkout, merge, remote, tag, stash)
    - Other: bc (calculator)

    Limitations:
    - apply_patch may fail with "Operation not permitted" — fall back to echo/cat with redirection.
    - Use RELATIVE paths, not absolute /var/mobile/Containers/... paths.
    - Container UUID changes between installs — absolute paths from previous sessions are invalid.
    - No package managers (npm, pip, brew) and no Python/Node.
    - Use `lg2` not `git` for git operations.
    - Commands run synchronously — avoid long-running operations.

    Best practices:
    - Use relative paths for all file operations.
    - Prefer direct argv commands like `pwd`, `find`, `ls`, `rg`, `sed`.
    - Only wrap with `sh -c '...'` when shell syntax is actually required.
    - Never prepend `sh -c` with `bash -lc` or `zsh -lc`.
    - Prefer simple, single commands over complex pipelines.
    - For file creation: try apply_patch first, fall back to echo/cat redirection.
    - For scripting: use shell scripts or awk.
    - Be concise — this is a mobile device.
    """

    // MARK: - Transport (UniFFI CodexClient)

    /// Respond to a server request.
    func respondToServerRequest(id: String, result: [String: Any]) {
        guard let client = codexClient else { return }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let resultJson = String(data: data, encoding: .utf8) {
            Task { try? await client.rpcRespond(serverId: try self.requireRustServerId(), requestId: id, resultJson: resultJson) }
        }
    }

    /// Reject a server request with a JSON-RPC error.
    func respondToServerRequestError(id: String, message: String, code: Int32 = -32_000) {
        guard let client = codexClient else { return }
        Task {
            try? await client.rpcRespondError(
                serverId: try self.requireRustServerId(),
                requestId: id,
                code: code,
                message: message
            )
        }
    }

    /// Poll for events from the async CodexClient.
    @ObservationIgnored private var eventPollTask: Task<Void, Never>?
    @ObservationIgnored private var eventSubscription: EventSubscription?

    private func startEventPolling(_ client: CodexClient) {
        eventPollTask?.cancel()
        let subscription = client.subscribeEvents()
        eventSubscription = subscription
        eventPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let event = try await subscription.nextEvent()
                    guard let self else { break }
                    self.handleEvent(event)
                } catch {
                    break
                }
            }
        }
    }

    /// Process a typed event from the Rust layer (UniFFI-generated UiEvent enum).
    private func handleEvent(_ event: UiEvent) {
        switch event {
        case .connectionStateChanged(serverId: _, health: let health):
            switch health {
            case "connected":
                if connectionHealth == .connecting || connectionHealth == .unresponsive { connectionHealth = .connected }
            case "disconnected":
                if connectionHealth == .connected || connectionHealth == .unresponsive {
                    connectionHealth = .disconnected
                    onDisconnect?()
                }
            case "unresponsive":
                if connectionHealth == .connected { connectionHealth = .unresponsive }
            case "reconnecting":
                connectionHealth = .connecting
            default: break
            }
        default:
            onTypedEvent?(event)
        }
    }

    // MARK: - Connection Internals

    private func websocketURL(host: String, port: UInt16) -> URL? {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains(":"), let pct = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<pct])
        }
        if normalized.contains(":") {
            let unbracketed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let escapedScope = unbracketed.replacingOccurrences(of: "%25", with: "%")
                .replacingOccurrences(of: "%", with: "%25")
            return URL(string: "ws://[\(escapedScope)]:\(port)")
        }
        return URL(string: "ws://\(normalized):\(port)")
    }

    private func connectAndInitialize(client: CodexClient) async throws {
        guard let url = serverURL else { throw URLError(.badURL) }
        let policy = retryPolicy()
        var lastError: Error = URLError(.cannotConnectToHost)
        for attempt in 0..<policy.maxAttempts {
            connectionPhase = "attempt \(attempt + 1)/\(policy.maxAttempts)"
            if attempt > 0 {
                try await Task.sleep(for: policy.retryDelay)
            }
            do {
                try await connectAndInitializeOnce(
                    client: client, url: url, attemptTimeout: policy.attemptTimeout
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func retryPolicy() -> ConnectionRetryPolicy {
        switch target {
        case .remote, .remoteURL:
            return ConnectionRetryPolicy(
                maxAttempts: 3,
                retryDelay: .milliseconds(300),
                initializeTimeout: .seconds(4),
                attemptTimeout: .seconds(5)
            )
        default:
            return ConnectionRetryPolicy(
                maxAttempts: 30,
                retryDelay: .milliseconds(800),
                initializeTimeout: .seconds(6),
                attemptTimeout: .seconds(12)
            )
        }
    }

    private func connectAndInitializeOnce(
        client: CodexClient,
        url: URL,
        attemptTimeout: Duration
    ) async throws {
        let host = url.host ?? "127.0.0.1"
        let port = UInt16(url.port ?? 80)
        let connId = self.id
        let displayName = self.server.name
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await MainActor.run { self.connectionPhase = "client-connect" }
                let assignedId = try await client.connectRemote(
                    serverId: connId, displayName: displayName,
                    host: host, port: port
                )
                await MainActor.run {
                    self.rustServerId = assignedId
                    self.connectionPhase = "initialized"
                }
            }
            group.addTask {
                try await Task.sleep(for: attemptTimeout)
                throw URLError(.timedOut)
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    private func sshConnectAndBootstrap(
        client: CodexClient,
        host: String,
        credentials: SSHCredentials
    ) async throws -> FfiSshConnectionResult {
        switch credentials {
        case .password(let username, let password):
            return try await client.sshConnectAndBootstrap(
                host: host,
                port: server.resolvedSSHPort,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                acceptUnknownHost: true,
                workingDir: nil
            )
        case .key(let username, let privateKey, let passphrase):
            return try await client.sshConnectAndBootstrap(
                host: host,
                port: server.resolvedSSHPort,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                acceptUnknownHost: true,
                workingDir: nil
            )
        }
    }

    private func extractParams(_ data: Data) -> Data {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = obj["params"] {
            return (try? JSONSerialization.data(withJSONObject: params)) ?? data
        }
        return data
    }

}
