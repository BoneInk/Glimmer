import AppKit
import SwiftUI

/// Separate entry point: never instantiates the production AppDelegate or restores desktop sessions.
@main
@MainActor
enum UIReviewMain {
    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimmer-UIReview-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("GW_UI_REVIEW_ROOT", root.path, 1)
        print("UI review isolated root: \(root.path)")
        let app = NSApplication.shared
        let delegate = UIReviewDelegate(root: root)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class UIReviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let root: URL
    var window: NSWindow?
    var previewWindow: NSWindow?
    var detailsReviewWindow: NSWindow?
    var detailsReviewSelection: WallpaperDetailsSelection?
    let workspaceWallpaperDetails = WorkspaceWallpaperDetails()
    let creatorAvatarTransition = WorkshopCreatorAvatarTransition()
    var lockScreenActions: LockScreenActionController?
    var lockScreenTerminationWait: Task<Void,Never>?
    var playback: DesktopPlaybackController?
    var store: VideoLibraryStore?
    var workshop: WorkshopCoordinator?
    var policy: GWPolicyController?
    var playlist: GWPlaylistRotator?

    init(root: URL) { self.root = root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await showWorkspace() }
    }

    // Only review booleans may be supplied by a cloned review bundle. Paths and
    // fixture metadata continue to require explicit command-line arguments.
    private let bundledFlags: Set<String> = {
        let allowed: Set<String> = ["--compact", "--dark", "--reduce-transparency", "--downloads", "--queue-review", "--library", "--progress-review", "--wallpaper-backdrop", "--reduce-motion", "--show-inspector", "--wallpaper-detail", "--video-detail", "--video-settings", "--lock-screen-review", "--details-window-review", "--web-author-review", "--scene-author-review", "--scene-script-review", "--scene-module-review", "--scene-parent-review"]
        guard let url = Bundle.main.url(forResource: "review-options", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 4096,
              let options = try? JSONDecoder().decode(ReviewOptions.self, from: data) else { return [] }
        return Set(options.flags).intersection(allowed)
    }()

    private struct ReviewOptions: Decodable {
        let flags: [String]
    }

    private func hasFlag(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag) || bundledFlags.contains(flag)
    }

    private func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func showWorkspace() async {
        if hasFlag("--progress-review") {
            showProgressReview()
            return
        }
        let storage = AppStorage(root: root)
        let lockScreenActions = LockScreenActionController(coordinator: .review(storage:storage))
        self.lockScreenActions = lockScreenActions
        let store = VideoLibraryStore(storage: storage)
        self.store = store
        let displays = DisplayRegistry()
        let playback = DesktopPlaybackController(store: store, displayRegistry: displays,
                                                  storage: storage, previewOnly: true,
                                                  writesToLibrary: hasFlag("--video-settings") || hasFlag("--details-window-review") || hasFlag("--web-author-review") || hasFlag("--scene-author-review") || hasFlag("--scene-script-review") || hasFlag("--scene-module-review") || hasFlag("--scene-parent-review"))
        self.playback = playback
        let importer = ImportService(store: store, storage: storage,
                                     thumbnailCache: ThumbnailCache(storage: storage))
        let paths = GWPersistencePaths(root: root)
        let policy = GWPolicyController(paths: paths, autoStartMonitoring: false)
        self.policy = policy
        let playlist = GWPlaylistRotator(paths: paths)
        self.playlist = playlist
        let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
        let queueReview = hasFlag("--queue-review")
        var preflight: (@MainActor () -> String?)? = nil
        if queueReview {
            preflight = { "隔离界面演示：下载未启动；仅验证排队与暂停界面。" }
        }
        let workshop = WorkshopCoordinator(account: SteamAccountManager(layout: layout),
            downloadPreflight: preflight, queuePersistence: .disabled)
        self.workshop = workshop
        workshop.onImportProject = { project, metadata in
            let source = project.videoProject?.videoURL ?? project.projectJSONURL
            switch await WorkshopWallpaperApplication.importItem(url: source, metadata: metadata, store: store, importer: importer) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        }
        let reviewRoot = root
        workshop.onApplyWallpaper = { url, metadata, target in
            let result = await WorkshopWallpaperApplication.apply(
                url: url, metadata: metadata, target: target,
                currentDisplayID: displays.primary?.id, store: store,
                importer: importer, displays: displays, playback: playback)
            let evidence: [String: Any] = [
                "result": result.message, "success": result.succeeded, "target": target.rawValue,
                "libraryItemCount": store.items.count, "sessionCount": playback.sessions.count,
                "desktopWindowCount": playback.sessions.values.filter { $0.window != nil }.count,
                "previewOnly": playback.sessions.values.allSatisfy { $0.isPreviewOnly },
                "savedAssignmentCount": displays.displays.filter { store.assignedItemID(for: $0.id) != nil }.count
            ]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reviewRoot.appendingPathComponent("wallpaper-apply-review.json"))
            }
            print("UI review explicit wallpaper action: \(result.message), sessions: \(playback.sessions.count)")
            return result
        }
        workshop.onOpenWallpaperDetails = { [weak self] url, metadata in
            guard let self else { return "界面验证正在结束" }
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item):
                guard !Task.isCancelled else { return "已取消打开详情" }
                self.workspaceWallpaperDetails.open(item)
                return nil
            case .failure(let error): return error.message
            }
        }
        workshop.onRequestDynamicLockScreen = { [weak self] url, metadata in
            guard let self else { return "界面验证正在结束" }
            if lockScreenActions.isBusy { return "请先完成或取消当前隔离演示" }
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item):
                guard !Task.isCancelled else { return "已取消打开隔离演示" }
                return lockScreenActions.startApply(item:item)
            case .failure(let error): return error.message
            }
        }
        workshop.deletionIsSimulated = true
        workshop.onDeleteWallpaper = { itemID in
            guard !lockScreenActions.isBusy else {return "请先完成或取消锁屏准备。"}
            guard let id = WorkshopItemID(itemID) else { return "演示作品 ID 不正确" }
            let source = layout.downloadDirectory(for: id).standardizedFileURL.resolvingSymlinksInPath()
            let safeRoot = reviewRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard source.path.hasPrefix(safeRoot) else { return "隔离演示拒绝访问临时目录以外的文件" }
            do {
                let trash = reviewRoot.appendingPathComponent("SimulatedTrash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source,
                    to: trash.appendingPathComponent("\(itemID)-\(UUID().uuidString)", isDirectory: true))
                // This controller is previewOnly and writesToLibrary:false; it has no real desktop sessions.
                playback.clear()
                for item in store.items where item.workshopID == itemID { store.remove(id: item.id) }
                return nil
            } catch { return "隔离演示删除失败：\(error.localizedDescription)" }
        }
        workshop.isDynamicLockScreenBusy = {lockScreenActions.isBusy}
        let settings = GWSettingsCoordinator(paths: GWSettingsPaths(root: root),
            external: AppSettingsWiring.externalActions(store: store, playback: playback, policy: policy, playlist: playlist))
        let cleanup = GWStorageCleanupController(paths: GWManagedStoragePaths(root: root),
            protectedURLsProvider: { AppSettingsWiring.protectedURLs(store: store, playback: playback) })
        // Login-item registration is deliberately unsupported in the review app.
        let loginItem = GWLoginItemService(bundleURL: root, bundleIdentifier: nil)

        // Copy only the explicitly selected video, and generate public project metadata locally.
        // No real Steam home/config/credentials/logs or download manifests are copied.
        let media = argument("--media").map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "ui-test-video", withExtension: "mp4")
        if argument("--web-project") == nil, !hasFlag("--scene-parent-review"), let media, WorkshopProjectResolver.isCandidateVideo(url: media) {
            let itemID = argument("--workshop-id").flatMap(WorkshopItemID.init) ?? WorkshopItemID("9999999999")!
            let title = argument("--media-title") ?? "界面验证视频（演示素材）"
            let directory = layout.downloadDirectory(for: itemID)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let copy = directory.appendingPathComponent("review-video.\(media.pathExtension)")
                try FileManager.default.copyItem(at: media, to: copy)
                let metadata: [String: String] = ["type": "video", "title": title, "file": copy.lastPathComponent]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("project.json"))
                if !hasFlag("--download-completion-review") {
                    await importer.importURLs([copy])
                    if let first = store.items.first {
                        store.rename(id: first.id, to: title)
                        store.mutate(id: first.id) { $0.workshopID = itemID.value }
                    }
                }
                await workshop.reloadDownloadedItems()
            } catch { print("Review fixture unavailable: \(error.localizedDescription)") }
        }

        if hasFlag("--web-author-review"),
           let fixture = Bundle.main.url(forResource: "WebAuthorWallpaper", withExtension: nil) {
            do {
                _ = try await WebWallpaperProjectImporter.importProject(fixture.appendingPathComponent("project.json"), store: store)
            } catch { print("Web author review fixture unavailable: \(error.localizedDescription)") }
        }
        if let project = argument("--web-project") {
            do { _ = try await WebWallpaperProjectImporter.importProject(URL(fileURLWithPath: project), store: store) }
            catch { print("Explicit Web review fixture unavailable: \(error.localizedDescription)") }
        }

        if hasFlag("--scene-author-review") || hasFlag("--scene-script-review") || hasFlag("--scene-module-review") || hasFlag("--scene-parent-review") {
            let fixture = argument("--scene-project").map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.url(forResource: hasFlag("--scene-parent-review") ? "SceneHierarchyWallpaper" : hasFlag("--scene-module-review") ? "SceneModuleWallpaper" : hasFlag("--scene-script-review") ? "SceneScriptWallpaper" : "SceneImageWallpaper", withExtension: nil)
            if let fixture {
                switch await importer.importLocalSceneProject(fixture) {
                case .imported, .duplicated: break
                case .failed(let message): print("Scene author review fixture unavailable: \(message)")
                }
            }
        }

        // Exercise a real decoder/session against the isolated demonstration video.
        // previewOnly suppresses desktop windows; writesToLibrary suppresses assignments.
        if hasFlag("--wallpaper-backdrop"), let item = store.items.first,
           let primary = displays.primary {
            if let error = await playback.applyAndWait(item: item, to: [primary.id]) {
                print("Review wallpaper backdrop unavailable: \(error)")
            }
        }

        if queueReview {
            workshop.setDownloadQueuePaused(true)
            workshop.enqueueDownload(WorkshopDownloadItem(publishedFileID: "9999999997",
                title: "排队演示 · 等待继续队列", kind: .video, declaredTags: ["Video"],
                previewImageURLString: nil, fileSizeBytes: 48_000_000, state: .queued))
            workshop.enqueueDownload(WorkshopDownloadItem(publishedFileID: "9999999998",
                title: "暂停演示 · 独立暂停", kind: .video, declaredTags: ["Video"],
                previewImageURLString: nil, fileSizeBytes: 64_000_000, state: .queued))
            workshop.pauseDownload(itemID: "9999999998")
        }
        let destination: AppDestination = (hasFlag("--library") || hasFlag("--web-author-review") || hasFlag("--scene-author-review") || hasFlag("--scene-script-review") || hasFlag("--scene-module-review") || hasFlag("--scene-parent-review")) ? .library(.all)
            : (hasFlag("--downloads") || queueReview ? .downloads : .workshop)
        let view = AppWorkspaceView(store: store, importService: importer, playback: playback,
            displays: displays, workshop: workshop, policy: policy, playlist: playlist,
            settings: settings, cleanup: cleanup, loginItem: loginItem,
            onOpenPreview: { [weak self] in
                let preview = NSWindow(contentViewController: NSHostingController(rootView:
                    DesktopPreviewView(store: store, displayRegistry: displays, controller: playback)))
                preview.title = "Glimmer · 界面验证 · 桌面预览"
                preview.setContentSize(NSSize(width: 800, height: 580))
                preview.styleMask.insert([.closable, .resizable])
                preview.isReleasedWhenClosed = false
                preview.center()
                preview.makeKeyAndOrderFront(nil)
                self?.previewWindow = preview
            }, onOpenDynamicLockScreen: { [weak self] item in
                self?.showLockScreenReview(item: item, storage: storage)
            }, onOpenWallpaperDetails: { [weak self] item in
                self?.showWallpaperDetailsReview(item: item, storage: storage, displays: displays, playback: playback)
            }, initialDestination: destination, wallpaperDetails: workspaceWallpaperDetails,
            avatarTransition: creatorAvatarTransition)
        let reduceTransparency = hasFlag("--reduce-transparency")
        let reviewContent: AnyView
        if hasFlag("--details-window-review"), let item = store.items.first {
            let selection = WallpaperDetailsSelection(itemID: item.id)
            detailsReviewSelection = selection
            reviewContent = AnyView(WallpaperDetailsWindowContent(store: store, selection: selection,
                displays: displays, playback: playback, onClose: { NSApp.terminate(nil) }, policy: policy,
                onOpenDynamicLockScreen: { [weak self] item in self?.showLockScreenReview(item: item, storage: storage) }))
        } else if hasFlag("--lock-screen-review"), let item = store.items.first {
            // Always inject the fake/temporary backend: this branch cannot create the production service.
            reviewContent = AnyView(VStack(alignment:.leading,spacing:20) {
                Text("动态锁屏 · 隔离演示，不写系统").font(.headline)
                LockScreenApplyControls(item:item)
                LockScreenMaintenanceSection()
                Spacer()
            }.padding(24))
        } else if hasFlag("--video-detail"), let item = workshop.downloadProgress.items.first,
           let preview = workshop.localPreview(for: item.id) {
            reviewContent = AnyView(WorkshopVideoPreviewSheet(preview: preview, coordinator: workshop))
        } else if hasFlag("--wallpaper-detail"), let item = workshop.downloadProgress.items.first {
            let result = WorkshopSearchResult(publishedFileID: item.id, title: "设为壁纸验证（演示素材）",
                shortDescription: "隔离验证：只有明确点击设为壁纸，才会启动无桌面窗口的预览会话。",
                tags: ["Video"], childCount: 0, isCollection: false)
            reviewContent = AnyView(GlassStyleReader { style in
                WorkshopSearchResultDetail(result: result, coordinator: workshop, style: style)
            })
        } else if hasFlag("--download-completion-review"), let download = workshop.downloadProgress.items.first {
            let result = WorkshopSearchResult(publishedFileID: download.id, title: download.title,
                shortDescription: "下载已校验，等待模拟素材导入完成。", tags: ["Video"], childCount: 0, isCollection: false)
            workspaceWallpaperDetails.open(result)
            reviewContent = AnyView(view.overlay(alignment: .topTrailing) {
                Button("完成模拟素材导入") { [weak self] in
                    Task { @MainActor in
                        guard let self, let project = download.validatedProject, let metadata = download.metadata else { return }
                        let previousRouteID = self.workspaceWallpaperDetails.route?.id
                        let error = await workshop.onImportProject?(project, metadata)
                        try? await Task.sleep(for: .milliseconds(300))
                        let evidence: [String: Any] = [
                            "error": error ?? "", "libraryItemCount": store.items.count,
                            "promotedItemID": self.workspaceWallpaperDetails.route?.item?.id.uuidString ?? "",
                            "hasPublicResult": self.workspaceWallpaperDetails.route?.result != nil,
                            "preservedRouteID": self.workspaceWallpaperDetails.route?.id == previousRouteID,
                            "sessionCount": playback.sessions.count, "savedAssignmentCount": store.assignments.count
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: reviewRoot.appendingPathComponent("download-completion-review.json"))
                        }
                    }
                }
                .buttonStyle(.glass).padding(16)
                .accessibilityIdentifier("review-complete-import")
            })
        } else {
            reviewContent = AnyView(view)
        }
        let reviewView = reviewContent
            .modifier(CreatorAvatarReviewEvidence(transition: creatorAvatarTransition,
                presentation: workspaceWallpaperDetails, root: root))
            .environment(\.lockScreenActions, lockScreenActions)
            .environment(\.libraryReviewShowInspector, hasFlag("--show-inspector"))
            .environment(\.windowGlassReduceTransparencyOverride, reduceTransparency)
            .environment(\.windowGlassReduceMotionOverride, hasFlag("--reduce-motion"))
            .preferredColorScheme(hasFlag("--dark") ? .dark : nil)
        let isWorkspaceReview = !["--details-window-review", "--lock-screen-review", "--video-detail", "--wallpaper-detail"].contains(where: hasFlag)
        let window = WindowGlassBackdrop.makeWindow(rootView: reviewView, forceReduceTransparency: reduceTransparency,
                                                    hidesPageTitle: isWorkspaceReview)
        if hasFlag("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.title = (hasFlag("--wallpaper-backdrop") || hasFlag("--wallpaper-detail") || hasFlag("--video-detail") || hasFlag("--lock-screen-review"))
            ? "Glimmer · 界面验证 · 演示素材背景（独立数据）"
            : "Glimmer · 界面验证 · 独立数据"
        if hasFlag("--lock-screen-review") { window.title = "动态锁屏 · 隔离演示 · 不写系统" }
        if hasFlag("--details-window-review") { window.title = "详情与设置 · 隔离演示素材" }
        let compact = hasFlag("--compact")
        window.setContentSize(hasFlag("--details-window-review") ? NSSize(width: 520, height: 740)
            : hasFlag("--lock-screen-review") ? NSSize(width: 620, height: 700) : NSSize(width: compact ? 1000 : 1200, height: compact ? 680 : 800))
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        if hasFlag("--lock-screen-review") { window.delegate = self }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showWallpaperDetailsReview(item: WallpaperItem, storage: AppStorage,
                                           displays: DisplayRegistry, playback: DesktopPlaybackController,
                                           cancelPendingRequest: Bool = true) {
        guard let store else { return }
        if cancelPendingRequest { workshop?.cancelOpeningWallpaperDetails() }
        if let window = detailsReviewWindow, let selection = detailsReviewSelection {
            selection.itemID = item.id
            window.makeKeyAndOrderFront(nil)
        } else {
            let selection = WallpaperDetailsSelection(itemID: item.id)
            detailsReviewSelection = selection
            let view = WallpaperDetailsWindowContent(store: store, selection: selection, displays: displays,
                playback: playback, onClose: { [weak self] in self?.detailsReviewWindow?.performClose(nil) }, policy: policy,
                onOpenDynamicLockScreen: { [weak self] item in self?.showLockScreenReview(item: item, storage: storage) })
                .environment(\.lockScreenActions, lockScreenActions)
                .environment(\.windowGlassReduceTransparencyOverride, hasFlag("--reduce-transparency"))
                .environment(\.windowGlassReduceMotionOverride, hasFlag("--reduce-motion"))
                .preferredColorScheme(hasFlag("--dark") ? .dark : nil)
            let window = WindowGlassBackdrop.makeWindow(rootView: view, forceReduceTransparency: hasFlag("--reduce-transparency"))
            window.title = "详情与设置 · 隔离演示素材"
            window.setContentSize(NSSize(width: 520, height: 740))
            window.styleMask.insert([.titled, .closable, .resizable])
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            detailsReviewWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        let evidence: [String: Any] = ["itemID": item.id.uuidString, "title": item.displayTitle,
            "libraryItemCount": store.items.count, "sessionCount": playback.sessions.count,
            "desktopWindowCount": playback.sessions.values.filter { $0.window != nil }.count,
            "savedAssignmentCount": store.assignments.count, "detailWindowCount": 1]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: storage.root.appendingPathComponent("details-window-review.json"))
        }
    }

    private func showLockScreenReview(item: WallpaperItem, storage: AppStorage) {
        _ = lockScreenActions?.startApply(item:item)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        if closed === detailsReviewWindow {
            workshop?.cancelOpeningWallpaperDetails()
            closed.contentViewController = nil
            detailsReviewWindow = nil
            detailsReviewSelection = nil
        }
    }

    /// Fixture-only branch: no account, downloader, library, or desktop controller is created.
    private func showProgressReview() {
        let reduceTransparency = hasFlag("--reduce-transparency")
        let view = WorkshopRingReviewView()
            .environment(\.windowGlassReduceTransparencyOverride, reduceTransparency)
            .environment(\.windowGlassReduceMotionOverride, hasFlag("--reduce-motion"))
            .preferredColorScheme(hasFlag("--dark") ? .dark : nil)
        let window = WindowGlassBackdrop.makeWindow(rootView: view, forceReduceTransparency: reduceTransparency)
        if hasFlag("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.title = "下载按钮状态验证 · 模拟进度"
        window.setContentSize(NSSize(width: 1120, height: 960))
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let actions=lockScreenActions else{return .terminateNow}
        if actions.isCommitting {
            if lockScreenTerminationWait == nil {
                lockScreenTerminationWait=Task {await actions.waitUntilIdle();sender.reply(toApplicationShouldTerminate:true)}
            }
            return .terminateLater
        }
        actions.cancelPreparation();return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        lockScreenActions?.cancelPreparation()
        playback?.tearDownAll()
        policy?.shutdown()
        playlist?.shutdown()
        workshop?.cancelActiveDownload()
        workshop?.cancelOpeningWallpaperDetails()
        store?.flush()
    }
}

private struct CreatorAvatarReviewEvidence: ViewModifier {
    let transition: WorkshopCreatorAvatarTransition
    let presentation: WorkspaceWallpaperDetails
    let root: URL
    func body(content: Content) -> some View {
        content.onChange(of: transition.flight?.id) { _, id in
            guard id != nil, let flight = transition.flight else { return }
            func rectangle(_ frame: CGRect) -> [String: Double] {
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            let values: [String: Any] = [
                "authorID": flight.authorID, "source": rectangle(flight.source.frame),
                "destination": rectangle(flight.destination.frame),
                "movesUpward": flight.destination.frame.midY < flight.source.frame.midY,
                "capturedSourceBitmap": flight.source.image != nil,
                "wallpaperRouteCleared": presentation.route == nil,
                "wallpaperReturning": presentation.closing
            ]
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("creator-avatar-transition-review.json"))
            }
        }
    }
}
