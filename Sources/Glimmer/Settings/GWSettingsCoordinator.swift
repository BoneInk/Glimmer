import AppKit
import Foundation
import Observation

// F17 设置协调器：外观偏好持久化 + 配置导出/导入 + 恢复默认 + 外部行为绑定。
//
// 外部绑定（由主控接线，本模块不依赖素材库/播放/策略的具体实现）：
// - 启动恢复：读取/写入「启动时恢复上次壁纸」的真实行为（例如素材库设置）；
//   偏好文件同时保存用户意图，保证重启与配置迁移一致。未接线时只持久化偏好，
//   界面提示「将在下次启动时生效」。
// - 播放/策略/播放列表：通过闭包生成导出快照与接收导入结果，避免耦合仍在演进的类型。

/// 由主控注入的外部行为绑定（均为可选：未注入的分节不会出现在导出中，也不会影响导入的其他分节）。
@MainActor
struct GWSettingsExternalActions {
    /// 读取真实「启动时恢复壁纸」开关（例如素材库设置）。nil 时使用偏好文件中的值。
    var readStartupRestoration: (() -> Bool)?
    /// 写入真实「启动时恢复壁纸」开关。
    var writeStartupRestoration: ((Bool) -> Void)?
    /// 生成当前播放设置快照（用于导出；返回 nil 表示暂不可用）。
    var makePlaybackExport: (() -> GWPlaybackConfiguration?)?
    /// 应用导入的播放设置。
    var applyPlaybackImport: ((GWPlaybackConfiguration) -> Void)?
    /// 读取当前电源策略设置（用于导出）。
    var readPolicySettings: (() -> GWPolicySettings?)?
    /// 应用导入的电源策略设置。
    var applyPolicySettings: ((GWPolicySettings) -> Void)?
    /// 读取当前播放列表设置（用于导出）。
    var readPlaylistSettings: (() -> GWPlaylistSettings?)?
    /// 应用导入的播放列表设置。
    var applyPlaylistSettings: ((GWPlaylistSettings) -> Void)?
    /// 恢复默认设置时额外重置的运行时设置（播放/策略/播放列表等）。
    var resetAdditionalSettings: (() -> Void)?
    /// 实时应用 Scene/Web 的全局帧率上限。
    var applyWallpaperFPS: ((Int) -> Void)?

    init(
        readStartupRestoration: (() -> Bool)? = nil,
        writeStartupRestoration: ((Bool) -> Void)? = nil,
        makePlaybackExport: (() -> GWPlaybackConfiguration?)? = nil,
        applyPlaybackImport: ((GWPlaybackConfiguration) -> Void)? = nil,
        readPolicySettings: (() -> GWPolicySettings?)? = nil,
        applyPolicySettings: ((GWPolicySettings) -> Void)? = nil,
        readPlaylistSettings: (() -> GWPlaylistSettings?)? = nil,
        applyPlaylistSettings: ((GWPlaylistSettings) -> Void)? = nil,
        resetAdditionalSettings: (() -> Void)? = nil,
        applyWallpaperFPS: ((Int) -> Void)? = nil
    ) {
        self.readStartupRestoration = readStartupRestoration
        self.writeStartupRestoration = writeStartupRestoration
        self.makePlaybackExport = makePlaybackExport
        self.applyPlaybackImport = applyPlaybackImport
        self.readPolicySettings = readPolicySettings
        self.applyPolicySettings = applyPolicySettings
        self.readPlaylistSettings = readPlaylistSettings
        self.applyPlaylistSettings = applyPlaylistSettings
        self.resetAdditionalSettings = resetAdditionalSettings
        self.applyWallpaperFPS = applyWallpaperFPS
    }
}

/// 素材库信息（设置页展示；由主控注入，避免依赖素材库类型）。
struct GWSettingsLibraryInfo: Sendable, Equatable {
    var itemCount: Int
    var favoriteCount: Int
    var missingCount: Int
    /// 素材库记录的文件大小合计（应用的媒体副本，不含原始导入文件）。
    var totalMediaBytes: Int64
    /// library.json 当前大小。
    var libraryFileBytes: Int64
    var assignedDisplayCount: Int
    var lastSavedAt: Date?

