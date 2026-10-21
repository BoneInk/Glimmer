import Foundation

/// 工坊显式应用边界：复用导入服务的去重 UUID，只在导入成功后开始桌面播放。
@MainActor
enum WorkshopWallpaperApplication {
    static func apply(
        url: URL, metadata: WorkshopMetadata, target: WorkshopWallpaperTarget,
        currentDisplayID: String?, store: VideoLibraryStore, importer: ImportService,
        displays: DisplayRegistry, playback: DesktopPlaybackController
    ) async -> WorkshopWallpaperApplyResult {
        guard !Task.isCancelled else { return .failed("已取消设置壁纸") }
        let displayIDs: [String]?
        switch target {
        case .currentDisplay:
            guard let currentDisplayID, displays.descriptor(for: currentDisplayID) != nil else {
                return .failed("当前显示器不可用，请检查显示器连接")
            }
            displayIDs = [currentDisplayID]
        case .allDisplays:
            guard !displays.displays.isEmpty else { return .failed("没有可用显示器") }
            displayIDs = nil
        }
        let item: WallpaperItem
        switch await importItem(url: url, metadata: metadata, store: store, importer: importer) {
        case .success(let imported): item = imported
        case .failure(let error): return .failed(error.message)
        }
        guard !Task.isCancelled else { return .failed("已取消设置壁纸；视频仍保留在素材库中") }
        if let error = await playback.applyAndWait(item: item, to: displayIDs) { return .failed(error) }
        return .applied(target == .allDisplays ? "已设为全部显示器的壁纸" : "已设为当前显示器的壁纸")
    }

    /// 只导入/复用作品，不改变任何桌面或锁屏配置。
    static func importItem(url: URL, metadata: WorkshopMetadata, store: VideoLibraryStore,
                           importer: ImportService) async -> Result<WallpaperItem, WorkshopWallpaperImportError> {
        guard !Task.isCancelled else { return .failure(.init(message: "已取消导入")) }
        let importMetadata = ImportWorkshopMetadata(
            publishedFileID: metadata.publishedFileID, title: metadata.title,
            pageURLString: metadata.workshopURLString,
            previewImageURLString: metadata.previewImageURLString,
            authorSteamID: metadata.authorSteamID,
            fileByteSize: metadata.videoByteSize ?? metadata.projectByteSize ?? metadata.fileSizeBytes)
        let outcome: ImportWorkshopOutcome
        switch metadata.projectType.lowercased() {
        case "video": outcome = await importer.importWorkshopVideo(url, metadata: importMetadata)
        case "web":
            outcome = await importer.importWorkshopWeb(url, metadata: importMetadata,
                managedDownloadRoot: metadata.projectDirectoryURL)
        case "scene":
            outcome = await importer.importWorkshopScene(url, metadata: importMetadata,
                managedDownloadRoot: metadata.projectDirectoryURL)
        default: return .failure(.init(message: "此类作品尚未接入可运行的壁纸引擎"))
        }
        let itemID: UUID
        switch outcome {
        case .imported(let id), .duplicated(let id, _): itemID = id
        case .failed(let message): return .failure(.init(message: message))
        }
        guard !Task.isCancelled else { return .failure(.init(message: "已取消操作；已导入的壁纸仍保留在素材库中")) }
        guard let item = store.item(withID: itemID) else { return .failure(.init(message: "素材记录已不可用，请重新导入")) }
        return .success(item)
    }

}


struct WorkshopWallpaperImportError: Error, Sendable {
    var message: String
}
