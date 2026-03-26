import SwiftUI
import Charts

struct ConversationInfoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let threadKey: ThreadKey
    var onOpenWallpaper: (() -> Void)?
    var onOpenConversation: ((ThreadKey) -> Void)?

    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var stats: ConversationStatistics = .init()
    @State private var serverUsage: ServerUsageData = .init()

    private var thread: AppThreadSnapshot? {
        appModel.snapshot?.threads.first { $0.key == threadKey }
    }

    private var server: AppServerSnapshot? {
        guard let serverId = thread?.key.serverId ?? Optional(threadKey.serverId) else { return nil }
        return appModel.snapshot?.servers.first { $0.serverId == serverId }
    }

    private var allServerThreads: [AppThreadSnapshot] {
        guard let snapshot = appModel.snapshot else { return [] }
        return snapshot.threads.filter { $0.key.serverId == threadKey.serverId }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                threadDetailsSection
                contextWindowSection
                conversationStatsSection
                serverChartsSection
                serverInfoSection
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(LitterTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Conversation Info")
                    .litterFont(size: 16, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
        .onAppear { computeData() }
        .onChange(of: thread?.hydratedConversationItems.count) { computeData() }
    }

    // MARK: - Section A: Thread Details

    private var threadDetailsSection: some View {
        VStack(spacing: 12) {
            // Title
            Text(thread?.info.title ?? "Untitled")
                .litterFont(size: 24, weight: .bold)
                .foregroundStyle(LitterTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Model + reasoning
            HStack(spacing: 8) {
                if let model = thread?.model ?? thread?.info.model {
                    Text(model)
                        .litterFont(size: 13, weight: .medium)
                        .foregroundStyle(LitterTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .modifier(GlassRectModifier(cornerRadius: 6))
                }
                if let effort = thread?.reasoningEffort {
                    Text("reasoning: \(effort)")
                        .litterFont(size: 12, weight: .regular)
                        .foregroundStyle(LitterTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .modifier(GlassRectModifier(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Working directory
            if let cwd = thread?.info.cwd {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(LitterTheme.textMuted)
                    Text(cwd)
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Timestamps
            HStack(spacing: 16) {
                if let created = thread?.info.createdAt {
                    timestampLabel("Created", timestamp: created)
                }
                if let updated = thread?.info.updatedAt {
                    timestampLabel("Updated", timestamp: updated)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .litterFont(size: 12)
                    .foregroundStyle(LitterTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func timestampLabel(_ label: String, timestamp: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .litterFont(size: 10, weight: .medium)
                .foregroundStyle(LitterTheme.textMuted)
            Text(relativeTimestamp(timestamp))
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textSecondary)
        }
    }

    private var statusColor: Color {
        switch thread?.info.status {
        case .active: return LitterTheme.success
        case .idle: return LitterTheme.textMuted
        case .systemError: return LitterTheme.danger
        case .notLoaded: return LitterTheme.textMuted
        default: return LitterTheme.textMuted
        }
    }

    private var statusLabel: String {
        switch thread?.info.status {
        case .active: return "Active"
        case .idle: return "Idle"
        case .systemError: return "Error"
        case .notLoaded: return "Not Loaded"
        default: return "Unknown"
        }
    }

    // MARK: - Context Window

    private var contextWindowSection: some View {
        Group {
            if let used = thread?.contextTokensUsed, let window = thread?.modelContextWindow, window > 0 {
                let percent = Double(used) / Double(window)
                VStack(spacing: 8) {
                    HStack {
                        Text("Context Window")
                            .litterFont(size: 14, weight: .semibold)
                            .foregroundStyle(LitterTheme.textPrimary)
                        Spacer()
                        Text("\(Int(percent * 100))%")
                            .litterFont(size: 14, weight: .bold)
                            .foregroundStyle(contextColor(percent: percent))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LitterTheme.border)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(contextColor(percent: percent))
                                .frame(width: geo.size.width * min(1, percent), height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(formatTokens(used))
                            .litterFont(size: 11)
                            .foregroundStyle(LitterTheme.textMuted)
                        Spacer()
                        Text(formatTokens(window))
                            .litterFont(size: 11)
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                }
                .padding(16)
                .modifier(GlassRectModifier(cornerRadius: 12))
            }
        }
    }

    private func contextColor(percent: Double) -> Color {
        if percent >= 0.8 { return LitterTheme.danger }
        if percent >= 0.6 { return LitterTheme.warning }
        return LitterTheme.accent
    }

    private func formatTokens(_ tokens: UInt64) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    // MARK: - Per-Conversation Stats

    private var conversationStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation Stats")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                statCard("Messages", value: "\(stats.totalMessages)", detail: "\(stats.userMessageCount) user · \(stats.assistantMessageCount) assistant")
                statCard("Turns", value: "\(stats.turnCount)")
                statCard("Commands", value: "\(stats.commandsExecuted)", detail: "\(stats.commandsSucceeded) ok · \(stats.commandsFailed) fail")
                statCard("Files Changed", value: "\(stats.filesChanged)")
                statCard("MCP Calls", value: "\(stats.mcpToolCallCount)")
                statCard("Exec Time", value: formatDuration(stats.totalCommandDurationMs))
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func statCard(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .litterFont(size: 20, weight: .bold)
                .foregroundStyle(LitterTheme.accent)
            Text(title)
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)
            if let detail {
                Text(detail)
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(GlassRectModifier(cornerRadius: 8))
    }

    private func formatDuration(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let secs = Double(ms) / 1000
        if secs < 60 { return String(format: "%.1fs", secs) }
        let mins = Int(secs / 60)
        let remainSecs = Int(secs) % 60
        return "\(mins)m \(remainSecs)s"
    }

    // MARK: - Section B: Server-Wide Charts

    private var serverChartsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Usage")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            if !serverUsage.tokensByThread.isEmpty {
                tokenUsageChart
            }

            if !serverUsage.activityByDay.isEmpty {
                activityChart
            }

            if !serverUsage.modelUsage.isEmpty {
                modelBreakdownChart
            }

            if let rateLimits = serverUsage.rateLimits {
                rateLimitGauge(rateLimits)
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private var tokenUsageChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage by Conversation")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(serverUsage.tokensByThread) { entry in
                AreaMark(
                    x: .value("Thread", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.3))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Thread", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(LitterTheme.accent)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .frame(height: 160)
        }
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity Timeline")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(serverUsage.activityByDay) { entry in
                BarMark(
                    x: .value("Date", entry.date, unit: .day),
                    y: .value("Activity", entry.turnCount)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .frame(height: 140)
        }
    }

    private var modelBreakdownChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Usage")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(serverUsage.modelUsage) { entry in
                BarMark(
                    x: .value("Count", entry.threadCount),
                    y: .value("Model", entry.model)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LitterTheme.textSecondary)
                }
            }
            .frame(height: CGFloat(max(serverUsage.modelUsage.count * 32, 60)))
        }
    }

    private func rateLimitGauge(_ rateLimits: RateLimitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate Limits")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            HStack(spacing: 16) {
                if let primary = rateLimits.primary {
                    rateLimitRing(label: "Primary", window: primary)
                }
                if let secondary = rateLimits.secondary {
                    rateLimitRing(label: "Secondary", window: secondary)
                }
            }
        }
    }

    private func rateLimitRing(label: String, window: RateLimitWindow) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(LitterTheme.border, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: Double(window.usedPercent) / 100)
                    .stroke(rateLimitColor(percent: Int(window.usedPercent)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(window.usedPercent)%")
                    .litterFont(size: 12, weight: .bold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
            .frame(width: 56, height: 56)

            Text(label)
                .litterFont(size: 10)
                .foregroundStyle(LitterTheme.textMuted)
        }
    }

    private func rateLimitColor(percent: Int) -> Color {
        if percent >= 80 { return LitterTheme.danger }
        if percent >= 60 { return LitterTheme.warning }
        return LitterTheme.accent
    }

    // MARK: - Section C: Server Info

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            if let server {
                infoRow("Name", value: server.displayName)
                infoRow("Address", value: "\(server.host):\(server.port)")
                infoRow("Mode", value: server.connectionModeLabel)

                HStack(spacing: 6) {
                    Text("Health")
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textMuted)
                    Spacer()
                    Circle()
                        .fill(healthColor(server.health))
                        .frame(width: 8, height: 8)
                    Text(healthLabel(server.health))
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textSecondary)
                }

                if let account = server.account {
                    accountRow(account)
                }

                if let models = server.availableModels, !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available Models")
                            .litterFont(size: 12)
                            .foregroundStyle(LitterTheme.textMuted)
                        ForEach(models.prefix(8), id: \.id) { model in
                            Text(model.displayName)
                                .litterFont(size: 12)
                                .foregroundStyle(LitterTheme.textSecondary)
                        }
                        if models.count > 8 {
                            Text("+\(models.count - 8) more")
                                .litterFont(size: 11)
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textMuted)
            Spacer()
            Text(value)
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textSecondary)
        }
    }

    private func healthColor(_ health: AppServerHealth) -> Color {
        switch health {
        case .connected: return LitterTheme.success
        case .connecting: return LitterTheme.warning
        case .disconnected, .unresponsive: return LitterTheme.danger
        case .unknown: return LitterTheme.textMuted
        }
    }

    private func healthLabel(_ health: AppServerHealth) -> String {
        switch health {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .unresponsive: return "Unresponsive"
        case .unknown: return "Unknown"
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack {
            Text("Account")
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textMuted)
            Spacer()
            switch account {
            case .apiKey:
                Text("API Key")
                    .litterFont(size: 12)
                    .foregroundStyle(LitterTheme.textSecondary)
            case .chatgpt(let email, let planType):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(email)
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textSecondary)
                    Text(planTypeLabel(planType))
                        .litterFont(size: 10)
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
        }
    }

    private func planTypeLabel(_ planType: PlanType) -> String {
        switch planType {
        case .free: return "Free"
        case .go: return "Go"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .team: return "Team"
        case .business: return "Business"
        case .enterprise: return "Enterprise"
        case .edu: return "Edu"
        case .unknown: return "Unknown"
        }
    }

    // MARK: - Section D: Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            actionButton(icon: "photo", title: "Change Wallpaper") {
                onOpenWallpaper?()
            }

            Divider().overlay(LitterTheme.separator)

            actionButton(icon: "arrow.branch", title: "Fork Conversation") {
                Task { await forkConversation() }
            }

            Divider().overlay(LitterTheme.separator)

            renameRow
        }
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(LitterTheme.accent)
                    .frame(width: 24)
                Text(title)
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(LitterTheme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var renameRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil")
                .font(.system(size: 14))
                .foregroundStyle(LitterTheme.accent)
                .frame(width: 24)

            if isRenaming {
                TextField("Thread name", text: $renameText)
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .onSubmit { saveRename() }

                Button("Save") { saveRename() }
                    .litterFont(size: 13, weight: .semibold)
                    .foregroundStyle(LitterTheme.accent)
            } else {
                Button {
                    renameText = thread?.info.title ?? ""
                    isRenaming = true
                } label: {
                    HStack {
                        Text("Rename Thread")
                            .litterFont(size: 14)
                            .foregroundStyle(LitterTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func forkConversation() async {
        do {
            let response = try await appModel.rpc.threadFork(
                serverId: threadKey.serverId,
                params: ThreadForkParams(
                    threadId: threadKey.threadId,
                    path: nil,
                    model: thread?.model,
                    modelProvider: nil,
                    serviceTier: nil,
                    cwd: thread?.info.cwd,
                    approvalPolicy: nil,
                    approvalsReviewer: nil,
                    sandbox: nil,
                    config: nil,
                    baseInstructions: nil,
                    developerInstructions: nil,
                    ephemeral: false,
                    persistExtendedHistory: true
                )
            )
            let newKey = ThreadKey(serverId: threadKey.serverId, threadId: response.thread.id)
            appModel.store.setActiveThread(key: newKey)
            await appModel.refreshSnapshot()
            onOpenConversation?(newKey)
        } catch {
            LLog.error("info", "failed to fork thread", error: error)
        }
    }

    private func saveRename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isRenaming = false
        Task {
            do {
                _ = try await appModel.rpc.threadSetName(
                    serverId: threadKey.serverId,
                    params: ThreadSetNameParams(threadId: threadKey.threadId, name: title)
                )
                await appModel.refreshSnapshot()
            } catch {
                LLog.error("info", "failed to rename thread", error: error)
            }
        }
    }

    private func computeData() {
        guard let thread else { return }
        stats = ConversationStatistics.compute(from: thread.hydratedConversationItems)

        if let server {
            serverUsage = ServerUsageData.compute(from: allServerThreads, server: server)
        }
    }
}
