import Foundation

/// Current public and on-disk identities. Legacy values live here as well, but
/// are read-only inputs for the one-way migration/compatibility paths.
enum GlimmerIdentity {
    static let displayName = "Glimmer"
    static let bundleIdentifier = "com.boneinkzhong.glimmer"
    static let applicationSupportFolderName = "Glimmer"
    static let defaultsSuite = "com.boneinkzhong.glimmer"
    static let keychainService = "com.boneinkzhong.glimmer.steam-content"
    static let lockScreenProvider = "com.boneinkzhong.glimmer.wallpaper-extension"
    static let lockScreenChoice = "glimmer.native-video"
    static let lockScreenSharedFolderName = "GlimmerNativeLockScreen"
    static let downloadManifestName = "glimmer-download.json"
    static let configurationFormat = "glimmer.configuration"
    static let libraryWindowAutosaveName = "GlimmerLibraryWindow"
    static let sceneBackendServicePrefix = "com.boneink.Glimmer.SceneBackend"
    static let sceneScriptWorkerName = "GlimmerSceneScriptWorker"
    static let steamContentHelperName = "GlimmerSteamContent"
    static let steamContentNativeLibraryName = "libGlimmerSteamContentNative.dylib"
    static let defaultsMigrationMarker = "glimmer.legacyDefaultsMigration.v1"

    // Migration/compatibility inputs. These are never selected for new writes.
    static let legacyBundleIdentifier = "com.boneinkzhong.glasswallpaper"
    static let legacyApplicationSupportFolderName = "GlassWallpaper"
    static let legacyKeychainService = "com.boneinkzhong.glasswallpaper.steam-content"
    static let legacyLockScreenSharedFolderName = "GlassWallpaperNativeLockScreen"
    static let legacyDownloadManifestName = "glasswallpaper-download.json"
    static let legacyConfigurationFormat = "glasswallpaper.configuration"
    static let legacyLibraryWindowAutosaveName = "GlassWallpaperLibraryWindow"

    static var downloadManifestNames: [String] {
        [downloadManifestName, legacyDownloadManifestName]
    }

    static var acceptedConfigurationFormats: Set<String> {
        [configurationFormat, legacyConfigurationFormat]
    }
}

/// 应用级常量。集中管理标识符与目录名，避免散落的字符串字面量。
enum AppConstants {
    static let displayName = GlimmerIdentity.displayName
    static let bundleIdentifier = GlimmerIdentity.bundleIdentifier
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.14.0"
    static let applicationSupportFolderName = GlimmerIdentity.applicationSupportFolderName
    static let libraryFileName = "library.json"
    static let librarySchemaVersion = 1
    static let defaultsSuitePrefix = GlimmerIdentity.defaultsSuite

    /// Steam 创意工坊 Wallpaper Engine 的 AppID（B02 批次的搜索/下载使用）。
    static let wallpaperEngineAppID = 431_960
}

enum AppFileError: LocalizedError {
    case unsupportedType(String)
    case notReadable(String)
    case unplayable(String, reason: String?)
    case duplicate(existingTitle: String)
    case cancelled
    case copyFailed(String, underlying: String)
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "不支持的文件类型：\(name)"
        case .notReadable(let name):
            return "无法读取文件：\(name)"
        case .unplayable(let name, let reason):
            if let reason, !reason.isEmpty {
                return "无法播放该视频：\(name)（\(reason)）"
            }
            return "无法播放该视频：\(name)"
        case .duplicate(let title):
            return "素材库中已存在相同文件：\(title)"
        case .cancelled:
            return "操作已取消"
        case .copyFailed(let name, let underlying):
            return "复制到素材库失败：\(name)（\(underlying)）"
        case .storageUnavailable(let detail):
            return "素材库目录不可用：\(detail)"
        }
    }
}

/// 便于在日志/诊断中安全展示路径：只显示文件名，避免记录完整用户路径。
enum PathRedaction {
    static func short(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? "(空路径)" : url.lastPathComponent
    }

    static func short(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
