import AVFoundation
import Foundation

/// 下载与本地校验相关的错误。
enum WorkshopDownloadError: LocalizedError, Equatable {
    case notSignedIn
    case sessionExpired(hint: String)
    case invalidCredentials(hint: String)
    case guardRequired(hint: String)
    case ownershipMissing
    case itemUnavailable
    case platformUnsupported(detail: String)
    case downloadFailed(detail: String)
    case validationFailed(reason: String)
    case extractionFailed(detail: String)
    case cancelled
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "尚未登录 Steam（下载需要真实的 SteamCMD 账号会话，网页登录无效）。"
        case .sessionExpired(let hint):
            return "Steam 会话已失效" + (hint.isEmpty ? "" : "（\(hint)）") + "。请重新登录后再试。"
        case .invalidCredentials(let hint):
            return "Steam 拒绝登录" + (hint.isEmpty ? "" : "：\(hint)") + "。请根据提示处理后重试。"
        case .guardRequired(let hint):
            return "该账号需要 Steam Guard 验证" + (hint.isEmpty ? "" : "（\(hint)）") + "。请按 Steam 提示完成验证后重新登录。"
        case .ownershipMissing:
            return "该账号没有 Wallpaper Engine（431960），或未拥有该作品：Steam 拒绝下载。请确认已购买并已登录正确账号。"
        case .itemUnavailable:
            return "Steam 报告该作品不存在、已删除或不可下载。请确认链接或稍后重试。"
        case .platformUnsupported(let detail):
            return "平台不受支持：\(detail)"
        case .downloadFailed(let detail):
            return "下载失败：\(detail)"
        case .validationFailed(let reason):
            return "下载内容校验失败：\(reason)"
        case .extractionFailed(let detail):
            return "SteamCMD 安装包展开失败：\(detail)"
        case .cancelled:
            return "下载已取消"
        case .storageUnavailable(let detail):
            return "管理目录不可用：\(detail)"
        }
    }
}
