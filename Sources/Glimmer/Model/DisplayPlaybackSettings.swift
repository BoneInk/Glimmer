import Foundation

/// 每台显示器的播放设置。以显示器 UUID 为键持久化，因此拔掉外接屏后重插仍能恢复。
struct DisplayPlaybackSettings: Codable, Hashable, Sendable {
    var isPaused: Bool
    var isMuted: Bool
    var volume: Double
    var rate: Double
    var gravity: VideoGravityMode

    static let `default` = DisplayPlaybackSettings(
        isPaused: false,
        isMuted: true, // 需求：默认静音
        volume: 1.0,
        rate: 1.0,
        gravity: .fill
    )

    var clampedVolume: Float { Float(min(max(volume, 0), 1)) }
    var clampedRate: Float { Float(min(max(rate, 0.25), 4.0)) }
}

/// 全局设置（与显示器无关的部分）。v1 只包含生命周期与预览相关的最小集合。
struct AppSettings: Codable, Hashable, Sendable {
    /// 应用启动时自动恢复上次的桌面视频。
    var autoApplyOnLaunch: Bool
    /// 壁纸窗口层级：`desktop`（桌面平面，位于图标之下）或 `desktopIcon`。
    var desktopLayer: DesktopLayer

    enum DesktopLayer: String, Codable, Sendable, CaseIterable, Identifiable {
        case desktop
        case desktopIcon

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .desktop: return "桌面平面（图标之下，推荐）"
            case .desktopIcon: return "桌面图标平面（兼容模式）"
            }
        }
    }

    static let `default` = AppSettings(
        autoApplyOnLaunch: false,
        desktopLayer: .desktop
    )
}
