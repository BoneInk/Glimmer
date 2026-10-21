import Foundation

enum GWLockScreenProjectPlayback: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, recorded
    var id: String { rawValue }
    var title: String { self == .live ? "实时渲染" : "录制视频" }
}

enum GWLockScreenExportResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, hd720, fullHD1080, qhd1440, uhd2160

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原始分辨率"
        case .hd720: "720p"
        case .fullHD1080: "1080p"
        case .qhd1440: "1440p（2K）"
        case .uhd2160: "2160p（4K）"
        }
    }
    var longEdge: Int? {
        switch self {
        case .original: nil
        case .hd720: 1280
        case .fullHD1080: 1920
        case .qhd1440: 2560
        case .uhd2160: 3840
        }
    }
}

/// Zero FPS means source timing. Manual values survive toggling synchronization.
struct GWLockScreenExportSettings: Codable, Equatable, Sendable {
    var projectPlayback: GWLockScreenProjectPlayback = .live
    var allowWebHTTPS = false
    var syncWallpaperSettings = true
    var resolution: GWLockScreenExportResolution = .fullHD1080
    var framesPerSecond: Int = 30 {
        didSet { framesPerSecond = min(max(framesPerSecond, 0), 240) }
    }

    init(syncWallpaperSettings: Bool = true,
         resolution: GWLockScreenExportResolution = .fullHD1080, framesPerSecond: Int = 30,
         projectPlayback: GWLockScreenProjectPlayback = .live, allowWebHTTPS: Bool = false) {
        self.syncWallpaperSettings = syncWallpaperSettings
        self.resolution = resolution
        self.framesPerSecond = min(max(framesPerSecond, 0), 240)
        self.projectPlayback = projectPlayback
        self.allowWebHTTPS = allowWebHTTPS
    }

    private enum CodingKeys: CodingKey { case syncWallpaperSettings, resolution, framesPerSecond, projectPlayback, allowWebHTTPS }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        syncWallpaperSettings = (try? values.decode(Bool.self, forKey: .syncWallpaperSettings)) ?? true
        resolution = (try? values.decode(GWLockScreenExportResolution.self, forKey: .resolution)) ?? .fullHD1080
        framesPerSecond = min(max((try? values.decode(Int.self, forKey: .framesPerSecond)) ?? 30, 0), 240)
        projectPlayback = (try? values.decode(GWLockScreenProjectPlayback.self, forKey: .projectPlayback)) ?? .live
        allowWebHTTPS = (try? values.decode(Bool.self, forKey: .allowWebHTTPS)) ?? false
    }

    static let original = Self(syncWallpaperSettings: false, resolution: .original, framesPerSecond: 0)
}

struct LockScreenExportSpecification: Equatable, Sendable {
    let width: Int
    let height: Int
    /// Keep fractional video rates (for example 24000/1001) until encoding.
    let framesPerSecond: Double

    static func validDimensions(width: Int, height: Int) -> Bool {
        (2...8192).contains(width) && (2...8192).contains(height)
            && width.isMultiple(of: 2) && height.isMultiple(of: 2)
            && width * height <= 16_777_216
    }

    var renderedFramesPerSecond: Int { max(1, Int(framesPerSecond.rounded(.down))) }
    var averageBitRate: Int {
        Self.averageBitRate(width: width, height: height, fps: framesPerSecond)
    }
    static func averageBitRate(width: Int, height: Int, fps: Double) -> Int {
        let scale = Double(width) * Double(height) / (1920 * 1080) * fps / 30
        return Int(min(120_000_000, max(1_000_000, 8_000_000 * scale)))
    }
}

struct LockScreenExportConfiguration: Sendable {
    var settings: GWLockScreenExportSettings = .init()
    /// Actual desktop render size; nil uses the source size (also useful in isolated tests).
    var wallpaperWidth: Int?
    var wallpaperHeight: Int?
    var wallpaperFPS: Double?

    func resolve(source: LockScreenExportSpecification) throws -> LockScreenExportSpecification {
        guard source.width >= 2, source.height >= 2,
              source.width <= 65_536, source.height <= 65_536,
              source.framesPerSecond.isFinite, source.framesPerSecond > 0 else {
            throw LockScreenExportConfigurationFailure(message: "无法确定素材原始分辨率或帧率，已停止锁屏导出。")
        }
        let width = Double(source.width), height = Double(source.height)
        var scale = 1.0
        var fps = source.framesPerSecond
        if settings.syncWallpaperSettings {
            if let wallpaperWidth, let wallpaperHeight, wallpaperWidth > 0, wallpaperHeight > 0 {
                scale = min(scale, Double(wallpaperWidth) / width, Double(wallpaperHeight) / height)
            }
            if let wallpaperFPS, wallpaperFPS.isFinite, wallpaperFPS > 0 { fps = min(fps, wallpaperFPS) }
        } else {
            if let longEdge = settings.resolution.longEdge {
                let shortEdge = Double(longEdge) * 9 / 16
                scale = min(scale, Double(longEdge) / max(width, height), shortEdge / min(width, height))
            }
            if settings.framesPerSecond > 0 { fps = min(fps, Double(settings.framesPerSecond)) }
        }
        // Match the Scene backend's pixel budget and H.264's even dimensions.
        scale = min(scale, 8192 / width, 8192 / height, sqrt(16_777_216 / (width * height)))
        let outputWidth = Int((width * scale).rounded(.down)) / 2 * 2
        let outputHeight = Int((height * scale).rounded(.down)) / 2 * 2
        guard LockScreenExportSpecification.validDimensions(width: outputWidth, height: outputHeight) else {
            throw LockScreenExportConfigurationFailure(message: "素材画面比例无法生成有效的锁屏视频。")
        }
        return .init(width: outputWidth, height: outputHeight, framesPerSecond: min(fps, 240))
    }
}

struct LockScreenExportConfigurationFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
