import AppKit
import Foundation

/// F17/F18/F20 与主程序真实行为的接线（设置导入导出、清理保护集、诊断注入、素材库信息）。
///
/// 该文件只做「现有模块之间的转换与注入」，不重复实现模块内部逻辑。
/// AppDelegate 与自检使用同一套接线，保证自检覆盖的就是真实运行路径。
@MainActor
enum AppSettingsWiring {

    // MARK: - 设置协调器的外部绑定

    static func externalActions(
        store: VideoLibraryStore,
        playback: DesktopPlaybackController,
        policy: GWPolicyController,
        playlist: GWPlaylistRotator,
        onPlaybackSettingsApplied: (() -> Void)? = nil,
        onWallpaperFPSApplied: ((Int) -> Void)? = nil
    ) -> GWSettingsExternalActions {
        GWSettingsExternalActions(
            readStartupRestoration: { store.appSettings.autoApplyOnLaunch },
            writeStartupRestoration: { value in
                store.updateAppSettings { $0.autoApplyOnLaunch = value }
                store.flush()
            },
            makePlaybackExport: { makePlaybackConfiguration(from: store) },
            applyPlaybackImport: { configuration in
                applyPlaybackConfiguration(configuration, to: store, playback: playback)
                // 导入可能整体改变每屏的暂停意图：同步一次聚合策略意图/轮播计时（R14）。
                onPlaybackSettingsApplied?()
            },
            readPolicySettings: { policy.settings },
            applyPolicySettings: { settings in
                policy.updateSettings { current in current = settings }
            },
            readPlaylistSettings: { playlist.settings },
            applyPlaylistSettings: { settings in
                playlist.updateSettings { current in current = settings }
            },
            resetAdditionalSettings: {
                policy.resetSettings()
                playlist.resetSettings()
                onPlaybackSettingsApplied?()
            },
            applyWallpaperFPS: {
                playback.setWallpaperFPS($0)
                onWallpaperFPSApplied?($0)
            }
        )
    }

    // MARK: - 播放设置转换（B01 DisplayPlaybackSettings ↔ F17 GWPlaybackConfiguration）

    static func makePlaybackConfiguration(from store: VideoLibraryStore) -> GWPlaybackConfiguration {
        var displays: [String: GWPlaybackConfiguration.DisplaySettings] = [:]
        for (displayID, settings) in store.displaySettings {
            displays[displayID] = GWPlaybackConfiguration.DisplaySettings(
                isPaused: settings.isPaused,
                isMuted: settings.isMuted,
                volume: settings.volume,
                rate: settings.rate,
                gravity: settings.gravity == .fill ? .fill : .fit
            )
        }
        return GWPlaybackConfiguration(displays: displays)
    }

    static func applyPlaybackConfiguration(
        _ configuration: GWPlaybackConfiguration,
        to store: VideoLibraryStore,
        playback: DesktopPlaybackController?
    ) {
        let normalized = configuration.normalized()
        for (displayID, settings) in normalized.displays {
            store.updateSettings(for: displayID) { current in
                current.isPaused = settings.isPaused
                current.isMuted = settings.isMuted
                current.volume = settings.volume
                current.rate = min(max(settings.rate, 0.25), 4)
                current.gravity = settings.gravity == .fill ? .fill : .fit
            }
        }
        store.flush()
        playback?.applyStoredSettingsToSessions()
    }

    // MARK: - 素材库信息与清理保护集

    static func libraryInfo(store: VideoLibraryStore, playback: DesktopPlaybackController) -> GWSettingsLibraryInfo {
        GWSettingsLibraryInfo(
            itemCount: store.items.count,
            favoriteCount: store.favoriteItems.count,
            missingCount: store.missingItemIDs.count,
            totalMediaBytes: store.totalSizeBytes,
            libraryFileBytes: store.libraryFileSizeBytes,
            assignedDisplayCount: store.assignments.count,
            lastSavedAt: store.lastSavedAt
        )
    }

    /// F18 清理的实时保护集：素材库全部引用 + 正在播放的会话素材（含显示器断开恢复期间的挂起会话）
    /// + 原始导入文件的来源路径。清理实现每次删除前都会重新调用本闭包。
    static func protectedURLs(store: VideoLibraryStore, playback: DesktopPlaybackController) -> Set<URL> {
        var urls = Set<URL>()
        for item in store.items {
            urls.formUnion(GWStorageProtection.urls(for: item, storageRoot: store.storage.root))
        }
        for session in playback.sessions.values {
            urls.formUnion(GWStorageProtection.urls(for: session.item, storageRoot: store.storage.root))
        }
        for itemID in playback.suspendedAssignments.values {
            if let item = store.item(withID: itemID) {
                urls.formUnion(GWStorageProtection.urls(for: item, storageRoot: store.storage.root))
            }
        }
        return urls
    }

    // MARK: - 诊断注入（F20）

