import SwiftUI

struct WallpaperAdjustView: View {
    @Environment(WallpaperManager.self) private var wallpaperManager
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let threadKey: ThreadKey

    @State private var isBlurred: Bool = false
    @State private var motionEnabled: Bool = false
    @State private var brightness: Double = 1.0
    @State private var hasLoaded = false

    private var currentConfig: WallpaperConfig? {
        wallpaperManager.resolveConfig(for: threadKey)
    }

    var body: some View {
        ZStack {
            // Full-screen live preview
            wallpaperPreview
                .blur(radius: isBlurred ? brightness * 20 : 0)
                .opacity(brightness)
                .ignoresSafeArea()

            // Sample bubbles
            sampleBubbles
                .padding(.top, 80)
                .padding(.bottom, 280)

            // Bottom controls
            VStack {
                Spacer()
                controlsCard
            }
        }
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Adjust Wallpaper")
                    .litterFont(size: 16, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            if let config = currentConfig {
                isBlurred = config.blur > 0.01
                motionEnabled = config.motionEnabled
                brightness = config.brightness
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var wallpaperPreview: some View {
        if let config = currentConfig {
            switch config.type {
            case .theme:
                if let slug = config.themeSlug,
                   let image = wallpaperManager.generateWallpaper(themeSlug: slug, themeManager: themeManager) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .customImage:
                if let image = wallpaperManager.wallpaperImage(for: config, scope: .thread(threadKey), themeManager: themeManager) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .solidColor:
                if let hex = config.colorHex {
                    Color(hex: hex)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .none:
                LitterTheme.backgroundGradient
            }
        } else {
            LitterTheme.backgroundGradient
        }
    }

    // MARK: - Sample Bubbles

    private var sampleBubbles: some View {
        VStack(spacing: 12) {
            Spacer()
            HStack {
                Spacer()
                Text("Refactor the auth middleware")
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(GlassRectModifier(cornerRadius: 14, tint: LitterTheme.accent.opacity(0.3)))
            }
            .padding(.horizontal, 16)

            HStack {
                Text("I'll review the auth middleware and refactor it for better separation of concerns.")
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(GlassRectModifier(cornerRadius: 14))
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    // MARK: - Controls Card

    private var controlsCard: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LitterTheme.textMuted.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            // Toggles
            HStack(spacing: 24) {
                toggleOption(label: "Blurred", isOn: $isBlurred)
                toggleOption(label: "Motion", isOn: $motionEnabled)
            }
            .padding(.horizontal, 16)

            // Brightness slider
            HStack(spacing: 12) {
                Image(systemName: "sun.min")
                    .font(.system(size: 14))
                    .foregroundStyle(LitterTheme.textMuted)
                Slider(value: $brightness, in: 0.2...1.0)
                    .tint(LitterTheme.accent)
                Image(systemName: "sun.max")
                    .font(.system(size: 14))
                    .foregroundStyle(LitterTheme.textPrimary)
            }
            .padding(.horizontal, 16)

            // Apply buttons
            VStack(spacing: 10) {
                Button {
                    applyWallpaper(scope: .thread(threadKey))
                } label: {
                    Text("Apply for This Thread")
                        .litterFont(size: 15, weight: .semibold)
                        .foregroundStyle(LitterTheme.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LitterTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    applyWallpaper(scope: .server(threadKey.serverId))
                } label: {
                    Text("Apply for This Server")
                        .litterFont(size: 15, weight: .medium)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .modifier(GlassRectModifier(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 16)

            Spacer().frame(height: 16)
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(LitterTheme.surface.opacity(0.95))
        )
    }

    private func toggleOption(label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn.wrappedValue ? LitterTheme.accent : LitterTheme.textMuted)
                Text(label)
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
    }

    // MARK: - Apply

    private func applyWallpaper(scope: WallpaperScope) {
        guard var config = currentConfig else { return }
        config.blur = isBlurred ? 0.5 : 0.0
        config.brightness = brightness
        config.motionEnabled = motionEnabled
        wallpaperManager.setWallpaper(config, scope: scope)
        dismiss()
    }
}
