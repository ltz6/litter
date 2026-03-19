import SwiftUI

struct AccountView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(\.dismiss) private var dismiss

    private var connection: ServerConnection? {
        serverManager.activeConnection ?? serverManager.connections.values.first(where: { $0.isConnected })
    }

    var body: some View {
        if let connection {
            AccountConnectionView(connection: connection, dismiss: dismiss)
        } else {
            AccountDisconnectedView(dismiss: dismiss)
        }
    }
}

private struct AccountConnectionView: View {
    let connection: ServerConnection
    let dismiss: DismissAction

    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var errorMsg: String?

    private var authStatus: AuthStatus {
        connection.authStatus
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        currentAccountSection
                        Divider().background(LitterTheme.surfaceLight)
                        loginSection
                        if let err = errorMsg {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .oauthLoginPresenter(connection: connection)
    }

    private var currentAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT ACCOUNT")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Circle()
                    .fill(authColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    if let sub = authSubtitle {
                        Text(sub)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                Spacer()
                if authStatus != .notLoggedIn && authStatus != .unknown {
                    Button("Logout") {
                        Task { await connection.logout() }
                    }
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .padding(.horizontal, 16)
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LOGIN")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            Button {
                Task {
                    isWorking = true
                    errorMsg = nil
                    await connection.loginWithChatGPT()
                    isWorking = false
                }
            } label: {
                HStack {
                    if isWorking {
                        ProgressView().tint(LitterTheme.textOnAccent).scaleEffect(0.8)
                    }
                    Image(systemName: "person.crop.circle.badge.checkmark")
                    Text("Login with ChatGPT")
                        .litterFont(.subheadline)
                }
                .foregroundColor(LitterTheme.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LitterTheme.accent)
                .cornerRadius(10)
            }
            .padding(.horizontal, 16)
            .disabled(isWorking)

            Text("— or use an API key —")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                SecureField("sk-...", text: $apiKey)
                    .litterFont(.subheadline)
                    .foregroundColor(LitterTheme.textPrimary)
                    .padding(12)
                    .background(LitterTheme.surface)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)

                Button {
                    let key = apiKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    Task {
                        isWorking = true
                        errorMsg = nil
                        await connection.loginWithApiKey(key)
                        isWorking = false
                        if case .apiKey = connection.authStatus {
                            dismiss()
                        }
                    }
                } label: {
                    Text("Save API Key")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(LitterTheme.accent.opacity(0.4), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 16)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    private var authColor: Color {
        switch authStatus {
        case .chatgpt: return LitterTheme.accent
        case .apiKey: return Color(hex: "#00AAFF")
        case .notLoggedIn, .unknown: return LitterTheme.textMuted
        }
    }

    private var authTitle: String {
        switch authStatus {
        case .chatgpt(let email): return email.isEmpty ? "ChatGPT" : email
        case .apiKey: return "API Key"
        case .notLoggedIn: return "Not logged in"
        case .unknown: return "Checking…"
        }
    }

    private var authSubtitle: String? {
        switch authStatus {
        case .chatgpt: return "ChatGPT account"
        case .apiKey: return "OpenAI API key"
        default: return nil
        }
    }
}

private struct AccountDisconnectedView: View {
    let dismiss: DismissAction

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Connect to a server first")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text("Account settings are tied to the active server connection.")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Account") {
    LitterPreviewScene(includeBackground: false) {
        AccountView()
    }
}
#endif
