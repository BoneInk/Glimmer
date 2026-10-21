import Foundation
import Observation

enum ExperimentalLockScreenState: String, Codable, Sendable {
    case idle, preparing, prepared, registered, applied, restored, failed
}

private struct LockScreenPersistentState: Codable {
    let state: ExperimentalLockScreenState
    let asset: ExperimentalLockScreenAsset?
    let warning: String?
}

private struct LockScreenExtensionConfiguration: Encodable {
    let schemaVersion: Int
    let assetID: String
    let videoFileName: String
    let liveDirectoryName: String?
    let gravity = "fill"
    let isMuted = true
    init(assetID: String, videoFileName: String = "", liveDirectoryName: String? = nil) {
        self.assetID = assetID; self.videoFileName = videoFileName
        self.liveDirectoryName = liveDirectoryName; schemaVersion = liveDirectoryName == nil ? 1 : 2
    }
}

@MainActor
@Observable
final class ExperimentalLockScreenCoordinator {
    private(set) var state: ExperimentalLockScreenState = .idle
    private(set) var preparedAsset: ExperimentalLockScreenAsset?
    private(set) var lastError: String?
    private(set) var isBusy = false
    private(set) var preparationDetail: String?
    private var operationDetail: String?
    private let storage: AppStorage
    private let environment: ExperimentalLockScreenEnvironment
    private let preparer = ExperimentalLockScreenAssetPreparer()
    private let exportConfiguration: @MainActor (WallpaperItem) -> LockScreenExportConfiguration
    private let registrar = ExperimentalLockScreenRegistrar()
    private var preparation: Task<ExperimentalLockScreenAsset, Error>?
    private var generation = UUID()

