import SwiftUI
import Inject

struct HeaderView: View {
    private static let contextBaselineTokens: Int64 = 12_000

    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showModelSelector = false
    @State private var isReloading = false

    var topInset: CGFloat = 0

    private var activeConn: ServerConnection? {
        serverManager.activeConnection
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.sidebarOpen.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "#999999"))
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier())
            }
            .accessibilityIdentifier("header.sidebarButton")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Button { showModelSelector = true } label: {
                        HStack(spacing: 6) {
                            Text(sessionModelLabel)
                                .foregroundColor(.white)
                            Text(sessionReasoningLabel)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        .font(LitterFont.monospaced(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("header.modelPickerButton")

                    ContextRingView(percent: Int(sessionContextPercent ?? 100), tint: sessionContextTint)
                }
                Text(sessionDirectoryLabel)
                    .font(LitterFont.monospaced(.caption2, weight: .semibold))
                    .foregroundColor(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(GlassRectModifier(cornerRadius: 16))

            Spacer(minLength: 0)

            reloadButton
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .black.opacity(0.2), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.bottom, -30)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        )
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            syncSelectionFromActiveThread()
            Task { await loadModelsIfNeeded() }
        }
        .onChange(of: serverManager.activeThread?.model) { _, _ in
            syncSelectionFromActiveThread()
        }
        .onChange(of: serverManager.activeThread?.reasoningEffort) { _, _ in
            syncSelectionFromActiveThread()
        }
        .onChange(of: serverManager.activeThread?.cwd) { _, _ in
            syncSelectionFromActiveThread()
        }
        .task {
            syncSelectionFromActiveThread()
            await loadModelsIfNeeded()
        }
        .enableInjection()
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorView()
                .environmentObject(serverManager)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sessionModelLabel: String {
        let threadModel = serverManager.activeThread?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadModel.isEmpty {
            return threadModel
        }

        let selectedModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedModel.isEmpty {
            return selectedModel
        }

        return "litter"
    }

    private var sessionReasoningLabel: String {
        let threadReasoning = serverManager.activeThread?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty {
            return threadReasoning
        }

        let selectedReasoning = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedReasoning.isEmpty {
            return selectedReasoning
        }

        return "default"
    }

    private var sessionContextTint: Color {
        guard let percent = sessionContextPercent else {
            return LitterTheme.textSecondary
        }
        switch percent {
        case ...15:
            return LitterTheme.danger
        case ...35:
            return LitterTheme.warning
        default:
            return LitterTheme.accentStrong
        }
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = serverManager.activeThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !currentDirectory.isEmpty {
            return abbreviateRemoteHomePath(currentDirectory)
        }

        let appDirectory = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appDirectory.isEmpty {
            return abbreviateRemoteHomePath(appDirectory)
        }

        return "~"
    }

    private var sessionContextPercent: Int64? {
        guard let thread = serverManager.activeThread,
              let contextWindow = thread.modelContextWindow else {
            return nil
        }

        let totalTokens = thread.contextTokensUsed ?? Self.contextBaselineTokens
        return percentOfContextWindowRemaining(
            totalTokens: totalTokens,
            contextWindow: contextWindow
        )
    }

    private func loadModelsIfNeeded() async {
        syncSelectionFromActiveThread()

        guard let conn = activeConn, conn.isConnected, !conn.modelsLoaded else { return }
        do {
            let resp = try await conn.listModels()
            conn.models = resp.data
            conn.modelsLoaded = true
            if appState.selectedModel.isEmpty {
                if let defaultModel = resp.data.first(where: { $0.isDefault }) {
                    appState.selectedModel = defaultModel.id
                    appState.reasoningEffort = defaultModel.defaultReasoningEffort
                } else if let first = resp.data.first {
                    appState.selectedModel = first.id
                    appState.reasoningEffort = first.defaultReasoningEffort
                }
            }
        } catch {}
    }

    private func syncSelectionFromActiveThread() {
        let threadModel = serverManager.activeThread?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadModel.isEmpty && appState.selectedModel != threadModel {
            appState.selectedModel = threadModel
        }

        let threadReasoning = serverManager.activeThread?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty && appState.reasoningEffort != threadReasoning {
            appState.reasoningEffort = threadReasoning
        }

        let threadCwd = serverManager.activeThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadCwd.isEmpty && appState.currentCwd != threadCwd {
            appState.currentCwd = threadCwd
        }
    }

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                await serverManager.refreshAllSessions()
                await serverManager.syncActiveThreadFromServer()
                syncSelectionFromActiveThread()
                isReloading = false
            }
        } label: {
            Group {
                if isReloading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(LitterTheme.accent)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(serverManager.hasAnyConnection ? LitterTheme.accent : LitterTheme.textMuted)
                }
            }
            .frame(width: 44, height: 44)
            .modifier(GlassCircleModifier())
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || !serverManager.hasAnyConnection)
    }

    private func percentOfContextWindowRemaining(totalTokens: Int64, contextWindow: Int64) -> Int64 {
        let baseline = Self.contextBaselineTokens
        guard contextWindow > baseline else { return 0 }

        let effectiveWindow = contextWindow - baseline
        let usedTokens = max(0, totalTokens - baseline)
        let remainingTokens = max(0, effectiveWindow - usedTokens)
        let remainingFraction = Double(remainingTokens) / Double(effectiveWindow)
        let percent = Int64((remainingFraction * 100).rounded())
        return min(max(percent, 0), 100)
    }

    private func abbreviateRemoteHomePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "~" }

        if let abbreviated = abbreviateUnixHomePrefix(trimmedPath, basePrefix: "/Users") {
            return abbreviated
        }
        if let abbreviated = abbreviateUnixHomePrefix(trimmedPath, basePrefix: "/home") {
            return abbreviated
        }
        return trimmedPath
    }

    private func abbreviateUnixHomePrefix(_ path: String, basePrefix: String) -> String? {
        let prefix = basePrefix + "/"
        guard path.hasPrefix(prefix) else { return nil }

        let remainder = path.dropFirst(prefix.count)
        guard let slashIndex = remainder.firstIndex(of: "/") else {
            return "~"
        }

        let suffix = remainder[slashIndex...]
        return "~" + suffix
    }
}

