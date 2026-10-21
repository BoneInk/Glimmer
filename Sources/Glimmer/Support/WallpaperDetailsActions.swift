import Foundation
import Observation

@MainActor
enum WallpaperDetailsActions {
    /// 只移除记录：先持久化，再停止该作品的会话及挂起分配，不删除任何原文件。
    static func removeRecord(itemID: UUID, store: VideoLibraryStore, playback: DesktopPlaybackController) throws {
        try store.removePersistedItems(ids: [itemID])
        playback.discardDeletedWallpaperSessions(itemIDs: [itemID])
    }
}

/// 详情内容的选择，不缓存 WallpaperItem 快照。
@MainActor
@Observable
final class WallpaperDetailsSelection {
    var itemID: UUID
    init(itemID: UUID) { self.itemID = itemID }
}
