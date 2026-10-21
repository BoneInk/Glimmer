import Foundation

struct SteamContentProgress: Equatable, Sendable {
    let logicalTotalBytes: UInt64
    let receivedPayloadBytes: UInt64
    let downloadedVerifiedBytes: UInt64
    let reusedVerifiedBytes: UInt64
    let successfulCompressedPayloadBytes: UInt64
    var verifiedBytes: UInt64 { downloadedVerifiedBytes + reusedVerifiedBytes }
    var fraction: Double? { logicalTotalBytes == 0 ? nil : Double(verifiedBytes) / Double(logicalTotalBytes) }
    static let zero = Self(logicalTotalBytes: 0, receivedPayloadBytes: 0, downloadedVerifiedBytes: 0, reusedVerifiedBytes: 0, successfulCompressedPayloadBytes: 0)
}
struct SteamContentChallenge: Equatable, Sendable {
    enum Kind: String, Sendable { case deviceCode = "device_code", emailCode = "email_code", deviceConfirmation = "device_confirmation", qr }
    let sessionID: String
    let challengeID: String
    let kind: Kind
    let previousIncorrect: Bool
    let challengeURL: URL?
}
struct SteamContentDownloadResult: Sendable {
    let contentURL: URL
    let progress: SteamContentProgress
    let planFingerprint: String
    /// Transport completion still requires the native project resolver/importer.
    let validationRequired: Bool
}
struct SteamEngineAssetManifestIdentity: Codable, Equatable, Sendable {
    let sha256: String
    let depotID: UInt32
    let manifestID: UInt64
}
struct SteamEngineAssetFile: Codable, Equatable, Sendable {
    let logicalPath: String
    let relativePath: String
    let sha256: String
    let sizeBytes: UInt64
}
struct SteamEngineAssetBundle: Sendable {
    let cacheRoot: URL
    let manifestIdentity: SteamEngineAssetManifestIdentity
    let files: [SteamEngineAssetFile]
    var logicalFileMappings: [String: URL] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.logicalPath, cacheRoot.appendingPathComponent($0.relativePath)) })
    }
}
struct SteamSceneRuntimeAssetBundle: Sendable {
    let cacheRoot: URL
    let manifestIdentity: SteamEngineAssetManifestIdentity
    let files: [SteamEngineAssetFile]
}
struct SteamEngineAssetInspection: Codable, Equatable, Sendable {
    struct Manifest: Codable, Equatable, Sendable { let depotID: UInt32; let manifestID: UInt64 }
    let manifests: [Manifest]
    let paths: [String]
}
struct SteamEngineAssetInventory: Codable, Equatable, Sendable {
    struct Manifest: Codable, Equatable, Sendable { let depotID: UInt32; let manifestID: UInt64 }
    struct File: Codable, Equatable, Sendable {
        let logicalPath: String; let manifestPath: String; let depotID: UInt32; let manifestID: UInt64
        let sizeBytes: UInt64; let sha1: String; let category: String; let `extension`: String; let archiveCandidate: Bool
    }
    struct Group: Codable, Equatable, Sendable {
        let category: String; let fileCount: Int; let totalBytes: UInt64; let maximumFileBytes: UInt64
    }
    let complete: Bool; let manifests: [Manifest]; let files: [File]; let groups: [Group]; let extensions: [Group]
    let totalFileCount: Int; let totalBytes: UInt64; let maximumFileBytes: UInt64
    let excludedExecutableCount: Int; let excludedExecutableBytes: UInt64; let reportSHA256: String
}
/// Public, bounded aggregate diagnostics. Never carries hosts, URLs or tokens.
struct SteamContentCDNDirectoryDiagnostics: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        let type: String
        let httpsCapability: String
        let rejection: String
        let count: Int
    }
    let total: Int
    let accepted: Int
    let groups: [Group]
}
enum SteamContentBrokerError: Error, LocalizedError, Equatable, Sendable {
    case invalidWorkspace, unavailable, savedSessionUnavailable, savedSessionAccessFailed, savedSessionRevoked, busy, invalidInput, protocolViolation, processExited, timeout, cancelled, helperRejected(String)
    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: return "Steam 内容工作目录必须是应用自有的私有规范目录。"
        case .unavailable: return "Steam 内容组件不可用。"
        case .savedSessionUnavailable: return "没有可恢复的 Steam 登录状态，请连接账号。"
        case .savedSessionAccessFailed: return "无法读取 macOS 钥匙串中的 Steam 登录状态，请重试或手动连接。"
        case .savedSessionRevoked: return "保存的 Steam 登录状态已失效，请重新连接。"
        case .busy: return "Steam 正在处理另一项操作。"
        case .invalidInput: return "Steam 请求参数无效。"
        case .protocolViolation: return "Steam 内容组件返回了无效响应。"
        case .processExited: return "Steam 内容组件已退出。"
        case .timeout: return "Steam 内容组件响应超时。"
        case .cancelled: return "本次 Steam 操作已取消。"
        case .helperRejected(let code):
            switch code {
            case "steam_auth_timeout":
                return "连接 Steam 超时，请重试。"
            case "session_not_authenticated", "steam_disconnected", "stale_session", "auth_adapter_not_authenticated":
                return "Steam 连接已失效，请重新连接后重试。"
            case "no_supported_https_cdn":
                return "当前网络下 Steam 返回的节点不支持 HTTPS。请检查网络或现有代理后重试。"
            case "cdn_auth_denied", "cdn_auth_failed":
                return "下载节点暂时拒绝授权，请稍后重试。"
            case "manifest_access_denied", "depot_key_denied", "app_token_denied":
                return "当前账号暂时无法访问这份工坊内容，请确认拥有 Wallpaper Engine 后重试。"
            case "engine_depot_key_denied":
                return "当前 Steam 账号无法读取 Wallpaper Engine 的内置资源。"
            case "engine_assets_not_found":
                return "Wallpaper Engine 清单中没有找到所需的内置资源。"
            case "engine_asset_cache_limit":
                return "内置资源缓存已满。"
            case "manifest_download_failed", "cdn_directory_denied":
                return "暂时无法从 Steam 下载节点读取内容，请稍后重试。"
            case "cdn_directory_cm_failed", "cdn_directory_public_failed":
                return "暂时无法获取 Steam 下载节点，请检查网络后重试。"
            case "manifest_protocol_failed":
                return "无法读取这份壁纸的文件清单，请稍后重试。"
            case "chunk_protocol_failed", "chunk_download_failed":
                return "壁纸文件传输中断，请重试以继续下载。"
            case "proxy_auth_required":
                return "当前代理要求认证，请在网络工具中完成配置后重试。"
            case "proxy_connect_failed":
                return "无法通过当前代理连接 Steam，请检查代理是否正常运行。"
            case "proxy_connect_boundary":
                return "当前代理配置无法用于安全下载，请检查本机代理设置。"
            default: return "Steam 内容操作未完成（\(code)）。"
            }
        }
    }
}
