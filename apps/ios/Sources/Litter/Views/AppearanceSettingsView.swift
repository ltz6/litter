import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Form {
                conversationPreviewSection
                lightThemeSection
                darkThemeSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Conversation Preview

    private var conversationPreviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                UserBubble(text: "Hey clanker, why is prod on fire", compact: true)

                ToolCallCardView(model: ToolCallCardModel(
                    kind: .commandExecution,
                    title: "Command",
                    summary: "rg 'TODO: fix later' --count",
                    status: .completed,
                    duration: "0.3s",
                    sections: []
                ))

                AssistantBubble(
                    text: """
                    Found the issue. Someone deployed this:

                    ```python
                    if is_friday():
                        yolo_deploy(skip_tests=True)
                    ```
                    I'm not mad, just disappointed.
                    """,
                    compact: true
                )

                UserBubble(text: "That was you, clanker", compact: true)
            }
            .padding(.vertical, 6)
            .id(themeManager.themeVersion)
            .listRowBackground(LitterTheme.backgroundGradient)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        } header: {
            Text("Preview")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Light Theme

    private var lightThemeSection: some View {
        Section {
            themePicker(
                themes: themeManager.lightThemes,
                selectedSlug: themeManager.selectedLightSlug
            ) { slug in
                themeManager.selectLightTheme(slug)
            }
        } header: {
            Text("Light theme")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Dark Theme

    private var darkThemeSection: some View {
        Section {
            themePicker(
                themes: themeManager.darkThemes,
                selectedSlug: themeManager.selectedDarkSlug
            ) { slug in
                themeManager.selectDarkTheme(slug)
            }
        } header: {
            Text("Dark theme")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Theme Picker

    private func themePicker(
        themes: [ThemeIndexEntry],
        selectedSlug: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let selected = themes.first(where: { $0.slug == selectedSlug }) ?? themes.first
        return Menu {
            ForEach(themes) { entry in
                Button {
                    onSelect(entry.slug)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(uiImage: ThemePreviewBadge.renderToImage(
                            backgroundHex: entry.backgroundHex,
                            foregroundHex: entry.foregroundHex,
                            accentHex: entry.accentHex
                        ))
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                ThemePreviewBadge(
                    backgroundHex: selected?.backgroundHex ?? "#000",
                    foregroundHex: selected?.foregroundHex ?? "#FFF",
                    accentHex: selected?.accentHex ?? "#0F0"
                )
                Text(selected?.name ?? "")
                    .font(LitterFont.styled(.subheadline))
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }
}

// MARK: - Theme Preview Badge

struct ThemePreviewBadge: View {
    let backgroundHex: String
    let foregroundHex: String
    let accentHex: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text("Aa")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: foregroundHex))
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: backgroundHex))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
            Circle()
                .fill(Color(hex: accentHex))
                .frame(width: 6, height: 6)
                .offset(x: 1, y: 1)
        }
    }

    @MainActor
    static func renderToImage(backgroundHex: String, foregroundHex: String, accentHex: String) -> UIImage {
        let badge = ThemePreviewBadge(backgroundHex: backgroundHex, foregroundHex: foregroundHex, accentHex: accentHex)
        let renderer = ImageRenderer(content: badge)
        renderer.scale = UIScreen.main.scale
        guard let cgImage = renderer.cgImage else { return UIImage() }
        return UIImage(cgImage: cgImage).withRenderingMode(.alwaysOriginal)
    }
}

#if DEBUG
#Preview("Appearance") {
    NavigationStack {
        AppearanceSettingsView()
    }
}
#endif
