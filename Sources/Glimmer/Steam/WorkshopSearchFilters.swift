import Foundation

/// Whitelist from Steam app 431960's public ready-to-use tag metadata (2026-10-18).
/// These are required tags sent to Steam, never local result approximations.
/// Portrait/ultrawide/multiple monitors are Steam Resolution tags; there is no
/// independent aspect-ratio parameter. Age tags do not alter Steam content settings.
struct WorkshopSearchFilters: Equatable, Sendable {
    /// Empty means every type. Multiple values are an OR across separate Steam
    /// requests; the remaining tags stay AND-ed inside every request.
    var types: Set<WorkshopSearchType>
    var resolution: WorkshopResolution? = nil
    var genre: WorkshopGenre? = nil
    var ageRating: WorkshopAgeRating? = nil
    /// Main-layer ranking control, separate from required-tag filter chips.
    var trendPeriod: WorkshopTrendPeriod = .week

    init(type: WorkshopSearchType = .video,
         resolution: WorkshopResolution? = nil,
         genre: WorkshopGenre? = nil,
         ageRating: WorkshopAgeRating? = nil,
         trendPeriod: WorkshopTrendPeriod = .week) {
        types = type == .all ? [] : [type]
        self.resolution = resolution
        self.genre = genre
        self.ageRating = ageRating
        self.trendPeriod = trendPeriod
    }

    init(types: Set<WorkshopSearchType>,
         resolution: WorkshopResolution? = nil,
         genre: WorkshopGenre? = nil,
         ageRating: WorkshopAgeRating? = nil,
         trendPeriod: WorkshopTrendPeriod = .week) {
        self.types = Set(types.filter { $0 != .all })
        self.resolution = resolution
        self.genre = genre
        self.ageRating = ageRating
        self.trendPeriod = trendPeriod
    }

    /// Source-compatible bridge for existing single-type callers.
    var type: WorkshopSearchType {
        get { types.count == 1 ? types.first! : .all }
        set { types = newValue == .all ? [] : [newValue] }
    }

    var orderedTypes: [WorkshopSearchType] {
        WorkshopSearchType.selectableCases.filter(types.contains)
    }

    var requiredTags: [String] {
        [resolution?.rawValue, genre?.rawValue, ageRating?.rawValue].compactMap { $0 }
    }
    var activeCount: Int { requiredTags.count + (types == [.video] ? 0 : 1) }
    var isEmpty: Bool { activeCount == 0 }
    var activeLabels: [String] {
        (types == [.video] ? [] : ["类型：" + (types.isEmpty ? "全部类型" : orderedTypes.map(\.title).joined(separator: "、"))]) + [resolution.map { "分辨率：" + $0.title }, genre.map { "分类：" + $0.title },
         ageRating.map { "年龄分级：" + $0.title }].compactMap { $0 }
    }
}

enum WorkshopSearchType: String, CaseIterable, Identifiable, Sendable, Hashable {
    case video, web, scene, all
    var id: String { rawValue }
    static let selectableCases: [WorkshopSearchType] = [.video, .web, .scene]
    var title: String { switch self { case .video: "视频"; case .web: "Web"; case .scene: "Scene"; case .all: "全部类型" } }
    var requiredTag: String? { switch self { case .video: "Video"; case .web: "Web"; case .scene: "Scene"; case .all: nil } }
    func includes(_ result: WorkshopSearchResult) -> Bool {
        guard !result.isCollection, result.childCount == 0, result.declaredKind != .collection else { return false }
        switch self { case .video: return result.declaredKind == .video; case .web: return result.declaredKind == .web; case .scene: return result.declaredKind == .scene; case .all: return true }
    }
}

