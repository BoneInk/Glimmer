import AppKit
import SwiftUI

/// 应用委托：管理窗口、状态栏与退出生命周期，并持有全部子系统。
///
/// 设计要点：
/// - 标准应用窗口支持 Dock/Command-Tab，菜单栏保留快捷控制。
/// - 关闭管理窗口不会停止桌面播放；预览播放器随窗口关闭而释放。
/// - 退出时停止所有会话、计时器与助手进程并落盘；不会修改系统桌面图片。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var libraryWindow: NSWindow?
    private let workspaceNavigation = AppWorkspaceNavigation()
    private var previewWindow: NSWindow?
    private let wallpaperDetails = WorkspaceWallpaperDetails()
    private(set) var lockScreenActions: LockScreenActionController!
    /// 桌面预览专用播放器：真实 AVPlayerLayer，但不写入素材库（R15 严格隔离）。
    private var previewPlayback: DesktopPlaybackController?

    private(set) var store: VideoLibraryStore!
    private(set) var displayRegistry: DisplayRegistry!
    private(set) var playback: DesktopPlaybackController!
    private(set) var importService: ImportService!
    private(set) var policy: GWPolicyController!
    private(set) var playlist: GWPlaylistRotator!
    private(set) var workshop: WorkshopCoordinator!
    private(set) var settings: GWSettingsCoordinator!
    private(set) var cleanup: GWStorageCleanupController!
    private(set) var loginItem: GWLoginItemService!
    private var integration: AppPlaybackIntegration!
    private var menuBar: MenuBarController!
    private var wallpaperDeletionAction: WallpaperDeletionAction!
    private var isTerminating = false
    private var lockScreenTerminationWait: Task<Void,Never>?
    private var startupMigrationTask: Task<Void, Never>?
    private var startupProgressWindow: NSWindow?
    private var startupProgressIndicator: NSProgressIndicator?
    private var startupStatusLabel: NSTextField?

    var isReady: Bool { store != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Standard application windows remain discoverable through Dock/Cmd-Tab;
        // closing them still leaves desktop playback and the menu bar running.
        NSApp.setActivationPolicy(.regular)
        beginStorageMigration()
    }

    /// The composition root is deliberately gated on a completed storage
    /// migration. No store, controller, integration, menu-bar item, or window is
    /// constructed until the legacy tree has either been published atomically or
    /// proven to be an already-initialized profile.
    private func beginStorageMigration() {
        let locations = GlimmerStorageMigration.defaultLocations()
        // This check is read-only and only runs when a real migration is pending.
        // An initialized Glimmer profile is accepted even after the old root has
        // been retained as a backup, so it never blocks future launches.
        if GlimmerStorageMigration.requiresMigration(source: locations.source, target: locations.target),
           legacyApplicationIsRunning() {
            showLegacyApplicationRunningAlert()
            return
        }
        showStartupProgress()
        startupMigrationTask = Task { [weak self] in
            guard let self else { return }
            let failure: String? = await Task.detached(priority: .utility) { [self] in
                do {
                    _ = try GlimmerStorageMigration.migrateIfNeeded(
                        source: locations.source,
                        target: locations.target
                    ) { progress in
                        Task { @MainActor [weak self] in
                            self?.updateStartupProgress(progress)
                        }
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            self.startupMigrationTask = nil
            if let failure {
                self.failStartup(failure)
            } else {
                self.updateStartupProgress(GlimmerStorageMigration.Progress(
                    completedFiles: 0, totalFiles: 0, fraction: nil,
                    message: "正在载入素材库…"))
                self.finishStartup(at: locations.target)
            }
        }
    }

    /// Read-only process discovery. Glimmer never asks another application to
    /// terminate or accesses its Keychain.
    private func legacyApplicationIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: GlimmerIdentity.legacyBundleIdentifier
        ).isEmpty
    }

    private func showLegacyApplicationRunningAlert() {
        guard !isTerminating else { return }
        isTerminating = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "请先退出旧版应用"
        alert.informativeText = "检测到旧版 GlassWallpaper 仍在运行。为保证数据迁移安全，请退出旧版后重新打开 Glimmer。Glimmer 不会自动退出旧版，也不会在迁移前读取旧版钥匙串。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func finishStartup(at root: URL) {
        let storage = AppStorage(root: root)
        do {
            try storage.prepareDirectories()
        } catch {
            failStartup(error.localizedDescription)
            return
        }

        // Import missing preferences only after the storage gate succeeded and
        // before any controller or window reads them. Login items are
        // intentionally not transferred: macOS associates them with the new
        // bundle identity, so the user must enable the new app once.
        let defaultsMigration = GlimmerUserDefaultsMigration.migrateIfNeeded()
        if defaultsMigration.markerAlreadyPresent == false {
            if defaultsMigration.committed {
                NSLog("[Glimmer] 已导入旧偏好 %d 项，窗口位置=%d",
                      defaultsMigration.importedKeys, defaultsMigration.importedWindowFrame ? 1 : 0)
            } else {
                NSLog("[Glimmer] 旧偏好尚未提交：%@",
                      defaultsMigration.failureReason ?? "未知原因")
            }
        }

        store = VideoLibraryStore(storage: storage)
        displayRegistry = DisplayRegistry()
        playback = DesktopPlaybackController(store: store, displayRegistry: displayRegistry)
        importService = ImportService(store: store)

        let persistencePaths = GWPersistencePaths(root: storage.root)
        policy = GWPolicyController(paths: persistencePaths, autoStartMonitoring: true)
        playlist = GWPlaylistRotator(paths: persistencePaths)
        // Only the real app composition root opts into the user's local Keychain.
        // Review bundles, temporary profiles and self-tests keep the default nil store.
        let steamSessionStore: (any SteamContentSessionStoring)? = Bundle.main.bundleIdentifier == AppConstants.bundleIdentifier
            ? SteamContentKeychainSessionStore() : nil
        workshop = WorkshopCoordinator(account: SteamAccountManager(sessionStore: steamSessionStore))
        lockScreenActions = LockScreenActionController(coordinator: ExperimentalLockScreenCoordinator(storage: storage,
            exportConfiguration: { [weak self] item in
                let preferences = self?.settings?.preferences ?? .default
                let displayID = self?.playback?.sessions.values.first(where: { $0.item.id == item.id })?.display.displayID
                    ?? CGMainDisplayID()
                return LockScreenExportSourceResolver.desktopConfiguration(settings: preferences.lockScreenExport,
                    wallpaperFPS: preferences.wallpaperFPS, displayID: displayID)
            }))
        workshop.isDynamicLockScreenBusy = { [weak self] in self?.lockScreenActions?.isBusy == true }
        integration = AppPlaybackIntegration(
            store: store,
            playback: playback,
            policy: policy,
            playlist: playlist
        )
        settings = GWSettingsCoordinator(
            paths: GWSettingsPaths(root: storage.root),
            external: AppSettingsWiring.externalActions(
                store: store,
                playback: playback,
                policy: policy,
                playlist: playlist,
                onPlaybackSettingsApplied: { [weak self] in
                    // 配置导入/重置改变了每屏暂停意图后，聚合策略意图与轮播计时同步（R14）。
                    self?.integration?.syncPolicyIntentFromSavedSettings()
                },
                onWallpaperFPSApplied: { [weak self] in self?.previewPlayback?.setWallpaperFPS($0) }
            )
        )
        // 启动一致性（R15 复核）：以素材库中真实生效的启动恢复值为准迁移偏好文件。
        // 显式切换会同时更新两处；这里只对齐文件，绝不用偏好默认值反向覆盖真实设置。
        settings.updatePreferences { $0.restoreWallpapersOnLaunch = store.appSettings.autoApplyOnLaunch }
        playback.setWallpaperFPS(settings.preferences.wallpaperFPS)
        cleanup = GWStorageCleanupController(
            paths: GWManagedStoragePaths(root: storage.root),
            protectedURLsProvider: { [store, playback] in
                AppSettingsWiring.protectedURLs(store: store, playback: playback)
            }
        )
        loginItem = GWLoginItemService()
        integration.activate()

        // 工坊下载并校验完成 → 真实导入素材库。
        // 只有导入/重复成功后才写入工坊来源与作品 ID；失败原因原样回报到下载队列界面。
        workshop.onImportProject = { [weak self] project, metadata in
            guard let self else { return "应用正在退出，未执行导入" }
            let source = project.videoProject?.videoURL ?? project.projectJSONURL
            return await self.importWorkshopWallpaper(source, metadata: metadata)
        }

        workshop.onApplyWallpaper = { [weak self] url, metadata, target in
            guard let self else { return .failed("应用正在退出，未设置壁纸") }
            let screenID = (self.libraryWindow?.screen ?? NSScreen.main).flatMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }.flatMap(DisplayRegistry.uuidString(for:))
            return await WorkshopWallpaperApplication.apply(
                url: url, metadata: metadata, target: target,
                currentDisplayID: screenID ?? self.displayRegistry.primary?.id,
                store: self.store, importer: self.importService,
                displays: self.displayRegistry, playback: self.playback)
        }

        workshop.onOpenWallpaperDetails = { [weak self] url, metadata in
            guard let self else { return "应用正在退出" }
            switch await WorkshopWallpaperApplication.importItem(
                url: url, metadata: metadata, store: self.store, importer: self.importService) {
            case .success(let item):
                guard !Task.isCancelled else { return "已取消打开详情" }
                self.showWallpaperDetails(item: item, cancelPendingRequest: false)
                return nil
            case .failure(let error): return error.message
            }
        }

        workshop.onRequestDynamicLockScreen = { [weak self] url, metadata in
            guard let self else { return "应用正在退出" }
            guard !self.lockScreenActions.isBusy else { return "锁屏正在处理，请等待完成或取消准备。" }
            switch await WorkshopWallpaperApplication.importItem(
                url: url, metadata: metadata, store: self.store, importer: self.importService) {
            case .success(let item):
                guard !Task.isCancelled else { return "已取消锁屏请求" }
                return self.lockScreenActions.startApply(item: item)
            case .failure(let error): return error.message
            }
        }

        let deletionService = ManagedWallpaperDeletionService(
            store: store, playback: playback, storage: storage, workshopLayout: workshop.account.layout)
        workshop.onDeleteWallpaper = { [weak self] itemID in
            guard let self else { return "应用正在退出" }
            guard !self.lockScreenActions.isBusy else { return "请先完成或取消锁屏准备，再删除视频。" }
            let priorIDs = Set(self.store.items.map(\.id))
            let error = await deletionService.delete(workshopID: itemID, itemID: nil)
            if error == nil {
                let remainingIDs = Set(self.store.items.map(\.id))
                for removedID in priorIDs.subtracting(remainingIDs) {
                    self.playlist.removeItem(removedID)
                    await ThumbnailCache.shared.invalidate(id: removedID)
                }
            }
            return error
        }
        wallpaperDeletionAction = WallpaperDeletionAction { [weak self] item in
            guard let self else { return "应用正在退出" }
            guard !self.lockScreenActions.isBusy else { return "请先完成或取消锁屏准备，再删除壁纸。" }
            let error: String?
            if item.source == .steamWorkshop, let workshopID = item.workshopID {
                error = await self.workshop.deleteLibraryWallpaper(itemID: workshopID, title: item.displayTitle)
            } else {
                error = await deletionService.deleteLocal(itemID: item.id)
                if error == nil {
                    self.playlist.removeItem(item.id)
                    await ThumbnailCache.shared.invalidate(id: item.id)
                }
            }
            return error
        }

        settings.applyAppearance()

        menuBar = MenuBarController(
            store: store,
            playback: playback,
            importService: importService,
            displayRegistry: displayRegistry
        )
        menuBar.openLibraryHandler = { [weak self] in self?.showLibraryWindow() }
        menuBar.quitHandler = { [weak self] in self?.requestQuit() }
        menuBar.previewHandler = { [weak self] in self?.showPreviewWindow() }
        menuBar.policyStatusProvider = { [weak self] in
            guard let self, self.policy.isPolicyBlockingPlayback else { return nil }
            return self.policy.status.reasonListText
        }
        menuBar.install()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if let error = store.lastError {
            NSLog("[Glimmer] 素材库载入警告: %@", error)
        }
        if let error = policy.lastErrorMessage {
            NSLog("[Glimmer] 电源策略载入警告: %@", error)
        }

        playback.restoreAssignmentsIfNeeded()
        // 启动恢复后同步聚合意图：全部手动暂停时不保持「播放中」意图，轮播计时保持停止（R14）。
        integration.syncPolicyIntentFromSavedSettings()
        integration.applyCurrentPolicyState()
        if playlist.settings.isEnabled, !playlist.isRotating {
            playlist.startRotation()
        }
        closeStartupProgress()
        showLibraryWindow()
        workshop.prepareIfNeeded()
    }

    private func showStartupProgress() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Glimmer"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()

        let label = NSTextField(labelWithString: "正在检查旧数据…")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)

        let content = NSView()
        content.addSubview(label)
        content.addSubview(indicator)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            indicator.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16)
        ])
        window.contentView = content
        startupProgressWindow = window
        startupProgressIndicator = indicator
        startupStatusLabel = label
        window.makeKeyAndOrderFront(nil)
    }

    private func updateStartupProgress(_ progress: GlimmerStorageMigration.Progress) {
        guard startupProgressWindow != nil else { return }
        startupStatusLabel?.stringValue = progress.message
        guard let indicator = startupProgressIndicator else { return }
        if let fraction = progress.fraction {
            if indicator.isIndeterminate {
                indicator.stopAnimation(nil)
                indicator.isIndeterminate = false
            }
            indicator.doubleValue = fraction
        } else if !indicator.isIndeterminate {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
    }

    private func closeStartupProgress() {
        startupProgressIndicator?.stopAnimation(nil)
        startupProgressWindow?.orderOut(nil)
        startupProgressWindow?.contentView = nil
        startupProgressWindow = nil
        startupProgressIndicator = nil
        startupStatusLabel = nil
    }

    private func failStartup(_ detail: String) {
        guard !isTerminating else { return }
        isTerminating = true
        closeStartupProgress()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Glimmer 无法安全完成数据迁移"
        alert.informativeText = detail + "\n\n旧数据与新数据目录均已保留。请检查 Application Support 中的目录后重新启动。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 再次打开已运行的 app（Finder 双击 / open 命令）时，重新显示管理窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isReady else { return true }
        showLibraryWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        isTerminating = true

        // 1) 停止真实播放、计时器与助手进程（无孤儿会话）。
        // 注意：不在退出时把偏好文件反向写入素材库（R15 复核：避免用默认值覆盖真实设置）。
        playback?.tearDownAll()
        playlist?.shutdown()
        policy?.shutdown()
        workshop?.cancelActiveDownload()
        workshop?.cancelOpeningWallpaperDetails()
        lockScreenActions?.cancelPreparation()
        if let account = workshop?.account, account.loginState != .idle, !account.loginState.isTerminal {
            account.cancelSignIn()
        }

        // 2) 落盘并移除菜单栏图标。
        store?.flush()
        menuBar?.remove()
    }

    @objc private func screenParametersChanged() {
        guard isReady else { return }
        displayRegistry.refresh()
        playback.handleScreenChange()
    }

    // MARK: - 工坊导入

    private func importWorkshopWallpaper(_ url: URL, metadata: WorkshopMetadata) async -> String? {
        switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importService) {
        case .success: return nil
        case .failure(let error): return error.message
        }
    }

    // MARK: - 窗口

    func showLibraryWindow() {
        guard isReady else { return }
        if libraryWindow == nil {
            libraryWindow = makeLibraryWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    func showPlaylistWindow() {
        workspaceNavigation.request(.playlist)
        showLibraryWindow()
    }

    private func makeLibraryWindow() -> NSWindow {
        let root = AppWorkspaceView(
            store: store,
            importService: importService,
            playback: playback,
            displays: displayRegistry,
            workshop: workshop,
            policy: policy,
            playlist: playlist,
            settings: settings,
            cleanup: cleanup,
            loginItem: loginItem,
            onOpenPreview: { [weak self] in self?.showPreviewWindow() },
            onOpenDynamicLockScreen: { [weak self] item in _ = self?.lockScreenActions.startApply(item: item) },
            onOpenWallpaperDetails: { [weak self] item in self?.showWallpaperDetails(item: item) },
            navigation: workspaceNavigation,
            wallpaperDetails: wallpaperDetails
        )
        .environment(\.lockScreenActions, lockScreenActions)
        .environment(\.wallpaperDeletionAction, wallpaperDeletionAction)
        let window = WindowGlassBackdrop.makeWindow(rootView: root, hidesPageTitle: true)
        window.title = "Glimmer"
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName(GlimmerIdentity.libraryWindowAutosaveName)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func showWallpaperDetails(item: WallpaperItem, cancelPendingRequest: Bool = true) {
        guard isReady else { return }
        if cancelPendingRequest { workshop.cancelOpeningWallpaperDetails() }
        wallpaperDetails.open(item)
        showLibraryWindow()
    }

    func showPreviewWindow() {
        guard isReady else { return }
        if previewWindow == nil {
            if previewPlayback == nil {
                previewPlayback = DesktopPlaybackController(
                    store: store,
                    displayRegistry: displayRegistry,
                    storage: store.storage,
                    previewOnly: true,
                    // 严格隔离：预览绝不写入素材库的分配/设置/最近播放（R15）。
                    writesToLibrary: false
                )
                previewPlayback?.setWallpaperFPS(settings.preferences.wallpaperFPS)
            }
            let controller = NSHostingController(
                rootView: DesktopPreviewView(
                    store: store,
                    displayRegistry: displayRegistry,
                    controller: previewPlayback!
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "桌面预览"
            window.setContentSize(NSSize(width: 760, height: 560))
            window.styleMask.insert([.titled, .closable, .resizable])
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            previewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        previewWindow?.makeKeyAndOrderFront(nil)
    }

    func requestQuit() {
        isTerminating = false
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isReady else { return .terminateNow }
        let actions: LockScreenActionController? = lockScreenActions
        let needsDownloadDrain = workshop?.hasDownloadLifecycleWork == true ||
            workshop?.account.nativeContentBroker != nil || workshop?.account.isNativeContentCleaningUp == true
        if actions?.isCommitting == true || needsDownloadDrain {
            if lockScreenTerminationWait == nil {
                lockScreenTerminationWait = Task {
                    actions?.cancelPreparation()
                    await actions?.waitUntilIdle()
                    await workshop?.shutdownDownloads()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        actions?.cancelPreparation()
        return .terminateNow
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === previewWindow {
            // 关闭预览：立即拆掉视图层级并释放预览播放器，避免窗口引用存留时
            // 仍有隐藏的解码会话（R15）。真实桌面会话不受影响。
            window.contentViewController = nil
            previewPlayback?.clear()
            previewPlayback?.tearDownAll()
            previewPlayback = nil
            previewWindow = nil
        } else if window === libraryWindow {
            workshop.cancelOpeningWallpaperDetails()
            wallpaperDetails.dismiss()
            if let id = wallpaperDetails.route?.id { wallpaperDetails.finishDismissal(id) }
            // 关闭管理窗口：真实桌面播放继续；窗口内的预览播放器随视图层级销毁。
            window.contentViewController = nil
            libraryWindow = nil
        }
    }
}

/// 桌面预览窗口：在本窗口内用真实的播放路径显示素材，便于在不改动桌面壁纸的前提下先看效果。
///
/// 严格控制（R15）：预览使用独立且**不落盘**的播放控制器（真实 AVPlayerLayer，但绝不写
/// 素材库的分配、最近播放、每屏设置或文件字节），因此开关、切换、暂停/调速、停止、关闭
/// 预览都不会影响真实桌面与已保存的设置。
struct DesktopPreviewView: View {
    let store: VideoLibraryStore
    let displayRegistry: DisplayRegistry
    let controller: DesktopPlaybackController

    @GlassState private var selectedItemID: UUID?
    @GlassState private var message: String?
    @GlassState private var applyTask: Task<Void, Never>?

    var body: some View {
        GlassStyleReader { style in
            VStack(alignment: .leading, spacing: 12) {
                Text("预览只在这个窗口内播放素材，不会改变你的桌面壁纸，也不会修改保存的显示器分配与设置。要显示在桌面上，请在素材库里点击「应用」按钮。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Picker("素材", selection: $selectedItemID) {
                        Text("未选择").tag(UUID?.none)
                        ForEach(store.items) { item in
                            Text(item.displayTitle).tag(UUID?.some(item.id))
                        }
                    }
                    .frame(maxWidth: 380)

                    Button("开始预览") { startPreview() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedItemID == nil)
                    Button("停止预览") { stopPreview() }
                        .buttonStyle(.glass)
                        .disabled(controller.sessions.isEmpty)
                }

                if !controller.sessions.isEmpty {
                    PreviewSessionList(controller: controller)
                } else {
                    Text("尚未开始预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(style.panelBackground(cornerRadius: 0))
        }
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = store.items.first?.id
            }
        }
        .onDisappear {
            stopPreview()
        }
    }

    private func startPreview() {
        guard let selectedItemID, let item = store.item(withID: selectedItemID) else { return }
        applyTask?.cancel()
        message = "正在准备预览…"
        applyTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let error = await controller.applyAndWait(item: item, to: nil)
            guard !Task.isCancelled else { return }
            message = error.map { "预览失败：\($0)" } ?? "正在预览：\(item.displayTitle)"
        }
    }

    private func stopPreview() {
        applyTask?.cancel()
        applyTask = nil
        controller.clear()
        controller.tearDownAll()
        message = "预览已停止"
    }
}

/// 预览会话列表：每台显示器一行，使用与桌面完全相同的播放器与图层显示画面。
struct PreviewSessionList: View {
    let controller: DesktopPlaybackController
    @GlassState private var refreshTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预览会话（\(controller.sessions.count)）")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.sessions.sorted { $0.key < $1.key }, id: \.key) { entry in
                        sessionRow(entry.key, entry.value)
                    }
                }
            }
        }
        .id(refreshTick)
    }

    private func sessionRow(_ id: String, _ session: DesktopPlaybackSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PreviewSessionHostView(session: session)
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(session.display.localizedName).font(.callout)
                Text(session.item.displayTitle).font(.caption).foregroundStyle(.secondary)
                Text("\(session.item.resolutionText) · \(session.item.durationText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(session.isPlaying ? "暂停" : "播放") {
                        controller.playPause(displayID: id)
                        refreshTick += 1
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    if let error = session.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 把会话的 `WallpaperVideoHostView`（真实 AVPlayerLayer）放进 SwiftUI 层级。
struct PreviewSessionHostView: NSViewRepresentable {
    let session: DesktopPlaybackSession

    func makeNSView(context: Context) -> NSView {
        session.hostView ?? NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.needsLayout = true
    }
}
