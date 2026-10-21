import SwiftUI

/// 侧边栏筛选项（F02 导航 + F10 过滤）。
enum LibraryFilter: Hashable, Identifiable, CaseIterable {
    case all
    case favorites
    case recent
    case source(WallpaperSource)
    case missing

    var id: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .recent: return "recent"
        case .source(let source): return "source-\(source.rawValue)"
        case .missing: return "missing"
        }
    }

    var title: String {
        switch self {
        case .all: return "全部壁纸"
        case .favorites: return "收藏"
        case .recent: return "最近使用"
        case .source(let source): return source.displayName
        case .missing: return "需要处理"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .favorites: return "star"
        case .recent: return "clock"
        case .source(let source): return source.symbolName
        case .missing: return "exclamationmark.triangle"
        }
    }

    static var allCases: [LibraryFilter] {
        [.all, .favorites, .recent, .source(.local), .source(.steamWorkshop), .missing]
    }
}

/// 排序方式（F10）。
enum LibrarySort: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded
    case recentlyPlayed
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "按名称"
        case .recentlyAdded: return "按导入时间"
        case .recentlyPlayed: return "按最近播放"
        case .duration: return "按时长"
        }
    }

    var symbolName: String {
        switch self {
        case .name: return "textformat.abc"
        case .recentlyAdded: return "arrow.down.circle"
        case .recentlyPlayed: return "play.circle"
        case .duration: return "timer"
        }
    }
}

/// 搜索与排序的计算逻辑单独放置，便于单元式自检（不依赖 UI）。
struct LibraryQuery: Sendable {
    var text: String = ""
    var filter: LibraryFilter = .all
    var sort: LibrarySort = .recentlyAdded
    var ascending: Bool = false

    func apply(to items: [WallpaperItem], missingIDs: Set<UUID> = []) -> [WallpaperItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = items

        // 过滤
        switch filter {
        case .all:
            break
        case .favorites:
            result = result.filter(\.isFavorite)
        case .recent:
            result = result.filter { $0.lastPlayedAt != nil }
        case .source(let source):
            result = result.filter { $0.source == source }
        case .missing:
            result = result.filter { missingIDs.contains($0.id) || !$0.fileExists }
        }

        // 搜索（标题、文件名、备注、工坊 ID）
        if !trimmed.isEmpty {
            let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            result = result.filter { item in
                let haystacks = [
                    item.title,
                    item.fileURL.lastPathComponent,
                    item.notes ?? "",
                    item.workshopID ?? ""
                ]
                return haystacks.contains { value in
                    value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
                        .contains(needle)
                }
            }
        }

        // 排序
        let sorted = result.sorted { lhs, rhs in
            switch sort {
            case .name:
                let comparison = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
                if comparison == .orderedSame { return lhs.addedAt > rhs.addedAt }
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            case .recentlyAdded:
                return ascending ? lhs.addedAt < rhs.addedAt : lhs.addedAt > rhs.addedAt
            case .recentlyPlayed:
                let lhsDate = lhs.lastPlayedAt ?? .distantPast
                let rhsDate = rhs.lastPlayedAt ?? .distantPast
                if lhsDate == rhsDate { return lhs.addedAt > rhs.addedAt }
                return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
            case .duration:
                let lhsDuration = lhs.durationSeconds ?? -1
                let rhsDuration = rhs.durationSeconds ?? -1
                if lhsDuration == rhsDuration { return lhs.addedAt > rhs.addedAt }
                return ascending ? lhsDuration < rhsDuration : lhsDuration > rhsDuration
            }
        }
        return sorted
    }

    /// 搜索结果为空时给出的可操作建议。
    func emptyStateMessage(isLibraryEmpty: Bool) -> String {
        if isLibraryEmpty {
            return "素材库还没有视频壁纸。\n点击工具栏「导入」或把视频文件拖到列表里即可开始。"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "没有匹配「\(trimmed)」的壁纸。\n可以换个关键词，或清除搜索条件。"
        }
        switch filter {
        case .favorites:
            return "还没有收藏任何壁纸。\n在卡片或详情面板点击星标即可收藏。"
        case .recent:
            return "还没有播放记录。\n选择一个壁纸并点击「应用到桌面」后就会出现在这里。"
        case .source(.steamWorkshop):
            return "还没有来自 Steam 创意工坊的素材。\n点击工具栏「创意工坊」查找视频，登录 Steam 后下载到素材库。"
        case .source(.local):
            return "还没有本地导入的素材。\n点击工具栏「导入」或拖入视频文件。"
        case .missing:
            return "所有素材文件都能正常访问，暂无需要处理的项目。"
        case .all:
            return "当前筛选条件下没有素材。"
        }
    }
}