    /// 主控注入的环境检查项：Steam 工具依赖、登录状态、播放与素材库现状。
    /// 文案本身不含账号/凭据；诊断模块还会再脱敏一次。
    static func diagnosticsExtras(
        workshop: WorkshopCoordinator?,
        policy: GWPolicyController,
        playback: DesktopPlaybackController,
        store: VideoLibraryStore
    ) -> [GWDiagnosticItem] {
        var items: [GWDiagnosticItem] = []

        if let account = workshop?.account {
            let report = account.report
            let statusText = report?.status.displayText ?? "尚未检测"
            let severity: GWDiagnosticSeverity
            var suggestion: String?
            switch report?.status {
            case .ready:
                severity = .ok
            case .notInstalled:
                severity = .info
                suggestion = "可在「下载与账号」中把官方 SteamCMD 下载到应用管理目录；不会安装系统组件，也不会改动全局 Steam。"
            case .rosettaRequired:
                severity = .warning
                suggestion = "官方 SteamCMD 为 x86_64，需要 Rosetta；请在「下载与账号」查看指引后自行决定是否安装系统组件（应用不会自动安装）。"
            case .unusable:
                severity = .error
                suggestion = "在「下载与账号」中可以查看探测详情并重新安装应用内的 SteamCMD。"
            case .none:
                severity = .info
                suggestion = "打开「下载与账号」后会进行真实依赖检测。"
            }
            items.append(GWDiagnosticItem(
                id: "steamcmd.capability",
                category: .steamHelper,
                severity: severity,
                title: "SteamCMD：\(statusText)",
                detail: report?.architecture.map { "二进制架构：\($0.displayName)，Rosetta：\($0 == .x86_64 || $0 == .universal ? report?.rosetta.displayText ?? "未知" : "无需")" },
                suggestion: suggestion
            ))
            items.append(GWDiagnosticItem(
                id: "steam.account",
                category: .steamHelper,
                severity: .info,
                title: account.isSignedIn ? "Steam 登录：已登录（会话保存在应用管理目录）" : "Steam 登录：未登录",
                detail: account.hasCachedSession
                    ? "存在此前保存的登录会话，密码与验证码从不落盘。"
                    : "公开搜索不受影响；下载需要你本人登录。",
                suggestion: account.isSignedIn ? nil : "在「下载与账号」中由你本人完成登录与 Steam Guard 验证。"
            ))
            if let searchError = workshop?.searchError, !searchError.isEmpty {
                items.append(GWDiagnosticItem(
                    id: "workshop.searchError",
                    category: .network,
                    severity: .warning,
                    title: "最近一次创意工坊搜索未成功",
                    detail: searchError,
                    suggestion: "检查网络或代理设置后重试；应用会如实显示失败原因。"
                ))
            }
        }

        if policy.isPolicyBlockingPlayback {
            items.append(GWDiagnosticItem(
                id: "policy.blocking",
                category: .playback,
                severity: .info,
                title: "电源策略正在暂停播放",
                detail: policy.status.reasonListText,
                suggestion: "这是按你的策略设置自动暂停；解除条件满足后会按每屏的播放意图恢复。"
            ))
        } else {
            items.append(GWDiagnosticItem(
                id: "policy.state",
                category: .playback,
                severity: .ok,
                title: "电源策略：未处于暂停状态",
                detail: "用户意图：\(policy.userIntent.displayName)，监控：\(policy.isMonitoring ? "运行中" : "已停止")"
            ))
        }

        items.append(GWDiagnosticItem(
            id: "playback.sessions",
            category: .playback,
            severity: playback.lastError == nil ? .ok : .warning,
            title: "桌面播放会话：\(playback.sessions.count) 个" + (playback.isPolicySuspended ? "（策略挂起中）" : ""),
            detail: playback.lastError ?? playback.lastMessage,
            suggestion: playback.lastError == nil ? nil : "在素材库中查看对应素材的文件状态，或重新应用。"
        ))

        if store.missingItemIDs.isEmpty {
            items.append(GWDiagnosticItem(
                id: "library.state",
                category: .storage,
                severity: .ok,
                title: "素材库：\(store.items.count) 个素材，无丢失文件"
            ))
        } else {
            items.append(GWDiagnosticItem(
                id: "library.state",
                category: .storage,
                severity: .warning,
                title: "素材库中有 \(store.missingItemIDs.count) 个素材文件不可访问",
                suggestion: "在素材库的「需要处理」中重新定位或移除记录（原始文件不会被删除）。"
            ))
        }

        return items
    }

    /// 最近问题列表（进入诊断报告前会再次脱敏）。
    static func recentIssues(
        store: VideoLibraryStore,
        playback: DesktopPlaybackController,
        policy: GWPolicyController,
        playlist: GWPlaylistRotator,
        workshop: WorkshopCoordinator?
    ) -> [String] {
        var issues: [String] = []
        if let error = store.lastError { issues.append("素材库：\(error)") }
        if let error = playback.lastError { issues.append("桌面播放:\(error)") }
        if let error = policy.lastErrorMessage { issues.append("电源策略：\(error)") }
        if let error = playlist.lastErrorMessage { issues.append("播放列表：\(error)") }
        if let workshop {
            if let error = workshop.searchError { issues.append("工坊搜索：\(error)") }
            if let error = workshop.resolveError { issues.append("工坊链接解析：\(error)") }
            if let banner = workshop.downloadBanner, !banner.isEmpty { issues.append("工坊下载：\(banner)") }
        }
        return issues
    }
}
