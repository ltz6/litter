import SwiftUI
import Combine
import Inject
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    private var pendingPushToken: Data?
    weak var serverManager: ServerManager? {
        didSet {
            if let token = pendingPushToken {
                serverManager?.devicePushToken = token
                pendingPushToken = nil
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[push] device token received (%d bytes): %@", deviceToken.count, hex)
        if let sm = serverManager {
            sm.devicePushToken = deviceToken
        } else {
            pendingPushToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] registration failed: %@", error.localizedDescription)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NSLog("[push] background push received")
        guard let sm = serverManager else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await sm.handleBackgroundPush()
            completionHandler(.newData)
        }
    }
}

@main
struct LitterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serverManager = ServerManager()
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .environmentObject(themeManager)
                .task {
                    appDelegate.serverManager = serverManager
                    await serverManager.reconnectAll()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                serverManager.appDidEnterBackground()
            case .active:
                serverManager.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var appState = AppState()
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var isEdgeOpeningSidebar = false

    private let sidebarAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)

    private var sidebarRevealProgress: CGFloat {
        guard appState.sidebarOpen else { return 0 }
        return min(1, max(0, 1 + (sidebarDragOffset / SidebarOverlay.sidebarWidth)))
    }

    private var rootSnapshot: ContentRootSnapshot {
        ContentRootSnapshot(
            activeThreadKey: serverManager.activeThreadKey,
            requestedConversationKey: appState.requestedConversationKey,
            composerPrefillRequest: serverManager.composerPrefillRequest,
            agentDirectoryVersion: serverManager.agentDirectoryVersion,
            activePendingApproval: serverManager.activePendingApproval
        )
    }

    private func activeConversationContext(
        for snapshot: ContentRootSnapshot
    ) -> (thread: ThreadState, connection: ServerConnection, key: ThreadKey)? {
        guard let key = snapshot.effectiveConversationKey,
              let thread = serverManager.threads[key],
              let connection = serverManager.connections[key.serverId] else {
            return nil
        }
        return (thread, connection, key)
    }

    var body: some View {
        let snapshot = rootSnapshot
        let activeConversationContext = activeConversationContext(for: snapshot)
        let hasActiveConversation = snapshot.effectiveConversationKey != nil

        GeometryReader { geometry in
        let composerBottomInset = resolvedComposerBottomInset(fallback: geometry.safeAreaInsets.bottom)
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            mainContent(
                snapshot: snapshot,
                activeConversationContext: activeConversationContext,
                topInset: geometry.safeAreaInsets.top,
                bottomInset: composerBottomInset
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .overlay {
                    if appState.showModelSelector {
                        Color.black.opacity(0.01)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    appState.showModelSelector = false
                                }
                            }
                    }
                }
                .overlay(alignment: .top) {
                    if let activeConversationContext {
                        HeaderView(
                            thread: activeConversationContext.thread,
                            connection: activeConversationContext.connection,
                            serverManager: serverManager,
                            topInset: geometry.safeAreaInsets.top
                        )
                    }
                }
                .id(themeManager.themeVersion)
                .allowsHitTesting(!appState.sidebarOpen)
                .overlay(alignment: .leading) {
                    if hasActiveConversation && !appState.sidebarOpen {
                        edgeOpenHandle
                    }
                }

            SidebarOverlay(dragOffset: $sidebarDragOffset, topInset: geometry.safeAreaInsets.top)

            if let approval = snapshot.activePendingApproval {
                ApprovalPromptView(approval: approval) { decision in
                    serverManager.respondToPendingApproval(requestId: approval.requestId, decision: decision)
                }
            }
        }
        .ignoresSafeArea(.container)
        }
        .environmentObject(appState)
        .onAppear {
            let forceDiscoveryForUITest =
                ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] == "1"
            if forceDiscoveryForUITest {
                appState.showServerPicker = true
            }
        }
        .onChange(of: appState.sidebarOpen) { _, isOpen in
            if !isOpen { sidebarDragOffset = 0 }
        }
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            appState.selectedModel = ""
            appState.reasoningEffort = ""
            appState.showModelSelector = false
        }
        .onChange(of: serverManager.activeThreadKey) { _, nextKey in
            appState.requestedConversationKey = nextKey
        }
        .enableInjection()
        .sheet(isPresented: $appState.showServerPicker) {
            let shouldOpenSidebarAfterConnect = snapshot.effectiveConversationKey != nil
            NavigationStack {
                DiscoveryView(onServerSelected: { _ in
                    appState.showServerPicker = false
                    if shouldOpenSidebarAfterConnect {
                        appState.sidebarOpen = true
                    }
                })
                .environmentObject(serverManager)
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(serverManager)
                .environmentObject(appState)
        }
    }

    private var edgeOpenHandle: some View {
        Color.clear
            .frame(width: 24)
            .contentShape(Rectangle())
            .gesture(edgeOpenGesture)
    }

    private func resolvedComposerBottomInset(fallback: CGFloat) -> CGFloat {
        let keyWindowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
        return keyWindowInset > 0 ? keyWindowInset : fallback
    }

    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !appState.sidebarOpen || isEdgeOpeningSidebar else { return }

                if !isEdgeOpeningSidebar {
                    let startsAtEdge = value.startLocation.x <= 24
                    let horizontalIntent = abs(value.translation.width) > abs(value.translation.height)
                    guard startsAtEdge, horizontalIntent, value.translation.width > 0 else { return }
                    isEdgeOpeningSidebar = true
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        appState.sidebarOpen = true
                        sidebarDragOffset = -SidebarOverlay.sidebarWidth
                    }
                }

                let translationX = max(0, value.translation.width)
                sidebarDragOffset = min(
                    0,
                    max(-SidebarOverlay.sidebarWidth, -SidebarOverlay.sidebarWidth + translationX)
                )
            }
            .onEnded { value in
                guard isEdgeOpeningSidebar else { return }
                isEdgeOpeningSidebar = false

                let projectedOpenDistance = max(value.translation.width, value.predictedEndTranslation.width)
                let shouldOpen = projectedOpenDistance > SidebarOverlay.sidebarWidth * 0.35
                withAnimation(sidebarAnimation) {
                    appState.sidebarOpen = shouldOpen
                    sidebarDragOffset = 0
                }
            }
    }

    private func mainContent(
        snapshot: ContentRootSnapshot,
        activeConversationContext: (thread: ThreadState, connection: ServerConnection, key: ThreadKey)?,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        Group {
            if let activeConversationContext {
                ConversationView(
                    thread: activeConversationContext.thread,
                    connection: activeConversationContext.connection,
                    activeThreadKey: activeConversationContext.key,
                    serverManager: serverManager,
                    composerPrefillRequest: snapshot.composerPrefillRequest,
                    agentDirectoryVersion: snapshot.agentDirectoryVersion,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            } else if snapshot.effectiveConversationKey != nil {
                ProgressView()
                    .tint(LitterTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            } else {
                HomeNavigationView()
                    .environmentObject(serverManager)
                    .environmentObject(appState)
            }
        }
    }
}

private struct ContentRootSnapshot {
    let activeThreadKey: ThreadKey?
    let requestedConversationKey: ThreadKey?
    let composerPrefillRequest: ServerManager.ComposerPrefillRequest?
    let agentDirectoryVersion: Int
    let activePendingApproval: ServerManager.PendingApproval?

    var effectiveConversationKey: ThreadKey? {
        activeThreadKey ?? requestedConversationKey
    }
}

private struct HomeNavigationView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var navigationPath: [HomeNavigationRoute] = []
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var actionErrorMessage: String?

    private enum HomeNavigationRoute: Hashable {
        case sessions(serverId: String, title: String)
    }

    private var connectedServers: [ServerConnection] {
        HomeDashboardSupport.sortedConnectedServers(
            from: Array(serverManager.connections.values),
            activeServerId: serverManager.activeThreadKey?.serverId
        )
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        connectedServers.map { connection in
            DirectoryPickerServerOption(
                id: connection.id,
                name: connection.server.name,
                sourceLabel: connection.server.source.rawString
            )
        }
    }

    private var recentSessions: [ThreadState] {
        HomeDashboardSupport.recentConnectedSessions(
            from: serverManager.sortedThreads,
            connectedServerIds: Set(connectedServers.map(\.id))
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            HomeDashboardView(
                recentSessions: recentSessions,
                connectedServers: connectedServers,
                openingRecentSessionKey: openingRecentSessionKey,
                onOpenRecentSession: openRecentSession,
                onOpenServerSessions: openServerSessions,
                onNewSession: handleNewSessionTap,
                onConnectServer: { appState.showServerPicker = true },
                onShowSettings: { appState.showSettings = true }
            )
            .navigationDestination(for: HomeNavigationRoute.self) { route in
                switch route {
                case let .sessions(serverId, title):
                    SessionSidebarView()
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                        .onAppear {
                            appState.sessionSidebarSelectedServerFilterId = serverId
                            appState.sessionSidebarShowOnlyForks = false
                        }
                }
            }
        }
        .sheet(item: $directoryPickerSheet) { _ in
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { directoryPickerSheet?.selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { nextServerId in
                            guard var sheet = directoryPickerSheet else { return }
                            sheet.selectedServerId = nextServerId
                            directoryPickerSheet = sheet
                        }
                    ),
                    onServerChanged: { nextServerId in
                        guard var sheet = directoryPickerSheet else { return }
                        sheet.selectedServerId = nextServerId
                        directoryPickerSheet = sheet
                    },
                    onDirectorySelected: { serverId, cwd in
                        directoryPickerSheet = nil
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
                .environmentObject(serverManager)
            }
        }
        .alert("Home Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        SessionLaunchSupport.defaultConnectedServerId(
            connectedServerIds: connectedServerOptions.map(\.id),
            activeThreadKey: serverManager.activeThreadKey,
            preferredServerId: preferredServerId
        )
    }

    private func handleNewSessionTap() {
        if let defaultServerId = defaultNewSessionServerId() {
            directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
        } else {
            appState.showServerPicker = true
        }
    }

    private func openServerSessions(_ connection: ServerConnection) {
        appState.sessionSidebarSelectedServerFilterId = connection.id
        appState.sessionSidebarShowOnlyForks = false
        navigationPath.append(.sessions(serverId: connection.id, title: connection.server.name))
    }

    private func openRecentSession(_ thread: ThreadState) async {
        guard openingRecentSessionKey == nil else { return }
        openingRecentSessionKey = thread.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        appState.requestedConversationKey = thread.key
        let opened = await serverManager.viewThread(
            thread.key,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        guard opened else {
            appState.requestedConversationKey = nil
            if let selectedThread = serverManager.threads[thread.key],
               case .error(let message) = selectedThread.status {
                actionErrorMessage = message
            } else {
                actionErrorMessage = "Failed to open conversation."
            }
            return
        }

        appState.requestedConversationKey = thread.key
    }

    private func startNewSession(serverId: String, cwd: String) async {
        workDir = cwd
        appState.currentCwd = cwd
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let startedKey = try? await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )

        guard let startedKey else {
            actionErrorMessage = "Failed to start a new session."
            return
        }

        appState.requestedConversationKey = startedKey
        _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
    }
}

