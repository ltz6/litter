import SwiftUI

/// Displays either the user's chosen wallpaper image or the default theme gradient.
struct ChatWallpaperBackground: View {
    @Environment(WallpaperManager.self) private var wallpaperManager

    var body: some View {
        if let image = wallpaperManager.wallpaperImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        } else {
            LitterTheme.backgroundGradient.ignoresSafeArea()
        }
    }
}
