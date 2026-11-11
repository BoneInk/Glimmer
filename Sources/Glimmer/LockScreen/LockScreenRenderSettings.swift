import Foundation

enum GWLockScreenRenderResolution: String, Codable, CaseIterable, Identifiable, Sendable {
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
struct GWLockScreenRenderSettings: Codable, Equatable, Sendable {
    var syncWallpaperSettings = true
    var resolution: GWLockScreenRenderResolution = .fullHD1080
    var framesPerSecond: Int = 30 {
        didSet { framesPerSecond = min(max(framesPerSecond, 0), 240) }
    }

    init(syncWallpaperSettings: Bool = true,
         resolution: GWLockScreenRenderResolution = .fullHD1080, framesPerSecond: Int = 30) {
        self.syncWallpaperSettings = syncWallpaperSettings
        self.resolution = resolution
        self.framesPerSecond = min(max(framesPerSecond, 0), 240)
    }

    private enum CodingKeys: CodingKey { case syncWallpaperSettings, resolution, framesPerSecond }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        syncWallpaperSettings = (try? values.decode(Bool.self, forKey: .syncWallpaperSettings)) ?? true
        resolution = (try? values.decode(GWLockScreenRenderResolution.self, forKey: .resolution)) ?? .fullHD1080
        framesPerSecond = min(max((try? values.decode(Int.self, forKey: .framesPerSecond)) ?? 30, 0), 240)
    }

    static let original = Self(syncWallpaperSettings: false, resolution: .original, framesPerSecond: 0)
}

struct LockScreenRenderSpecification: Equatable, Sendable {
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

}

struct LockScreenRenderConfiguration: Sendable {
    var settings: GWLockScreenRenderSettings = .init()
    /// Actual desktop render size; nil uses the source size (also useful in isolated tests).
    var wallpaperWidth: Int?
    var wallpaperHeight: Int?
    var wallpaperFPS: Double?

    func resolve(source: LockScreenRenderSpecification) throws -> LockScreenRenderSpecification {
        guard source.width >= 2, source.height >= 2,
              source.width <= 65_536, source.height <= 65_536,
              source.framesPerSecond.isFinite, source.framesPerSecond > 0 else {
            throw LockScreenRenderConfigurationFailure(message: "无法确定素材原始分辨率或帧率，已停止准备锁屏。")
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
        guard LockScreenRenderSpecification.validDimensions(width: outputWidth, height: outputHeight) else {
            throw LockScreenRenderConfigurationFailure(message: "素材画面比例无法生成有效的锁屏画面。")
        }
        return .init(width: outputWidth, height: outputHeight, framesPerSecond: min(fps, 240))
    }
}

struct LockScreenRenderConfigurationFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