    private var root: URL { storage.root.resolvingSymlinksInPath().appendingPathComponent("ExperimentalLockScreen", isDirectory: true) }
    private var sceneCacheRoot: URL { root.appendingPathComponent("SceneVideoCache", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var snapshotURL: URL { root.appendingPathComponent("previous-settings.json") }
    private var configurationURL: URL { environment.sharedDirectory.appendingPathComponent("config.json") }
    private var pendingSnapshotURL: URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("pending-") && $0.pathExtension == "json" }
            .max { lhs, rhs in
                let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }
    var canRestorePrevious: Bool { pendingSnapshotURL != nil || FileManager.default.fileExists(atPath: snapshotURL.path) }

    var statusText: String {
        if isBusy, let operationDetail { return operationDetail }
        return switch state {
        case .idle: "尚未准备动态锁屏"
        case .preparing: (preparationDetail ?? "正在准备锁屏素材") + "；尚未修改系统设置"
        case .prepared: "锁屏素材已准备；尚未注册扩展或修改系统设置"
        case .registered: "扩展注册命令已完成；尚未确认系统加载"
        case .applied: "配置已提交，尚未验证锁屏可见" + (lastError.map { "。" + $0 } ?? "")
        case .restored: "上一次配置已恢复；尚未确认系统重新加载" + (lastError.map { "。" + $0 } ?? "")
        case .failed: lastError ?? "操作失败；可恢复备份已保留"
        }
    }

    init(storage: AppStorage = AppStorage(), environment: ExperimentalLockScreenEnvironment = .production,
         exportConfiguration: @escaping @MainActor (WallpaperItem) -> LockScreenExportConfiguration = { _ in
             LockScreenExportSourceResolver.desktopConfiguration()
         }) {
        self.storage = storage
        self.environment = environment
        self.exportConfiguration = exportConfiguration
        // Reading status never re-applies wallpaper or registers an extension after launch.
        if let data = try? Data(contentsOf: storage.root.appendingPathComponent("ExperimentalLockScreen/state.json")),
           let saved = try? JSONDecoder().decode(LockScreenPersistentState.self, from: data) {
            state = saved.state == .preparing ? .idle : saved.state
            preparedAsset = saved.asset
            lastError = saved.warning
        }
        if pendingSnapshotURL != nil {
            state = .failed
            lastError = "检测到未完成的锁屏配置事务；可尝试恢复备份，不会自动重应用。"
        }
    }

    static func review(storage: AppStorage) -> ExperimentalLockScreenCoordinator {
        Self(storage: storage, environment: .review(storage: storage))
    }

    func prepare(item: WallpaperItem) async {
        guard !isBusy else { return }
        guard item.isVideoWallpaper || item.isWebWallpaper || item.isSceneWallpaper else {
            lastError = "动态锁屏目前支持视频、Web 动画和 Scene。"
            return
        }
        generation = UUID()
        let ticket = generation
        let previousAsset = preparedAsset
        isBusy = true
        state = .preparing
        preparedAsset = nil
        preparationDetail = "正在检查视频编码与时长"
        lastError = nil
        do {
            try LockScreenOwnedFiles.makePrivateDirectory(root)
            try saveState()
            let assetsRoot = root.appendingPathComponent("Assets", isDirectory: true)
            try LockScreenOwnedFiles.makePrivateDirectory(assetsRoot)
            let preparer = self.preparer, storage = self.storage
            var configuration = exportConfiguration(item)
            // Video desktop playback retains the track's native timing, independently
            // of the global Scene/Web FPS cap. Probe it again in the preparer.
            if item.isVideoWallpaper { configuration.wallpaperFPS = nil }
            let sceneCacheRoot = self.sceneCacheRoot.appendingPathComponent(item.id.uuidString, isDirectory: true)
            let webCacheRoot = root.appendingPathComponent("WebVideoCache", isDirectory: true)
                .appendingPathComponent(item.id.uuidString, isDirectory: true)
            let rendered: LockScreenExportSpecification? = item.isVideoWallpaper ? nil
                : try configuration.resolve(source: LockScreenExportSourceResolver.renderedSource(item: item, configuration: configuration))
            preparationDetail = rendered.map { "正在准备 \($0.width)×\($0.height) · \($0.renderedFramesPerSecond) FPS 锁屏视频" }
                ?? "正在检查视频原始规格"
            let task = Task { [weak self] in
                if !item.isVideoWallpaper, configuration.settings.projectPlayback == .live {
                    guard let rendered else { throw LiveWallpaperFailure(message: "缺少实时锁屏规格。") }
                    self?.receivePreparationDetail("正在准备实时锁屏项目与作者设置", ticket: ticket)
                    return try await LiveWallpaperPreparer.prepare(item: item, storage: storage, root: assetsRoot,
                        specification: rendered, allowHTTPS: configuration.settings.allowWebHTTPS)
                }
                if item.isSceneWallpaper {
                    #if GW_UNIVERSAL_SCENE_BACKEND
                    guard let rendered else { throw LockScreenExportConfigurationFailure(message: "缺少 Scene 导出规格。") }
                    let settings = RenderedLockScreenVideoCache.Settings(signature: "scene-h264-v2",
                        framesPerSecond: rendered.renderedFramesPerSecond, width: rendered.width, height: rendered.height)
                    let cache = RenderedLockScreenVideoCache(root: sceneCacheRoot, settings: settings,
                        materialProvider: {
                            try await SceneWallpaperLockScreenConfiguration.material(item: item, storage: storage)
                        },
                        exportOperation: { payload, directory, progress in
                            let report = try await SceneWallpaperLockScreenExporter(settings: settings)
                                .export(item: item, authorPayload: payload, directory: directory, progress: progress)
                            return report.videoURL
                        })
                    return try await cache.withVideo(progress: { [weak self] detail in
                        await self?.receivePreparationDetail(detail, ticket: ticket)
                    }) { video in
                        let asset = try await preparer.prepare(item: item, sourceURL: video, root: assetsRoot) { [weak self] detail in
                            await self?.receivePreparationDetail(detail, ticket: ticket)
                        }
                        RenderedLockScreenVideoCache.discardOtherEntries(in: sceneCacheRoot, keeping: video)
                        return asset
                    }
                    #else
                    throw ExperimentalLockScreenFailure(message: "当前构建不支持 Scene 锁屏导出。")
                    #endif
                }
                if item.isWebWallpaper {
                    guard let rendered else { throw LockScreenExportConfigurationFailure(message: "缺少网页导出规格。") }
                    let webVideoCache = WebWallpaperLockScreenVideoCache(root: webCacheRoot,
                        settings: .init(framesPerSecond: rendered.renderedFramesPerSecond,
                                        width: rendered.width, height: rendered.height))
                    return try await webVideoCache.withVideo(item: item, storage: storage, progress: { [weak self] detail in
                        await self?.receivePreparationDetail(detail, ticket: ticket)
                    }) { video in
                        let asset = try await preparer.prepare(item: item, sourceURL: video, root: assetsRoot) { [weak self] detail in
                            await self?.receivePreparationDetail(detail, ticket: ticket)
                        }
                        webVideoCache.discardOtherEntries(keeping: video)
                        return asset
                    }
                }
                return try await preparer.prepare(item: item, sourceURL: nil, root: assetsRoot,
                                                  configuration: configuration) { [weak self] detail in
                    await self?.receivePreparationDetail(detail, ticket: ticket)
                }
            }
            preparation = task
            let asset = try await task.value
            guard generation == ticket else { return }
            preparedAsset = asset
            state = .prepared
            try saveState()
            if let previousAsset, previousAsset.itemID == item.id, previousAsset.videoURL != asset.videoURL {
                let oldDirectory = previousAsset.videoURL.deletingLastPathComponent().standardizedFileURL
                if oldDirectory.deletingLastPathComponent() == assetsRoot.standardizedFileURL,
                   oldDirectory.lastPathComponent == previousAsset.id.uuidString,
                   (try? oldDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                    try? FileManager.default.removeItem(at: oldDirectory)
                }
            }
        } catch {
            guard generation == ticket else { return }
            state = .failed
            lastError = error.localizedDescription
            try? saveState()
        }
        guard generation == ticket else { return }
        preparation = nil
        preparationDetail = nil
        isBusy = false
    }

    func cancelPreparation() {
        guard state == .preparing else { return }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        isBusy = false
        state = .idle
        preparationDetail = nil
        lastError = nil
        try? saveState()
    }

    /// Must only be called from an explicit Apply action. Review environments never
    /// call pluginkit or access the actual user's wallpaper store.
    func applyPrepared() async {
        guard !isBusy, let asset = preparedAsset else { return }
        isBusy = true
        operationDetail = "正在准备扩展可读取的私有素材"
        lastError = nil
        var previousConfiguration: Data?
        var submittedConfiguration: Data?
        var configurationWasWritten = false
        var committed = false
        do {
            try LockScreenOwnedFiles.makePrivateDirectory(root)
            try LockScreenOwnedFiles.makePrivateDirectory(environment.sharedDirectory)
            if environment.isReview { try createReviewStoreIfNeeded() }
            // Copy from an owned prepared asset only; never change the original library video.
            let expectedAssetRoot = root.appendingPathComponent("Assets").standardizedFileURL.path + "/"
            guard asset.videoURL.standardizedFileURL.path.hasPrefix(expectedAssetRoot),
                  asset.videoURL.resolvingSymlinksInPath().path == asset.videoURL.standardizedFileURL.path else {
                throw ExperimentalLockScreenFailure(message: "已准备素材路径无效，请重新准备。")
            }
            let configuration: LockScreenExtensionConfiguration
            if asset.liveRecipe != nil {
                let name = try await LiveWallpaperPackaging.shared.stage(asset, directory: environment.sharedDirectory)
                configuration = .init(assetID: asset.id.uuidString, liveDirectoryName: name)
            } else {
                let sharedVideo = try await preparer.stageVideo(asset, directory: environment.sharedDirectory)
                configuration = .init(assetID: asset.id.uuidString, videoFileName: sharedVideo.lastPathComponent)
            }
            let config = try JSONEncoder().encode(configuration)
            previousConfiguration = try? Data(contentsOf: configurationURL)
            submittedConfiguration = config
            // The extension remains harmless until an explicit system desktop/lock-screen provider selection.
            if !environment.isReview {
                guard let url = environment.extensionURL else {
                    throw ExperimentalLockScreenFailure(message: "安装包没有动态锁屏扩展。")
                }
                operationDetail = "正在注册应用内扩展；尚未修改系统壁纸"
                try await registrar.register(extensionURL: url)
            }
            state = .registered
            try saveState()
            try LockScreenOwnedFiles.privateWrite(config, to: configurationURL)
            configurationWasWritten = true
            operationDetail = "正在备份并提交系统桌面／锁屏配置"
            let transaction = LockScreenStoreTransaction(storeDirectory: environment.storeDirectory, snapshotURL: snapshotURL)
            _ = try transaction.apply(configuration: config, previousConfiguration: previousConfiguration,
                                      assetID: asset.id, sharedDirectory: environment.sharedDirectory)
            committed = true
            state = .applied
            // State-file failure must not claim the wallpaper store itself rolled back.
            try? saveState()
            operationDetail = "正在请求系统重新加载；桌面可能短暂闪烁"
            try await reloadAfterCommit()
        } catch {
            if !committed, configurationWasWritten, let submittedConfiguration,
               (try? Data(contentsOf: configurationURL)) == submittedConfiguration {
                if let previousConfiguration {
                    try? LockScreenOwnedFiles.privateWrite(previousConfiguration, to: configurationURL)
                } else { try? FileManager.default.removeItem(at: configurationURL) }
            }
            state = committed ? .applied : .failed
            lastError = committed ? "配置已提交，但系统重新加载未完成：" + error.localizedDescription : error.localizedDescription
            try? saveState()
        }
        isBusy = false
        operationDetail = nil
    }

    func restorePrevious() async {
        guard !isBusy else { return }
        isBusy = true
        operationDetail = "正在检查并恢复之前的配置"
        lastError = nil
        var committed = false
        do {
            let pendingURL = pendingSnapshotURL
            let snapshot = try JSONDecoder().decode(LockScreenStoreSnapshot.self, from: Data(contentsOf: pendingURL ?? snapshotURL))
            let location = try LockScreenSharedConfigurationLocator.locate(
                snapshot: snapshot, preferredDirectory: environment.sharedDirectory,
                legacyDirectory: environment.legacySharedDirectory)
            let currentConfig = location.data
            let restoredConfigurationURL = location.directory.appendingPathComponent("config.json", isDirectory: false)
            let transaction = LockScreenStoreTransaction(storeDirectory: environment.storeDirectory, snapshotURL: snapshotURL)
            try transaction.validateRestoration(snapshot, allowOriginal: pendingURL != nil)
            if let previous = snapshot.previousSharedConfiguration {
                try LockScreenOwnedFiles.privateWrite(previous, to: restoredConfigurationURL)
            } else { try FileManager.default.removeItem(at: restoredConfigurationURL) }
            do {
                try transaction.restore(snapshot, allowOriginal: pendingURL != nil)
            } catch {
                // Configuration is part of the transaction. Roll it back only if no
                // other selection/configuration has replaced the exact previous value.
                let observed = try? Data(contentsOf: restoredConfigurationURL)
                if observed == snapshot.previousSharedConfiguration {
                    try? LockScreenOwnedFiles.privateWrite(currentConfig, to: restoredConfigurationURL)
                }
                throw error
            }
            if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
            committed = true
            state = .restored
            try? saveState()
            operationDetail = "正在请求系统重新加载恢复后的配置；桌面可能短暂闪烁"
            try await reloadAfterCommit()
        } catch {
            state = committed ? .restored : .failed
            lastError = committed ? "原配置已恢复，但系统重新加载未完成：" + error.localizedDescription : error.localizedDescription
            try? saveState()
        }
        isBusy = false
        operationDetail = nil
    }

    private func receivePreparationDetail(_ detail: String, ticket: UUID) {
        guard generation == ticket, state == .preparing else { return }
        preparationDetail = detail
    }

    private func saveState() throws {
        try LockScreenOwnedFiles.privateWrite(JSONEncoder().encode(LockScreenPersistentState(state: state, asset: preparedAsset,
            warning: state == .applied || state == .restored ? lastError : nil)), to: stateURL)
    }

    private func reloadAfterCommit() async throws {
        if environment.isReview {
            if let message = environment.reviewReloadFailureMessage {
                throw ExperimentalLockScreenFailure(message: message)
            }
        } else {
            try await registrar.reloadCurrentUser()
        }
    }

    private func createReviewStoreIfNeeded() throws {
        try LockScreenOwnedFiles.makePrivateDirectory(environment.storeDirectory)
        let url = environment.storeDirectory.appendingPathComponent("Index.plist")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let fixture: [String: Any] = ["SystemDefault": ["Type": "individual",
            "Desktop": ["Content": ["Choices": [["Provider": "review.desktop.unchanged"]]]],
            "Idle": ["Content": ["Choices": [["Provider": "review.idle.original"]]]]],
            "Displays": [String: String](), "Spaces": [String: String]()]
        try LockScreenOwnedFiles.privateWrite(PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0), to: url)
    }
}
