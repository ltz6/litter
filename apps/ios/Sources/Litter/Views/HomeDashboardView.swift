import SwiftUI

struct HomeDashboardView: View {
    let recentSessions: [ThreadState]
    let connectedServers: [ServerConnection]
    let openingRecentSessionKey: ThreadKey?
    let isStartingNewSession: Bool
    let onOpenRecentSession: @MainActor (ThreadState) async -> Void
    let onOpenServerSessions: (ServerConnection) -> Void
    let onNewSession: () -> Void
    let onConnectServer: () -> Void
    let onShowSettings: () -> Void
    var onDeleteThread: ((ThreadKey) async -> Void)? = nil
    var onDisconnectServer: ((String) -> Void)? = nil
    @State private var deleteTargetThread: ThreadState?
    @State private var disconnectTargetServer: ServerConnection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                recentSessionsSection
                connectedServersSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 144)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .alert("Delete Session?", isPresented: Binding(
            get: { deleteTargetThread != nil },
            set: { if !$0 { deleteTargetThread = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTargetThread = nil }
            Button("Delete", role: .destructive) {
                if let thread = deleteTargetThread {
                    Task { await onDeleteThread?(thread.key) }
                }
                deleteTargetThread = nil
            }
        } message: {
            Text("This will permanently delete \"\(deleteTargetThread?.sessionTitle ?? "this session")\".")
        }
        .alert("Disconnect Server?", isPresented: Binding(
            get: { disconnectTargetServer != nil },
            set: { if !$0 { disconnectTargetServer = nil } }
        )) {
            Button("Cancel", role: .cancel) { disconnectTargetServer = nil }
            Button("Disconnect", role: .destructive) {
                if let conn = disconnectTargetServer {
                    onDisconnectServer?(conn.id)
                }
                disconnectTargetServer = nil
            }
        } message: {
            Text("Disconnect from \"\(disconnectTargetServer?.server.name ?? "this server")\"?")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onShowSettings) {
                    Image(systemName: "gearshape")
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }
            ToolbarItem(placement: .principal) {
                BrandLogo(size: 44)
            }
        }
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Recent Sessions",
                buttonTitle: "New Session",
                systemImage: "plus",
                showsLoading: isStartingNewSession,
                action: onNewSession
            )

            if recentSessions.isEmpty {
                emptyStateCard(
                    title: "No recent sessions",
                    message: connectedServers.isEmpty
                        ? "Connect a server to start your first session."
                        : "Start a new session on one of your connected servers."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(recentSessions) { thread in
                        Button {
                            Task { await onOpenRecentSession(thread) }
                        } label: {
                            recentSessionCard(thread)
                        }
                        .buttonStyle(.plain)
                        .disabled(openingRecentSessionKey != nil || isStartingNewSession)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTargetThread = thread
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectedServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Connected Servers", buttonTitle: "Connect Server", systemImage: "bolt.horizontal.circle", action: onConnectServer)

            if connectedServers.isEmpty {
                emptyStateCard(
                    title: "No connected servers",
                    message: "Use Connect Server to add a server and its sessions will appear here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(connectedServers) { connection in
                        Button {
                            onOpenServerSessions(connection)
                        } label: {
                            connectedServerRow(connection)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                disconnectTargetServer = connection
                            } label: {
                                Label("Disconnect Server", systemImage: "bolt.slash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(
        title: String,
        buttonTitle: String,
        systemImage: String,
        showsLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .litterFont(.headline)
                .foregroundColor(LitterTheme.textPrimary)

            Spacer(minLength: 0)

            Button(action: action) {
                Group {
                    if showsLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LitterTheme.accent)
                            .frame(width: 74)
                    } else {
                        Label(buttonTitle, systemImage: systemImage)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.accent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LitterTheme.surface.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(LitterTheme.border.opacity(0.7), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(showsLoading)
        }
    }

    private func recentSessionCard(_ thread: ThreadState) -> some View {
        let subtitle: String = {
            var parts = [thread.serverName]
            if let workspace = HomeDashboardSupport.workspaceLabel(for: thread) {
                parts.append(workspace)
            }
            return parts.joined(separator: " · ")
        }()

        let trailing: SessionServerCardRow.Trailing = {
            if openingRecentSessionKey == thread.key { return .none }
            if thread.hasTurnActive { return .badge("Thinking") }
            return .chevron
        }()

        return ZStack {
            SessionServerCardRow(
                icon: thread.hasTurnActive ? "sparkles" : "text.bubble",
                title: thread.sessionTitle,
                subtitle: subtitle,
                trailing: trailing
            )
            // Overlay loading spinner when opening.
            if openingRecentSessionKey == thread.key {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                }
                .padding(.trailing, 14)
            }
        }
        .accessibilityIdentifier("home.recentSessionCard")
    }

    private func connectedServerRow(_ connection: ServerConnection) -> some View {
        SessionServerCardRow(
            icon: connection.server.source == .local ? "iphone" : "server.rack",
            title: connection.server.name,
            subtitle: HomeDashboardSupport.serverSubtitle(for: connection.server),
            trailing: .status(connected: connection.isConnected)
        )
        .accessibilityIdentifier("home.connectedServerRow")
    }

    private func emptyStateCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .litterFont(.subheadline)
                .foregroundColor(LitterTheme.textPrimary)

            Text(message)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LitterTheme.surface.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(LitterTheme.border.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusBadge(_ title: String) -> some View {
        Text(title)
            .litterFont(.caption)
            .foregroundColor(LitterTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(LitterTheme.accent.opacity(0.14))
            .clipShape(Capsule())
    }

    private var metadataDivider: some View {
        Circle()
            .fill(LitterTheme.textMuted.opacity(0.7))
            .frame(width: 3, height: 3)
    }
}
