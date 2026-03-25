import SwiftUI
import Observation

@MainActor
@Observable
final class WallpaperManager {
    @MainActor static let shared = WallpaperManager()

    private(set) var wallpaperImage: UIImage?
    private(set) var isWallpaperSet: Bool = false

    @ObservationIgnored
    private static let customFileName = "custom_wallpaper.jpg"

    @ObservationIgnored
    private static var customFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(customFileName)
    }

    private init() {
        let key = UserDefaults.standard.string(forKey: "chatWallpaper") ?? "none"
        let (image, isSet) = Self.resolveWallpaper(for: key)
        self.wallpaperImage = image
        self.isWallpaperSet = isSet
    }

    // MARK: - Public

    func setCustom(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: Self.customFileURL, options: .atomic)
        UserDefaults.standard.set("custom", forKey: "chatWallpaper")
        wallpaperImage = image
        isWallpaperSet = true
    }

    func clear() {
        UserDefaults.standard.set("none", forKey: "chatWallpaper")
        wallpaperImage = nil
        isWallpaperSet = false
        try? FileManager.default.removeItem(at: Self.customFileURL)
    }

    // MARK: - Private

    private static func resolveWallpaper(for key: String) -> (UIImage?, Bool) {
        switch key {
        case "none":
            return (nil, false)
        case "custom":
            return (UIImage(contentsOfFile: customFileURL.path), true)
        default:
            return (UIImage(named: key), true)
        }
    }
}