struct ModelSelectorView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?

    private var models: [CodexModel] {
        serverManager.activeConnection?.models ?? []
    }

    private var currentModel: CodexModel? {
        models.first { $0.id == appState.selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Model")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.bottom, 16)

            if models.isEmpty {
                Spacer()
                if let err = loadError {
                    Text(err)
                        .font(.system(.footnote))
                        .foregroundColor(LitterTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                    Button("Retry") {
                        loadError = nil
                        Task { await loadModels() }
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(LitterTheme.accent)
                } else {
                    ProgressView().tint(LitterTheme.accent)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(models) { model in
                            Button {
                                appState.selectedModel = model.id
                                appState.reasoningEffort = model.defaultReasoningEffort
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(model.displayName)
                                                .font(.system(.subheadline))
                                                .foregroundColor(.white)
                                            if model.isDefault {
                                                Text("default")
                                                    .font(.system(.caption2, weight: .medium))
                                                    .foregroundColor(LitterTheme.accent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(LitterTheme.accent.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(model.description)
                                            .font(.system(.caption))
                                            .foregroundColor(LitterTheme.textSecondary)
                                    }
                                    Spacer()
                                    if model.id == appState.selectedModel {
                                        Image(systemName: "checkmark")
                                            .font(.system(.subheadline, weight: .medium))
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            }
                            Divider().background(Color(hex: "#1E1E1E")).padding(.leading, 20)
                        }

                        if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                            Text("Reasoning")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 12)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(info.supportedReasoningEfforts) { effort in
                                        Button {
                                            appState.reasoningEffort = effort.reasoningEffort
                                        } label: {
                                            Text(effort.reasoningEffort)
                                                .font(.system(.footnote, weight: .medium))
                                                .foregroundColor(effort.reasoningEffort == appState.reasoningEffort ? .black : .white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(effort.reasoningEffort == appState.reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .background(.ultraThinMaterial)
        .task {
            if models.isEmpty { await loadModels() }
        }
    }

    private func loadModels() async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            loadError = "Not connected to a server"
            return
        }
        do {
            let resp = try await conn.listModels()
            conn.models = resp.data
            conn.modelsLoaded = true
            if appState.selectedModel.isEmpty {
                if let defaultModel = resp.data.first(where: { $0.isDefault }) {
                    appState.selectedModel = defaultModel.id
                    appState.reasoningEffort = defaultModel.defaultReasoningEffort
                } else if let first = resp.data.first {
                    appState.selectedModel = first.id
                    appState.reasoningEffort = first.defaultReasoningEffort
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("Header") {
    LitterPreviewScene {
        HeaderView()
    }
}

#Preview("Model Selector") {
    LitterPreviewScene(includeBackground: false) {
        ModelSelectorView()
    }
}
#endif
