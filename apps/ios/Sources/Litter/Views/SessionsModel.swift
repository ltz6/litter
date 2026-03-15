import Combine
import Foundation

@MainActor
final class SessionsModel: ObservableObject {
    struct ThreadEphemeralState: Equatable {
        let hasTurnActive: Bool
        let updatedAt: Date
    }

    private enum ThreadChangeKind {
        case structural
        case status
        case updatedAt
    }

    @Published private(set) var derivedData: SessionSidebarDerivedData = .empty
    @Published private(set) var connectedServerOptions: [DirectoryPickerServerOption] = []
    @Published private(set) var ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState] = [:]

    private weak var serverManager: ServerManager?
    private weak var appState: AppState?
    private var threadsSubscription: AnyCancellable?
    private var connectionsSubscription: AnyCancellable?
    private var selectedServerFilterSubscription: AnyCancellable?
    private var showOnlyForksSubscription: AnyCancellable?
    private var workspaceSortModeSubscription: AnyCancellable?
    private var threadSubscriptions: [ThreadKey: AnyCancellable] = [:]
    private var connectionSubscriptions: [String: AnyCancellable] = [:]

    private var selectedServerFilterId: String?
    private var showOnlyForks = false
    private var workspaceSortMode: WorkspaceSortMode = .mostRecent
    private var searchQuery = ""
    private var hasInitializedState = false
    private var hasPendingDerivedDataRebuild = false
    private var frozenMostRecentThreadOrder: [ThreadKey]?

    func bind(serverManager: ServerManager, appState: AppState) {
        let needsManagerBinding = self.serverManager !== serverManager
        let needsAppStateBinding = self.appState !== appState

        self.serverManager = serverManager
        self.appState = appState
        selectedServerFilterId = appState.sessionSidebarSelectedServerFilterId
        showOnlyForks = appState.sessionSidebarShowOnlyForks
        workspaceSortMode = WorkspaceSortMode(rawValue: appState.sessionSidebarWorkspaceSortModeRaw) ?? .mostRecent

        if needsManagerBinding {
            bindServerManager(serverManager)
        }

        if needsAppStateBinding {
            bindAppState(appState)
        }

        guard needsManagerBinding || needsAppStateBinding || !hasInitializedState else { return }
        hasInitializedState = true
        refreshState()
    }

    func updateSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        scheduleDerivedDataRebuild()
    }

    private func bindServerManager(_ serverManager: ServerManager) {
        threadsSubscription?.cancel()
        threadsSubscription = serverManager.$threads
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshThreadSubscriptions()
                self?.scheduleDerivedDataRebuild()
            }

        connectionsSubscription?.cancel()
        connectionsSubscription = serverManager.$connections
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshConnectionSubscriptions()
                self?.refreshConnectedServerOptions()
                self?.scheduleDerivedDataRebuild()
            }
    }

    private func bindAppState(_ appState: AppState) {
        selectedServerFilterSubscription?.cancel()
        selectedServerFilterSubscription = appState.$sessionSidebarSelectedServerFilterId
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] nextValue in
                guard let self, self.selectedServerFilterId != nextValue else { return }
                self.selectedServerFilterId = nextValue
                self.scheduleDerivedDataRebuild()
            }

        showOnlyForksSubscription?.cancel()
        showOnlyForksSubscription = appState.$sessionSidebarShowOnlyForks
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] nextValue in
                guard let self, self.showOnlyForks != nextValue else { return }
                self.showOnlyForks = nextValue
                self.scheduleDerivedDataRebuild()
            }

        workspaceSortModeSubscription?.cancel()
        workspaceSortModeSubscription = appState.$sessionSidebarWorkspaceSortModeRaw
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] rawValue in
                guard let self else { return }
                let nextMode = WorkspaceSortMode(rawValue: rawValue) ?? .mostRecent
                guard self.workspaceSortMode != nextMode else { return }
                self.workspaceSortMode = nextMode
                self.scheduleDerivedDataRebuild()
            }
    }

    private func refreshState() {
        refreshThreadSubscriptions()
        refreshConnectionSubscriptions()
        refreshConnectedServerOptions()
        rebuildDerivedData()
    }

    private func refreshThreadSubscriptions() {
        guard let serverManager else {
            cancelThreadSubscriptions()
            return
        }

        let currentKeys = Set(serverManager.threads.keys)
        for key in threadSubscriptions.keys where !currentKeys.contains(key) {
            threadSubscriptions.removeValue(forKey: key)?.cancel()
            ephemeralStateByThreadKey.removeValue(forKey: key)
        }

        for (key, thread) in serverManager.threads where threadSubscriptions[key] == nil {
            updateEphemeralState(for: key, thread: thread)

            let structuralChanges = Publishers.MergeMany([
                thread.$preview.map { _ in () }.eraseToAnyPublisher(),
                thread.$cwd.map { _ in () }.eraseToAnyPublisher(),
                thread.$model.map { _ in () }.eraseToAnyPublisher(),
                thread.$modelProvider.map { _ in () }.eraseToAnyPublisher(),
                thread.$parentThreadId.map { _ in () }.eraseToAnyPublisher(),
                thread.$rootThreadId.map { _ in () }.eraseToAnyPublisher(),
                thread.$agentNickname.map { _ in () }.eraseToAnyPublisher(),
                thread.$agentRole.map { _ in () }.eraseToAnyPublisher()
            ])
            .map { ThreadChangeKind.structural }
            .eraseToAnyPublisher()

            let statusChanges = thread.$status
                .map { _ in ThreadChangeKind.status }
                .eraseToAnyPublisher()

            let updatedAtChanges = thread.$updatedAt
                .map { _ in ThreadChangeKind.updatedAt }
                .eraseToAnyPublisher()

            threadSubscriptions[key] = Publishers.MergeMany([
                structuralChanges,
                statusChanges,
                updatedAtChanges
            ])
                .receive(on: RunLoop.main)
                .sink { [weak self] change in
                    self?.handleThreadChange(change, key: key, thread: thread)
                }
        }
    }

    private func refreshConnectionSubscriptions() {
        guard let serverManager else {
            cancelConnectionSubscriptions()
            return
        }

        let currentIDs = Set(serverManager.connections.keys)
        for serverId in connectionSubscriptions.keys where !currentIDs.contains(serverId) {
            connectionSubscriptions.removeValue(forKey: serverId)?.cancel()
        }

        for (serverId, connection) in serverManager.connections where connectionSubscriptions[serverId] == nil {
            connectionSubscriptions[serverId] = connection.$isConnected
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshConnectedServerOptions()
                }
        }
    }

    private func refreshConnectedServerOptions() {
        guard let serverManager else {
            connectedServerOptions = []
            return
        }

        connectedServerOptions = serverManager.connections.values
            .filter(\.isConnected)
            .sorted {
                $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
            }
            .map {
                DirectoryPickerServerOption(
                    id: $0.id,
                    name: $0.server.name,
                    sourceLabel: $0.server.source.rawString
                )
            }
    }

    private func rebuildDerivedData() {
        guard let serverManager else {
            derivedData = .empty
            return
        }

        derivedData = SessionsDerivation.build(
            serverManager: serverManager,
            selectedServerFilterId: selectedServerFilterId,
            showOnlyForks: showOnlyForks,
            workspaceSortMode: workspaceSortMode,
            searchQuery: searchQuery,
            frozenMostRecentOrder: resolvedFrozenMostRecentThreadOrder(serverManager: serverManager)
        )
    }

    private func resolvedFrozenMostRecentThreadOrder(serverManager: ServerManager) -> [ThreadKey]? {
        guard workspaceSortMode == .mostRecent else {
            frozenMostRecentThreadOrder = nil
            return nil
        }

        let hasActiveThread = serverManager.threads.values.contains(where: \.hasTurnActive)
        guard hasActiveThread else {
            frozenMostRecentThreadOrder = nil
            return nil
        }

        if let frozenMostRecentThreadOrder {
            return frozenMostRecentThreadOrder
        }

        let initialOrder: [ThreadKey]
        if !derivedData.allThreadKeys.isEmpty {
            initialOrder = derivedData.allThreadKeys
        } else {
            initialOrder = serverManager.threads.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(\.key)
        }
        frozenMostRecentThreadOrder = initialOrder
        return initialOrder
    }

    private func scheduleDerivedDataRebuild() {
        guard !hasPendingDerivedDataRebuild else { return }
        hasPendingDerivedDataRebuild = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingDerivedDataRebuild = false
            self.rebuildDerivedData()
        }
    }

    private func handleThreadChange(
        _ change: ThreadChangeKind,
        key: ThreadKey,
        thread: ThreadState
    ) {
        let previousState = ephemeralStateByThreadKey[key]
        updateEphemeralState(for: key, thread: thread)

        switch change {
        case .structural:
            scheduleDerivedDataRebuild()
        case .status:
            handleStatusChange(previousState: previousState, thread: thread)
        case .updatedAt:
            handleUpdatedAtChange(thread: thread)
        }
    }

    private func updateEphemeralState(for key: ThreadKey, thread: ThreadState) {
        let nextState = ThreadEphemeralState(
            hasTurnActive: thread.hasTurnActive,
            updatedAt: thread.updatedAt
        )
        guard ephemeralStateByThreadKey[key] != nextState else { return }
        ephemeralStateByThreadKey[key] = nextState
    }

    private func handleStatusChange(
        previousState: ThreadEphemeralState?,
        thread: ThreadState
    ) {
        let wasActive = previousState?.hasTurnActive ?? false
        let isActive = thread.hasTurnActive

        guard wasActive != isActive else { return }

        switch workspaceSortMode {
        case .mostRecent:
            if !isActive {
                rebuildDerivedData()
            }
        case .date:
            rebuildDerivedData()
        case .name:
            break
        }
    }

    private func handleUpdatedAtChange(thread: ThreadState) {
        switch workspaceSortMode {
        case .mostRecent:
            guard !thread.hasTurnActive else { return }
            rebuildDerivedData()
        case .date:
            rebuildDerivedData()
        case .name:
            break
        }
    }

    private func cancelThreadSubscriptions() {
        for subscription in threadSubscriptions.values {
            subscription.cancel()
        }
        threadSubscriptions.removeAll()
        ephemeralStateByThreadKey.removeAll()
    }

    private func cancelConnectionSubscriptions() {
        for subscription in connectionSubscriptions.values {
            subscription.cancel()
        }
        connectionSubscriptions.removeAll()
    }
}
