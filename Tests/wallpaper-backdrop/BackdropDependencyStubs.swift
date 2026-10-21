import AppKit
import Observation
struct DisplayDescriptor: Equatable { let id: String; let displayID: UInt32 }
@MainActor @Observable final class DisplayRegistry { var displays: [DisplayDescriptor] = []; var primary: DisplayDescriptor? { displays.first } }
@MainActor @Observable final class DesktopPlaybackController { var sessions: [String: DesktopPlaybackSession] = [:]; func session(for id: String) -> DesktopPlaybackSession? { sessions[id] } }
struct WallpaperItem { let id: UUID; let fileURL: URL; var isWebWallpaper: Bool { fileURL.pathExtension == "json" }; var isSceneWallpaper: Bool { false }; var isVideoWallpaper: Bool { !isWebWallpaper } }
@MainActor @Observable final class DesktopPlaybackSession { var webRuntime: WebWallpaperRuntime?; var sceneRuntime: SceneWallpaperRuntime?; let item: WallpaperItem; init(item: WallpaperItem) { self.item = item } }

struct WebWallpaperProjectDescriptor {
    let projectURL: URL
    let posterURL: URL?

    init(projectURL: URL) throws {
        let data = try Data(contentsOf: projectURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String)?.lowercased() == "web",
              let preview = object["preview"] as? String, !preview.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.projectURL = projectURL
        let candidate = projectURL.deletingLastPathComponent().appendingPathComponent(preview)
        posterURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
struct AppStorage {
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-test-storage-\(UUID().uuidString)", isDirectory: true)
    }
    init(root: URL) { self.root = root }
    func thumbnailURL(for id: UUID) -> URL {
        root.appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).jpg")
    }
}

@MainActor @Observable final class SceneWallpaperRuntime { enum State: String { case idle, ready, paused }; var state: State = .idle; var posterImage: CGImage? }