    init(
        itemCount: Int = 0,
        favoriteCount: Int = 0,
        missingCount: Int = 0,
        totalMediaBytes: Int64 = 0,
        libraryFileBytes: Int64 = 0,
        assignedDisplayCount: Int = 0,
        lastSavedAt: Date? = nil
    ) {
        self.itemCount = itemCount
        self.favoriteCount = favoriteCount
        self.missingCount = missingCount
        self.totalMediaBytes = totalMediaBytes
        self.libraryFileBytes = libraryFileBytes
        self.assignedDisplayCount = assignedDisplayCount
        self.lastSavedAt = lastSavedAt
    }
}

/// 设置状态（外观/启动偏好 + 配置迁移）。@MainActor，SwiftUI 直接观察。
@MainActor
@Observable
final class GWSettingsCoordinator {
    let paths: GWSettingsPaths

    /// 当前偏好（写入即原子落盘）。
    private(set) var preferences: GWPreferencesSettings
    private(set) var lastSavedAt: Date?
    private(set) var lastError: String?
    private(set) var corruptedBackupPath: String?
    private(set) var lastExportAt: Date?
    private(set) var lastImportAt: Date?

    private let external: GWSettingsExternalActions
    private let persistenceEnabled: Bool

    /// 是否已接入外部启动恢复绑定。
    var hasExternalStartupRestoration: Bool {
        external.readStartupRestoration != nil || external.writeStartupRestoration != nil
    }

    /// 当前可导出的分节名称（用于设置界面展示）。
    var exportSectionNames: [String] {
        var names = ["外观与启动偏好"]
        if external.makePlaybackExport != nil { names.append("播放设置") }
        if external.readPolicySettings != nil { names.append("电源与睡眠策略") }
        if external.readPlaylistSettings != nil { names.append("播放列表轮播") }
        return names
    }

    /// 启动恢复开关的当前有效值（外部行为优先，未接线时使用偏好文件）。
    var startupRestorationEffectiveValue: Bool {
        external.readStartupRestoration?() ?? preferences.restoreWallpapersOnLaunch
    }

    init(
        paths: GWSettingsPaths = GWSettingsPaths(),
        persistenceEnabled: Bool = true,
        external: GWSettingsExternalActions = GWSettingsExternalActions()
    ) {
        self.paths = paths
        self.persistenceEnabled = persistenceEnabled
        self.external = external
        self.preferences = .default
        loadPreferences()
    }

    // MARK: - 偏好读写

