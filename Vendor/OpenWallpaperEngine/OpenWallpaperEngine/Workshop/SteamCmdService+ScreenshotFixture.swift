#if DEBUG
import Foundation

extension SteamCmdService {
    /// The launch argument that fills the Downloads tab with sample rows, for screenshots of an
    /// isolated development copy (`OWE_ISOLATED_STATE`) without running steamcmd. Debug builds only.
    static let screenshotFixtureArgument = "-OWEDownloadsScreenshotFixture"

    /// One row per state, made from the wallpapers already in the Wallpaper Storage folder: one
    /// running, two queued, one failed with a steamcmd error, the rest finished.
    func loadScreenshotFixtureIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(Self.screenshotFixtureArgument), downloadProgress.isEmpty else { return }
        let folders: [URL]
        do {
            let storage = try WallpaperStorage.availableDirectory()
            folders = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
                .filter { WEProject.exists(in: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            OWELog.error(.workshop, "Downloads screenshot fixture: no Wallpaper Storage folder: \(error.localizedDescription)")
            return
        }
        let now = Date()
        for (index, folder) in folders.prefix(6).enumerated() {
            let id = String(3_000_000_000 + index * 7_919)
            let project = (try? WEProject.object(in: folder))
                as? [String: Any] ?? [:] // Optional: a fixture row without a title still shows its id.
            let title = project["title"] as? String ?? folder.lastPathComponent
            let preview = (project["preview"] as? String).map { folder.appending(path: $0) }
            downloadTitles[id] = title
            downloadItems[id] = DownloadItem(title: title, previewURL: preview, creatorId: nil,
                                             subscriptions: 1_200 * (index + 1), fileSize: 48_000_000 * (index + 1))
            switch index {
            case 0:
                activeDownloadId = id
                queuedDownloadIds.append(id)
                downloadStartedAt[id] = now.addingTimeInterval(-24)
                downloadPercentages[id] = 0.42
                downloadProgress[id] = .downloading(status: String(localized: "Downloading…", comment: "Download status"))
            case 1, 2:
                queuedDownloadIds.append(id)
                downloadPercentages[id] = 0
                downloadProgress[id] = .downloading(status: Self.queuedStatus)
            case 3:
                downloadStartedAt[id] = now.addingTimeInterval(-600)
                downloadProgress[id] = .failed("ERROR! Download item \(id) failed (Failure).")
            default:
                downloadStartedAt[id] = now.addingTimeInterval(-Double(1_200 * index))
                downloadFolders[id] = folder
                downloadProgress[id] = .completed
            }
        }
    }
}
#endif