enum WorkshopResolution: String, CaseIterable, Identifiable, Sendable {
    case standardDefinition = "Standard Definition"
    case size1280X720 = "1280 x 720"
    case size1366X768 = "1366 x 768"
    case size1920X1080 = "1920 x 1080"
    case size2560X1440 = "2560 x 1440"
    case size3840X2160 = "3840 x 2160"
    case ultrawideStandardDefinition = "Ultrawide Standard Definition"
    case ultrawide2560X1080 = "Ultrawide 2560 x 1080"
    case ultrawide3440X1440 = "Ultrawide 3440 x 1440"
    case dualStandardDefinition = "Dual Standard Definition"
    case dual3840X1080 = "Dual 3840 x 1080"
    case dual5120X1440 = "Dual 5120 x 1440"
    case dual7680X2160 = "Dual 7680 x 2160"
    case tripleStandardDefinition = "Triple Standard Definition"
    case triple4096X768 = "Triple 4096 x 768"
    case triple5760X1080 = "Triple 5760 x 1080"
    case triple7680X1440 = "Triple 7680 x 1440"
    case triple11520X2160 = "Triple 11520 x 2160"
    case portraitStandardDefinition = "Portrait Standard Definition"
    case portrait720X1280 = "Portrait 720 x 1280"
    case portrait1080X1920 = "Portrait 1080 x 1920"
    case portrait1440X2560 = "Portrait 1440 x 2560"
    case portrait2160X3840 = "Portrait 2160 x 3840"
    case otherResolution = "Other resolution"
    case dynamicResolution = "Dynamic resolution"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standardDefinition: return "标准清晰度"
        case .size1280X720: return "1280 × 720"
        case .size1366X768: return "1366 × 768"
        case .size1920X1080: return "1920 × 1080"
        case .size2560X1440: return "2560 × 1440"
        case .size3840X2160: return "3840 × 2160 · 4K"
        case .ultrawideStandardDefinition: return "超宽屏 · 标准清晰度"
        case .ultrawide2560X1080: return "超宽屏 · 2560 × 1080"
        case .ultrawide3440X1440: return "超宽屏 · 3440 × 1440"
        case .dualStandardDefinition: return "双屏 · 标准清晰度"
        case .dual3840X1080: return "双屏 · 3840 × 1080"
        case .dual5120X1440: return "双屏 · 5120 × 1440"
        case .dual7680X2160: return "双屏 · 7680 × 2160"
        case .tripleStandardDefinition: return "三屏 · 标准清晰度"
        case .triple4096X768: return "三屏 · 4096 × 768"
        case .triple5760X1080: return "三屏 · 5760 × 1080"
        case .triple7680X1440: return "三屏 · 7680 × 1440"
        case .triple11520X2160: return "三屏 · 11520 × 2160"
        case .portraitStandardDefinition: return "竖屏 · 标准清晰度"
        case .portrait720X1280: return "竖屏 · 720 × 1280"
        case .portrait1080X1920: return "竖屏 · 1080 × 1920"
        case .portrait1440X2560: return "竖屏 · 1440 × 2560"
        case .portrait2160X3840: return "竖屏 · 2160 × 3840"
        case .otherResolution: return "其他分辨率"
        case .dynamicResolution: return "动态分辨率"
        }
    }
}

enum WorkshopGenre: String, CaseIterable, Identifiable, Sendable {
    case abstract = "Abstract"
    case animal = "Animal"
    case anime = "Anime"
    case cartoon = "Cartoon"
    case cgi = "CGI"
    case cyberpunk = "Cyberpunk"
    case fantasy = "Fantasy"
    case game = "Game"
    case girls = "Girls"
    case guys = "Guys"
    case landscape = "Landscape"
    case medieval = "Medieval"
    case memes = "Memes"
    case mmd = "MMD"
    case music = "Music"
    case nature = "Nature"
    case pixelArt = "Pixel art"
    case relaxing = "Relaxing"
    case retro = "Retro"
    case sciFi = "Sci-Fi"
    case sports = "Sports"
    case technology = "Technology"
    case television = "Television"
    case vehicle = "Vehicle"
    case unspecified = "Unspecified"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .abstract: return "抽象"
        case .animal: return "动物"
        case .anime: return "动漫"
        case .cartoon: return "卡通"
        case .cgi: return "CGI"
        case .cyberpunk: return "赛博朋克"
        case .fantasy: return "奇幻"
        case .game: return "游戏"
        case .girls: return "女生"
        case .guys: return "男生"
        case .landscape: return "风景"
        case .medieval: return "中世纪"
        case .memes: return "表情梗图"
        case .mmd: return "MMD"
        case .music: return "音乐"
        case .nature: return "自然"
        case .pixelArt: return "像素艺术"
        case .relaxing: return "放松"
        case .retro: return "复古"
        case .sciFi: return "科幻"
        case .sports: return "运动"
        case .technology: return "科技"
        case .television: return "电视"
        case .vehicle: return "车辆"
        case .unspecified: return "未指定"
        }
    }
}

enum WorkshopAgeRating: String, CaseIterable, Identifiable, Sendable {
    case everyone = "Everyone"
    case questionable = "Questionable"
    case mature = "Mature"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyone: return "全年龄"
        case .questionable: return "有争议内容"
        case .mature: return "成人内容"
        }
    }
}


/// Steam uses rolling days, not calendar day/week/month/year boundaries.
enum WorkshopTrendPeriod: Int, CaseIterable, Identifiable, Sendable {
    case day = 1, week = 7, month = 30, year = 365, all = 0
    var id: Int { rawValue }
    var title: String { switch self { case .day: "今日"; case .week: "本周"; case .month: "本月"; case .year: "今年"; case .all: "全部" } }
    var urlDays: Int { self == .all ? -1 : rawValue }
    var detail: String { self == .all ? "Steam 全部时间热榜" : "Steam 最近\(rawValue)天热榜，按滚动时间计算" }
}