private struct ApprovalPromptView: View {
    let approval: ServerManager.PendingApproval
    let onDecision: (ServerManager.ApprovalDecision) -> Void

    private var title: String {
        switch approval.kind {
        case .commandExecution:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        }
    }

    private var requesterLabel: String? {
        let nickname = approval.requesterAgentNickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let role = approval.requesterAgentRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !nickname.isEmpty && !role.isEmpty {
            return "\(nickname) [\(role)]"
        }
        if !nickname.isEmpty {
            return nickname
        }
        if !role.isEmpty {
            return "[\(role)]"
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(LitterFont.styled(.headline))
                    .foregroundColor(LitterTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(LitterFont.styled(.footnote))
                        .foregroundColor(LitterTheme.textSecondary)
                }

                if let requesterLabel {
                    Text("Requester: \(requesterLabel)")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .font(LitterFont.styled(.caption))
                            .foregroundColor(LitterTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .font(LitterFont.styled(.footnote))
                                .foregroundColor(LitterTheme.textBody)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LitterTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let cwd = approval.cwd, !cwd.isEmpty {
                    Text("CWD: \(cwd)")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                VStack(spacing: 8) {
                    Button("Allow Once") { onDecision(.accept) }
                        .buttonStyle(.borderedProminent)
                        .tint(LitterTheme.accent)
                        .frame(maxWidth: .infinity)

                    Button("Allow for Session") { onDecision(.acceptForSession) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button("Deny") { onDecision(.decline) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)

                        Button("Abort") { onDecision(.cancel) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(LitterFont.styled(.callout))
            }
            .padding(16)
            .modifier(GlassRectModifier(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(LitterTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 24) {
                BrandLogo(size: 132)
                Text("AI coding agent on iOS")
                    .font(LitterFont.styled(.body))
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
