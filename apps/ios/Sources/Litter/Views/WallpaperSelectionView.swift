import SwiftUI
import PhotosUI

struct WallpaperSelectionView: View {
    @Environment(WallpaperManager.self) private var wallpaperManager
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let threadKey: ThreadKey
    var onSelectWallpaper: (() -> Void)?

    @State private var selectedThemeSlug: String?
    @State private var selectedColor: Color?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var customImage: UIImage?
    @State private var previewConfig: WallpaperConfig?

    var body: some View {
        ZStack {
            // Full-screen preview background
            wallpaperPreview
                .ignoresSafeArea()

            // Sample bubbles overlay
            sampleBubbles
                .padding(.top, 80)
                .padding(.bottom, 300)

            // Bottom card
            VStack {
                Spacer()
                bottomCard
            }
        }
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Select Wallpaper")
                    .litterFont(size: 16, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
    }

    // MARK: - Preview Background

    @ViewBuilder
    private var wallpaperPreview: some View {
        if let config = previewConfig {
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
            case .solidColor:
                if let hex = config.colorHex {
                    Color(hex: hex)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .customImage:
                if let customImage {
                    Image(uiImage: customImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .none:
                LitterTheme.backgroundGradient
            }
        } else {
            ChatWallpaperBackground(threadKey: threadKey)
        }
    }

    // MARK: - Sample Bubbles

    private var sampleBubbles: some View {
        VStack(spacing: 12) {
            Spacer()
            // User bubble
            HStack {
                Spacer()
                Text("Fix the login bug on the profile page")
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(GlassRectModifier(cornerRadius: 14, tint: LitterTheme.accent.opacity(0.3)))
            }
            .padding(.horizontal, 16)

            // Assistant bubble
            HStack {
                Text("I'll look at the profile page login flow and fix the issue.")
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

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 16) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(LitterTheme.textMuted.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            Text("Select Theme")
                .litterFont(size: 16, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            // Theme thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // No Wallpaper option
                    noWallpaperThumbnail

                    // Theme-derived thumbnails
                    ForEach(themeManager.themeIndex) { entry in
                        themeThumbnail(for: entry)
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider().overlay(LitterTheme.separator)

            // Photos picker
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 16))
                        .foregroundStyle(LitterTheme.accent)
                    Text("Choose Wallpaper from Photos")
                        .litterFont(size: 14)
                        .foregroundStyle(LitterTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selectedPhoto) { _, newItem in
                Task { await loadPhoto(newItem) }
            }

            // Color picker
            colorRow

            Spacer().frame(height: 16)
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(LitterTheme.surface.opacity(0.95))
        )
    }

    // MARK: - Thumbnails

    private var noWallpaperThumbnail: some View {
        Button {
            previewConfig = WallpaperConfig(type: .none)
            selectedThemeSlug = nil
            selectedColor = nil
            customImage = nil
            // Apply immediately
            wallpaperManager.setWallpaper(WallpaperConfig(type: .none), scope: .thread(threadKey))
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LitterTheme.surface)
                        .frame(width: 68, height: 100)
                    Image(systemName: "xmark")
                        .font(.system(size: 18))
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selectedThemeSlug == nil && previewConfig?.type == .none ? LitterTheme.accent : LitterTheme.border, lineWidth: 2)
                )

                Text("None")
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func themeThumbnail(for entry: ThemeIndexEntry) -> some View {
        Button {
            selectedThemeSlug = entry.slug
            selectedColor = nil
            customImage = nil
            previewConfig = WallpaperConfig(type: .theme, themeSlug: entry.slug)
            onSelectWallpaper?()
        } label: {
            VStack(spacing: 6) {
                Image(uiImage: wallpaperManager.generateThumbnail(for: entry))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 68, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedThemeSlug == entry.slug ? LitterTheme.accent : LitterTheme.border, lineWidth: 2)
                    )

                Text(entry.name)
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
        }
    }

    // MARK: - Color Picker

    private var colorRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintpalette")
                .font(.system(size: 16))
                .foregroundStyle(LitterTheme.accent)
            Text("Set a Color")
                .litterFont(size: 14)
                .foregroundStyle(LitterTheme.textPrimary)
            Spacer()

            ColorPicker("", selection: Binding(
                get: { selectedColor ?? .black },
                set: { color in
                    selectedColor = color
                    selectedThemeSlug = nil
                    customImage = nil
                    let hex = colorToHex(color)
                    previewConfig = WallpaperConfig(type: .solidColor, colorHex: hex)
                    onSelectWallpaper?()
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Helpers

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            customImage = image
            selectedThemeSlug = nil
            selectedColor = nil
            previewConfig = WallpaperConfig(type: .customImage)
            wallpaperManager.setCustomImage(image, scope: .thread(threadKey))
            onSelectWallpaper?()
        }
    }

    private func colorToHex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