    private func loadPreferences() {
        guard persistenceEnabled else { return }
        do {
            if let document = try GWPreferencesPersistence.load(from: paths.preferencesFile) {
                preferences = document.settings
                lastSavedAt = document.updatedAt
            }
        } catch let error as GWStorageError {
            lastError = error.errorDescription
            // 版本过高不隔离：文件可能来自更新版本应用，保留原文件供用户升级后使用。
            if case .corrupted = error,
               let backup = GWPreferencesPersistence.quarantine(paths.preferencesFile) {
                corruptedBackupPath = backup.path
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 修改偏好并原子保存（按需应用到外观）。
    func updatePreferences(_ body: (inout GWPreferencesSettings) -> Void) {
        let previousFPS = preferences.wallpaperFPS
        var copy = preferences
        body(&copy)
        guard copy != preferences else { return }
        preferences = copy
        persistPreferences(reportError: true)
        applyAppearance()
        if copy.wallpaperFPS != previousFPS { external.applyWallpaperFPS?(copy.wallpaperFPS) }
    }

    /// 直接设置启动恢复开关：同步真实行为（已接线时）并保存偏好。
    func setStartupRestoration(_ value: Bool) {
        external.writeStartupRestoration?(value)
        updatePreferences { $0.restoreWallpapersOnLaunch = value }
    }

    /// 把偏好文件中的启动行为同步到外部真实设置（主控可在启动时调用；未接线时无操作）。
    func pushPreferencesToExternal() {
        external.writeStartupRestoration?(preferences.restoreWallpapersOnLaunch)
        external.applyWallpaperFPS?(preferences.wallpaperFPS)
    }

    /// 把外观偏好应用到应用（跟随系统/浅色/深色）。CLI 环境无 NSApp 时安全跳过。
    func applyAppearance() {
        let appearance: NSAppearance?
        switch preferences.appearance {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }
        NSApp?.appearance = appearance
    }

    @discardableResult
    private func persistPreferences(reportError: Bool) -> Bool {
        guard persistenceEnabled else { return true }
        do {
            try GWPreferencesPersistence.save(preferences, to: paths.preferencesFile)
            lastSavedAt = Date()
            lastError = nil
            return true
        } catch {
            if reportError {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    // MARK: - 配置导出

    /// 生成当前导出信封：只包含已接入的分节，绝不包含账号/凭据/素材库内容。
    func makeExportEnvelope() -> GWConfigurationEnvelope {
        GWConfigurationEnvelope(
            preferences: preferences,
            playback: external.makePlaybackExport?(),
            policy: external.readPolicySettings?(),
            playlist: external.readPlaylistSettings?()
        )
    }

    /// 导出到指定文件（原子写入），返回字节数。
    @discardableResult
    func exportConfiguration(to url: URL) throws -> Int {
        let bytes = try GWConfigurationTransfer.writeExport(makeExportEnvelope(), to: url)
        lastExportAt = Date()
        return bytes
    }

    // MARK: - 配置导入

    /// 校验导入数据（零副作用）。只有通过校验的结果才能调用 `commitImport`。
    func validateImport(data: Data) throws -> GWValidatedConfiguration {
        try GWConfigurationTransfer.validateImport(data: data)
    }

    /// 校验磁盘上的配置文件（零副作用）。
    func validateImport(contentsOf url: URL) throws -> GWValidatedConfiguration {
        try GWConfigurationTransfer.validateImport(contentsOf: url)
    }

    /// 提交已完整校验的配置：保存偏好并应用各分节。
    ///
    /// 顺序：先应用外观/启动偏好（含落盘），再依次调用主控注入的分节应用闭包。
    /// 偏好落盘失败时抛错，且不会继续应用其他分节。
    @discardableResult
    func commitImport(_ configuration: GWValidatedConfiguration) throws -> [String] {
        if let importedPreferences = configuration.preferences {
            let previous = preferences
            preferences = importedPreferences
            guard persistPreferences(reportError: false) else {
                let detail = lastError ?? "无法写入偏好文件"
                // 落盘失败：回滚内存状态，保持与磁盘一致，不产生“看似已应用”的假象。
                preferences = previous
                lastError = detail
                throw GWConfigurationError.writeFailed(detail: detail)
            }
            applyAppearance()
            external.writeStartupRestoration?(importedPreferences.restoreWallpapersOnLaunch)
            external.applyWallpaperFPS?(importedPreferences.wallpaperFPS)
        }
        if let playback = configuration.playback {
            external.applyPlaybackImport?(playback)
        }
        if let policy = configuration.policy {
            external.applyPolicySettings?(policy)
        }
        if let playlist = configuration.playlist {
            external.applyPlaylistSettings?(playlist)
        }
        lastImportAt = Date()
        lastError = nil
        return configuration.sectionNames
    }

    // MARK: - 恢复默认

    /// 恢复外观与启动偏好为默认值（不影响素材库与文件）。
    func resetPreferences() {
        preferences = .default
        persistPreferences(reportError: true)
        applyAppearance()
        external.writeStartupRestoration?(GWPreferencesSettings.default.restoreWallpapersOnLaunch)
        external.applyWallpaperFPS?(GWPreferencesSettings.default.wallpaperFPS)
    }

    /// 恢复全部设置：偏好 + 主控注入的运行时设置（播放/策略/播放列表等）。
    /// 不删除任何素材文件，不退出 Steam 登录，不清除下载。
    func resetAllSettings() {
        resetPreferences()
        external.resetAdditionalSettings?()
    }
}
