import Foundation

enum WallpaperContentKind: String, Codable, Sendable {
    case video, web, scene
}

/// 素材来源。v1 只处理本地文件与 Steam 创意工坊两类视频素材。
enum WallpaperSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case steamWorkshop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本地文件"
        case .steamWorkshop: return "Steam 创意工坊"
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "folder"
        case .steamWorkshop: return "storefront"
        }
    }
}

/// 视频画面适配方式。
enum VideoGravityMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "填充"
        }
    }

    var shortName: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "填满"
        }
    }
}

/// Built-in video controls, independent of author-defined Web/Scene properties.
/// Pause remains a display/user intent and is deliberately not stored per wallpaper.
struct VideoPlaybackPreferences: Codable, Hashable, Sendable {
    var isMuted: Bool
    var volume: Double
    var rate: Double
    var gravity: VideoGravityMode

    init(isMuted: Bool = true, volume: Double = 1, rate: Double = 1, gravity: VideoGravityMode = .fill) {
        self.isMuted = isMuted
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
        self.rate = rate.isFinite ? min(max(rate, 0.25), 4) : 1
        self.gravity = gravity
    }

    init(settings: DisplayPlaybackSettings) {
        self.init(isMuted: settings.isMuted, volume: settings.volume, rate: settings.rate, gravity: settings.gravity)
    }

    var normalized: Self {
        Self(isMuted: isMuted, volume: volume, rate: rate, gravity: gravity)
    }

    func applying(to displaySettings: DisplayPlaybackSettings) -> DisplayPlaybackSettings {
        let preferences = normalized
        var effective = displaySettings
        effective.isMuted = preferences.isMuted
        effective.volume = preferences.volume
        effective.rate = preferences.rate
        effective.gravity = preferences.gravity
        return effective
    }
}

/// 素材库中的一条视频壁纸记录。
///
/// 约定：`filePath` 指向应用管理目录内的副本（本地导入时由 ImportService 复制），
/// 原始文件永远不被移动或删除；`originalPath` 仅用于「定位原始文件」与重链接。
struct WallpaperItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    /// 应用管理目录内的媒体文件路径。
    var filePath: String
    /// 用户导入时的原始路径（可能已被移动/删除）。
    var originalPath: String?
    var source: WallpaperSource
    var isFavorite: Bool
    var addedAt: Date
    var lastPlayedAt: Date?
    var fileSizeBytes: Int64
    var contentFingerprint: String?
    var durationSeconds: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var hasAudioTrack: Bool
    /// 导入时的源文件修改时间，用于判断外部变化。
    var sourceModifiedAt: Date?
    /// Steam 创意工坊作品 ID（本地素材为 nil）。
    var workshopID: String?
    var notes: String?
    /// Nil inherits the display defaults. Optional decoding preserves older libraries.
    var videoPlaybackPreferences: VideoPlaybackPreferences?
    /// Missing in legacy libraries means video. Web records point at project.json.
    var contentKind: WallpaperContentKind?

    init(
        id: UUID = UUID(),
        title: String,
        filePath: String,
        originalPath: String? = nil,
        source: WallpaperSource = .local,
        isFavorite: Bool = false,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        fileSizeBytes: Int64 = 0,
        contentFingerprint: String? = nil,
        durationSeconds: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        frameRate: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        hasAudioTrack: Bool = false,
        sourceModifiedAt: Date? = nil,
        workshopID: String? = nil,
        notes: String? = nil,
        videoPlaybackPreferences: VideoPlaybackPreferences? = nil,
        contentKind: WallpaperContentKind? = nil
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.originalPath = originalPath
        self.source = source
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.fileSizeBytes = fileSizeBytes
        self.contentFingerprint = contentFingerprint
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hasAudioTrack = hasAudioTrack
        self.sourceModifiedAt = sourceModifiedAt
        self.workshopID = workshopID
        self.notes = notes
        self.videoPlaybackPreferences = videoPlaybackPreferences?.normalized
        self.contentKind = contentKind
    }

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var isWebWallpaper: Bool { contentKind == .web }
    var isSceneWallpaper: Bool { contentKind == .scene }
    var isProjectWallpaper: Bool { isWebWallpaper || isSceneWallpaper }
    var isVideoWallpaper: Bool { contentKind == nil || contentKind == .video }
    var originalURL: URL? { originalPath.map { URL(fileURLWithPath: $0) } }

    var fileExists: Bool { FileManager.default.fileExists(atPath: filePath) }
    var originalExists: Bool { originalPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    var durationText: String {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return "—" }
        return Self.formatDuration(durationSeconds)
    }

    var resolutionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    var fileSizeText: String {
        guard fileSizeBytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var frameRateText: String {
        guard let frameRate, frameRate > 0 else { return "—" }
        return String(format: "%.2f fps", frameRate)
    }

    var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var addedAtText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: addedAt)
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 展示用短标题（用于网格卡片与菜单）。
    var displayTitle: String {
        title.isEmpty ? fileURL.lastPathComponent : title
    }
}
