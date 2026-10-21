import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation

/// 承载 AVPlayerLayer 的真实视图。
///
/// 桌面窗口与预览窗口共用同一条渲染路径：都是「NSView + AVPlayerLayer」，
/// 因此在预览窗口中看到的画面与桌面窗口使用完全相同的解码与合成方式。
@MainActor
final class WallpaperVideoHostView: NSView {
    let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        wantsLayer = true
        let backing = CALayer()
        backing.backgroundColor = NSColor.black.cgColor
        layer = backing
        backing.addSublayer(playerLayer)
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        autoresizesSubviews = true
        updateLayerFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WallpaperVideoHostView 不支持从归档创建")
    }

    override func layout() {
        super.layout()
        updateLayerFrame()
    }

    private func updateLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 一台显示器上的视频播放会话。
///
/// 生命周期：`apply` 创建 → 用户在管理窗口/菜单栏控制 → `tearDown` 释放。
/// 切换素材时必须先 `tearDown` 旧会话，确保不残留孤儿播放器与渲染图层。
@MainActor
final class DesktopPlaybackSession {
    let display: DisplayDescriptor
    let item: WallpaperItem
    private let appSettings: AppSettings
    private(set) var window: NSWindow?
    private(set) var playerLayer: AVPlayerLayer?
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var settings: DisplayPlaybackSettings
    private(set) var isPreviewOnly: Bool
    private var storedLastError: String?
    var lastError: String? { sceneRuntime?.lastError ?? webRuntime?.lastError ?? storedLastError }
    /// 预览模式：承载画面的真实视图（由预览窗口显示）。
    private(set) var hostView: WallpaperVideoHostView?
    /// 解码取证通道：AVPlayerItemVideoOutput 取到的是真实解码帧。
    private var decodeOutput: AVPlayerItemVideoOutput?
    private var failureObserver: NSObjectProtocol?
    private(set) var webRuntime: WebWallpaperRuntime?
    private(set) var sceneRuntime: SceneWallpaperRuntime?
    private var sceneSetupTask: Task<Void, Error>?
    private var sceneHostToken: UUID?
    private(set) var webHostView: NSView?
    private var webSetupTask: Task<Void, Never>?
    private var webPaused = true
    private var webPropertyRevision = 0
    private var webHostToken: UUID?
    private let authorStorage: AppStorage
    private var wallpaperFPS: Int


    var isPlaying: Bool {
        if let sceneRuntime { return sceneRuntime.state == .ready }
        if let webRuntime { return !webPaused && webRuntime.state == .ready }
        return (player?.rate ?? 0) != 0
    }
    var currentRate: Float { player?.rate ?? 0 }
    var currentTimeSeconds: Double {
        guard let time = player?.currentTime(), time.isNumeric else { return 0 }
        return time.seconds
    }

    init(
        display: DisplayDescriptor,
        item: WallpaperItem,
        settings: DisplayPlaybackSettings,
        appSettings: AppSettings,
        previewOnly: Bool,
        wallpaperFPS: Int = 30,
        authorStorage: AppStorage = AppStorage()
    ) {
        self.display = display
        self.item = item
        self.settings = settings
        self.appSettings = appSettings
        self.isPreviewOnly = previewOnly
        self.wallpaperFPS = min(max(wallpaperFPS, 1), 240)
        self.authorStorage = authorStorage
    }

    /// 建立播放器与桌面窗口。返回失败原因（nil 表示成功）。
    ///
    /// `policySuspended` 为真时（睡眠/锁屏/省电策略挂起）即使保存的意图是播放也先保持暂停：
    /// 策略层永远不改写用户保存的 `isPaused`。
    @discardableResult
    func start(policySuspended: Bool = false) -> String? {
        guard item.fileExists else {
            storedLastError = "媒体文件不存在：\(item.displayTitle)"
            return lastError
        }
        if item.isSceneWallpaper { return startScene(policySuspended: policySuspended) }
        if item.isWebWallpaper { return startWeb(policySuspended: policySuspended) }
        let asset = AVURLAsset(url: item.fileURL)
        let assetItem = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .advance

        // AVPlayerLooper 在当前 SDK 中不是 throwing 初始化；创建后通过 looper.status 观察结果。
        let looper = AVPlayerLooper(player: queuePlayer, templateItem: assetItem)

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = settings.gravity == .fill ? .resizeAspectFill : .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor

        queuePlayer.isMuted = settings.isMuted
        queuePlayer.volume = settings.clampedVolume
        queuePlayer.defaultRate = settings.clampedRate

        if settings.isPaused || policySuspended {
            queuePlayer.pause()
        } else {
            // play() 会把速率重置为 1.0；playImmediately(atRate:) 才能保留用户选择的速度。
            queuePlayer.playImmediately(atRate: settings.clampedRate)
        }

        self.player = queuePlayer
        self.looper = looper
        self.playerLayer = layer

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // 只把 Sendable 的值带进隔离区：通知对象本身不可并发传递。
            let failedItemID = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断"
            MainActor.assumeIsolated {
                guard let self, let failedItemID else { return }
                // AVPlayerLooper 会复制条目，因此按对象标识而不是预过滤对象身份来判断归属。
                guard self.player?.items().contains(where: { ObjectIdentifier($0) == failedItemID }) == true else { return }
                self.storedLastError = message
            }
        }

        if isPreviewOnly {
            hostView = WallpaperVideoHostView(playerLayer: layer)
        } else {
            let window = DesktopWallpaperWindow(
                frame: display.frame,
                hostView: WallpaperVideoHostView(playerLayer: layer),
                level: desktopLevel,
                displayID: display.displayID
            )
            window.orderFrontRegardless()
            self.window = window
        }
        storedLastError = nil
        return nil
    }

    private func startWeb(policySuspended: Bool) -> String? {
        do {
            let project = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
            let runtime = try WebWallpaperRuntime(projectURL: project.projectURL,
                entryURL: project.entryURL, propertiesJSON: Data("{}".utf8))
            try runtime.setFrameRateLimit(wallpaperFPS)
            webRuntime = runtime
            webHostToken = AuthorPropertyServices.shared.register(runtime, itemID: item.id, onConfigurationChange: { [weak self] in self?.webPropertyRevision += 1 })
            webPaused = settings.isPaused || policySuspended
            runtime.setPaused(webPaused)
            let host = runtime.webView
            webHostView = host
            if !isPreviewOnly {
                let window = DesktopWallpaperWindow(frame: display.frame, hostView: host,
                    level: desktopLevel, displayID: display.displayID)
                window.orderFrontRegardless()
                self.window = window
            }
            let revision = webPropertyRevision
            webSetupTask = Task { [weak self, weak runtime] in
                guard let self, let runtime else { return }
                do {
                    let config = try await AuthorPropertyServices.configuration(item: self.item, storage: self.authorStorage)
                    guard !Task.isCancelled, self.webRuntime === runtime else { return }
                    if revision == self.webPropertyRevision {
                        try runtime.configureResourceManifest(config.manifest)
                        try runtime.applyPropertiesJSON(config.payload)
                    }
                    runtime.setPaused(self.webPaused)
                    runtime.load()
                } catch {
                    guard !Task.isCancelled, self.webRuntime === runtime else { return }
                    self.storedLastError = error.localizedDescription
                }
            }
            storedLastError = nil
            return nil
        } catch {
            storedLastError = error.localizedDescription
            return lastError
        }
    }

    private func startScene(policySuspended: Bool) -> String? {
        do {
            let screen = isPreviewOnly ? SceneVector2(x:display.pixelSize.width,y:display.pixelSize.height)
                : SceneWallpaperRuntime.physicalScreenResolution(displayID: display.displayID)
            let runtime = try SceneWallpaperRuntime(projectURL: item.fileURL, screenResolution: screen)
            try runtime.setFrameRateLimit(wallpaperFPS)
            sceneRuntime = runtime
            runtime.hostView.frame = CGRect(origin: .zero, size: display.frame.size)
            runtime.setAspectFill(settings.gravity == .fill)
            runtime.setPaused(settings.isPaused || policySuspended)
            sceneHostToken = AuthorPropertyServices.shared.registerScene(runtime, itemID: item.id)
            if !isPreviewOnly {
                // Prepare invisibly. The controller publishes the new session only
                // after the actual image is ready, preserving the previous wallpaper.
                window = DesktopWallpaperWindow(frame: display.frame, hostView: runtime.hostView,
                    level: desktopLevel, displayID: display.displayID)
            }
            sceneSetupTask = Task { [weak self, weak runtime] in
                guard let self, let runtime else { throw CancellationError() }
                let payload = try await AuthorPropertyServices.payload(item: self.item, storage: self.authorStorage)
                try Task.checkCancellation()
                try await runtime.load(propertiesJSON: payload)
                try Task.checkCancellation()
                guard self.sceneRuntime === runtime else { throw CancellationError() }
                // The saved display settings are the user's scene-music intent; default is muted.
                runtime.setSceneSound(enabled: !self.settings.isMuted,
                                      volume: Double(self.settings.clampedVolume))
            }
            return nil
        } catch { storedLastError = error.localizedDescription; return storedLastError }
    }

    func waitForSceneReady() async throws {
        try await sceneSetupTask?.value
        guard let sceneRuntime, sceneRuntime.state == .ready || sceneRuntime.state == .paused else {
            throw SceneWallpaperFailure(message: lastError ?? "Scene 尚未完成画面准备")
        }
    }

    func revealPreparedScene() { window?.orderFrontRegardless() }

    func updateAuthorProperties(_ payload: Data) throws {
        try webRuntime?.applyPropertiesJSON(payload)
        webPropertyRevision += 1
    }

    func setWallpaperFPS(_ fps: Int) {
        wallpaperFPS = min(max(fps, 1), 240)
        try? webRuntime?.setFrameRateLimit(wallpaperFPS)
        try? sceneRuntime?.setFrameRateLimit(wallpaperFPS)
    }

    private var desktopLevel: NSWindow.Level {
        switch appSettings.desktopLayer {
        case .desktop: return DesktopWallpaperWindow.desktopPlaneLevel
        case .desktopIcon: return DesktopWallpaperWindow.desktopIconLevel
        }
    }

    // MARK: - 播放控制

    func play() {
        startPlayback()
    }

    func pause() {
        sceneRuntime?.setPaused(true)
        webPaused = true
        webRuntime?.setPaused(true)
        player?.pause()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// 以当前设置的速率开始/继续播放，且不覆盖用户选择的速率。
    private func startPlayback() {
        if let sceneRuntime { sceneRuntime.setPaused(false); return }
        if let webRuntime { webPaused = false; webRuntime.setPaused(false); return }
        guard let player else { return }
        let rate = settings.clampedRate
        player.defaultRate = rate
        if player.rate != 0 {
            // 已在播放：直接调整速率（不会触发 play() 的速率重置）
            player.rate = rate
        } else {
            player.playImmediately(atRate: rate)
        }
    }

    /// 应用新的播放设置。
    ///
    /// `allowPlay` 为 false（策略挂起期间）时只更新静音/音量/倍速/画面适配并保持暂停，
    /// 绝不恢复播放——挂起期间的设置调整不得绕过策略。
    func apply(settings newSettings: DisplayPlaybackSettings, allowPlay: Bool = true) {
        settings = newSettings
        if let sceneRuntime {
            sceneRuntime.setAspectFill(newSettings.gravity == .fill)
            sceneRuntime.setPaused(newSettings.isPaused || !allowPlay)
            sceneRuntime.setSceneSound(enabled: !newSettings.isMuted, volume: Double(newSettings.clampedVolume))
            return
        }
        if let webRuntime {
            webPaused = newSettings.isPaused || !allowPlay
            webRuntime.setPaused(webPaused)
            return
        }
        guard let player else { return }
        player.isMuted = newSettings.isMuted
        player.volume = newSettings.clampedVolume
        player.defaultRate = newSettings.clampedRate
        playerLayer?.videoGravity = newSettings.gravity == .fill ? .resizeAspectFill : .resizeAspect
        if newSettings.isPaused || !allowPlay {
            player.pause()
        } else {
            startPlayback()
        }
    }

    func updateFrame(for display: DisplayDescriptor) {
        window?.setFrame(display.frame, display: true)
        if let runtime = sceneRuntime {
            let size = isPreviewOnly ? SceneVector2(x:display.pixelSize.width,y:display.pixelSize.height)
                : SceneWallpaperRuntime.physicalScreenResolution(displayID: display.displayID)
            guard let size else { return }
            Task { [weak runtime] in
                do { try await runtime?.updateScreenResolutionAndWait(size) }
                catch { /* Runtime exposes failure and preserves its last successful pixels. */ }
            }
        }
    }

    func tearDown() {
        sceneSetupTask?.cancel()
        sceneSetupTask = nil
        if let sceneHostToken { AuthorPropertyServices.shared.unregisterScene(itemID: item.id, token: sceneHostToken) }
        sceneHostToken = nil
        sceneRuntime?.dispose()
        sceneRuntime = nil
        webSetupTask?.cancel()
        webSetupTask = nil
        if let webHostToken { AuthorPropertyServices.shared.unregister(itemID: item.id, token: webHostToken) }
        webHostToken = nil
        webRuntime?.dispose()
        webRuntime = nil
        webHostView = nil
        webPaused = true
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        hostView?.playerLayer.player = nil
        window?.ignoresMouseEvents = true
        window?.orderOut(nil)
        window?.close()
        window = nil
        hostView = nil
        playerLayer = nil
        player = nil
        looper = nil
        decodeOutput = nil
    }

    // MARK: - 解码取证

    /// 通过 `AVPlayerItemVideoOutput` 抓取一帧真实解码结果。
    ///
    /// 注意：`AVPlayerLayer.render(in:)` 只反映图层属性，不能作为「画面已显示」的证据；
    /// 这里取的是播放管线实际解码出的像素缓冲，可用于验证解码、画面变化与循环。
    func captureDecodedFrame() -> CGImage? {
        guard let player, let currentItem = player.currentItem else { return nil }
        let output = ensureDecodeOutput(on: currentItem)
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        var sampleTime = itemTime
        if !output.hasNewPixelBuffer(forItemTime: itemTime) {
            sampleTime = player.currentTime()
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: sampleTime, itemTimeForDisplay: nil) else {
            return nil
        }
        return Self.makeCGImage(from: buffer)
    }

    /// 轮询等待一帧解码结果（用于启动初期或暂停后恢复）。
    func waitForDecodedFrame(timeout: TimeInterval = 3.0) async -> CGImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let image = captureDecodedFrame() { return image }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    private func ensureDecodeOutput(on item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let decodeOutput, item.outputs.contains(where: { $0 === decodeOutput }) {
            return decodeOutput
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        decodeOutput = output
        return output
    }

    static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return context.makeImage()
    }

    func diagnostics() -> [String] {
        var lines: [String] = []
        lines.append("显示器: \(display.localizedName) [\(display.shortIdentifier)] \(display.resolutionText)")
        lines.append("素材: \(item.displayTitle) (\(PathRedaction.short(item.fileURL)))")
        if let player {
            lines.append("播放器: rate=\(String(format: "%.2f", player.rate)) muted=\(player.isMuted) volume=\(String(format: "%.2f", player.volume)) status=\(statusText(player.status)) 时间=\(String(format: "%.2f", currentTimeSeconds))s")
        }
        if let currentItem = player?.currentItem {
            lines.append("当前条目: status=\(statusText(currentItem.status))\(currentItem.error.map { " error=\($0.localizedDescription)" } ?? "")")
        }
        if let window {
            lines.append("桌面窗口: level=\(window.level.rawValue) 可见=\(window.isVisible) 忽略鼠标=\(window.ignoresMouseEvents)")
        } else if isPreviewOnly {
            lines.append("预览会话: 使用预览窗口显示，不创建桌面窗口")
        }
        if let lastError { lines.append("错误: \(lastError)") }
        return lines
    }

    private func statusText(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    private func statusText(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }
}

/// 桌面级无边框窗口：位于桌面平面，鼠标事件穿透，不参与窗口循环。
///
/// 仅使用公开 AppKit API（窗口层级 + `ignoresMouseEvents`），不调用任何私有壁纸接口，
/// 也不会修改用户的桌面图片设置。
@MainActor
final class DesktopWallpaperWindow: NSWindow {
    /// 桌面图标之下的平面（推荐）：视频可见，桌面图标与点击都正常。
    static let desktopPlaneLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    /// 桌面图标平面：受阻时使用。图标仍接收点击，但视频会覆盖图标区域。
    static let desktopIconLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))

    let displayID: UInt32

    init(frame: CGRect, hostView: NSView, level: NSWindow.Level, displayID: UInt32) {
        self.displayID = displayID
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = level
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isOpaque = true
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.isMovable = false
        self.animationBehavior = .none
        self.tabbingMode = .disallowed
        self.acceptsMouseMovedEvents = false
        self.setFrame(frame, display: false)
        hostView.frame = NSRect(origin: .zero, size: frame.size)
        hostView.autoresizingMask = [.width, .height]
        self.contentView = hostView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 桌面播放控制器：每台显示器一个会话，统一处理切换、控制、屏幕变化与退出清理。
///
/// 只做「窗口叠层播放」：不写入系统桌面图片，因此退出/清除时只需要关闭窗口，
/// 用户的桌面图片始终保持不变。
@MainActor
@Observable
final class DesktopPlaybackController {
    private(set) var sessions: [String: DesktopPlaybackSession] = [:]
    /// 最近一次操作的用户可见说明（成功/失败），用于状态栏与诊断。
    private(set) var lastMessage: String?
    private(set) var lastError: String?
    /// 因显示器断开而被挂起的会话：显示器 ID → 素材 ID（重新连接后恢复）。
    private(set) var suspendedAssignments: [String: UUID] = [:]
    /// 策略层（睡眠/锁屏/省电等）是否正在挂起播放。
    ///
    /// 该标志只影响真实会话的播放/暂停，绝不写入用户保存的 `isPaused`；
    /// 挂起期间应用/切换素材、调整静音/音量/倍速都必须保持暂停。
    private(set) var isPolicySuspended = false
    /// 用户显式播放/暂停操作完成后的回调（用于同步全局策略意图）。
    /// 策略自动暂停/恢复不触发该回调，避免与全局意图形成反馈循环。
    var onUserPlaybackCommand: (() -> Void)?

    private let store: VideoLibraryStore
    private let displayRegistry: DisplayRegistry
    private let storage: AppStorage
    private let previewOnly: Bool
    /// 是否把播放操作（分配/最近播放/每屏设置/停止）写入素材库。
    ///
    /// - 真实桌面播放：true（默认）；
    /// - 桌面预览窗口：false（预览必须完全隔离，绝不改动真实分配、设置、最近播放与文件字节）；
    /// - 自检无窗口会话：true（在不创建真实桌面窗口的前提下验证真实写入语义）。
    private let writesToLibrary: Bool
    private var isTearingDown = false
    private var sceneRequestTickets: [String: UUID] = [:]
    private var pendingSceneSessions: [String: DesktopPlaybackSession] = [:]
    private var scheduledSceneIntent = UUID()
    /// Isolated preview edits never change the library. A stored nil means inherit display defaults.
    private var previewVideoPreferences: [UUID: VideoPlaybackPreferences?] = [:]
    private(set) var wallpaperFPS = 30

    init(
        store: VideoLibraryStore,
        displayRegistry: DisplayRegistry,
        storage: AppStorage = AppStorage(),
        previewOnly: Bool = false,
        writesToLibrary: Bool = true
    ) {
        self.store = store
        self.displayRegistry = displayRegistry
        self.storage = storage
        self.previewOnly = previewOnly
        self.writesToLibrary = writesToLibrary
    }

    // MARK: - 查询

    var activeDisplayCount: Int { sessions.count }
    var isPlayingAnywhere: Bool { sessions.values.contains { $0.isPlaying } }
    var suspendedDisplayIDs: [String] { suspendedAssignments.keys.sorted() }

    func session(for displayID: String) -> DesktopPlaybackSession? {
        sessions[displayID]
    }

    func setWallpaperFPS(_ fps: Int) {
        wallpaperFPS = min(max(fps, 1), 240)
        for session in sessions.values { session.setWallpaperFPS(wallpaperFPS) }
        for session in pendingSceneSessions.values { session.setWallpaperFPS(wallpaperFPS) }
    }

    // MARK: - 应用 / 清除

    /// 将素材应用到指定显示器（`nil` 表示全部）。
    @discardableResult
    func apply(item: WallpaperItem, to displayIDs: [String]?) -> String? {
        if item.isSceneWallpaper {
            // Legacy synchronous clients (menu bar/rotation) still use the real
            // asynchronous transaction; no assignments are changed while loading.
            lastMessage = "正在准备 Scene 壁纸…"
            let intent = UUID()
            scheduledSceneIntent = intent
            Task { [weak self] in
                guard let self, self.scheduledSceneIntent == intent else { return }
                _ = await self.applyAndWait(item: item, to: displayIDs)
            }
            return nil
        }
        scheduledSceneIntent = UUID()
        let targets: [DisplayDescriptor]
        if let displayIDs {
            targets = displayIDs.compactMap { displayRegistry.descriptor(for: $0) }
        } else {
            targets = displayRegistry.displays
        }
        guard !targets.isEmpty else {
            lastError = "没有可用显示器"
            return lastError
        }
        guard item.fileExists else {
            let message = "素材文件不存在，无法应用：\(item.displayTitle)"
            lastError = message
            return message
        }

        var problems: [String] = []
        for display in targets {
            invalidateSceneRequest(display.id)
            suspendedAssignments.removeValue(forKey: display.id)
            startSession(item: item, display: display, problems: &problems)
            if writesToLibrary, sessions[display.id]?.item.id == item.id {
                store.assign(itemID: item.id, to: display.id)
                store.markPlayed(id: item.id)
            }
        }
        if writesToLibrary { store.flush() }
        onUserPlaybackCommand?()

        if problems.isEmpty {
            lastMessage = targets.count == 1
                ? "已在「\(targets[0].localizedName)」上应用：\(item.displayTitle)"
                : "已应用到 \(targets.count) 台显示器：\(item.displayTitle)"
            lastError = nil
            return nil
        }
        lastMessage = "部分显示器应用失败"
        lastError = problems.joined(separator: "；")
        return lastError
    }

    private func startSession(item: WallpaperItem, display: DisplayDescriptor, problems: inout [String]) {
        if item.isSceneWallpaper {
            invalidateSceneRequest(display.id)
            let ticket = UUID()
            sceneRequestTickets[display.id] = ticket
            Task { [weak self] in
                guard let self, self.sceneRequestTickets[display.id] == ticket else { return }
                _ = await self.prepareScene(item: item, targets: [display], persist: false)
            }
            return
        }
        let settings = effectiveSettings(for: item.id, displayID: display.id)
        let session = DesktopPlaybackSession(
            display: display,
            item: item,
            settings: settings,
            appSettings: store.appSettings,
            previewOnly: previewOnly,
            wallpaperFPS: wallpaperFPS,
            authorStorage: storage
        )
        if let error = session.start(policySuspended: isPolicySuspended) {
            session.tearDown()
            problems.append("\(display.localizedName)：\(error)")
            return
        }
        sessions[display.id]?.tearDown()
        sessions[display.id] = session
    }

    /// Scene preparation is asynchronous and may reject unsupported behavior.
    /// Keep existing sessions and assignments until every target has real pixels.
    @discardableResult
    func applyAndWait(item: WallpaperItem, to displayIDs: [String]?) async -> String? {
        guard item.isSceneWallpaper else { return apply(item: item, to: displayIDs) }
        scheduledSceneIntent = UUID()
        let targets = displayIDs.map { ids in ids.compactMap { displayRegistry.descriptor(for: $0) } }
            ?? displayRegistry.displays
        return await prepareScene(item: item, targets: targets, persist: writesToLibrary)
    }

    private func invalidateSceneRequest(_ displayID: String) {
        sceneRequestTickets[displayID] = nil
        pendingSceneSessions.removeValue(forKey: displayID)?.tearDown()
    }

    private func prepareScene(item: WallpaperItem, targets: [DisplayDescriptor], persist: Bool) async -> String? {
        guard !Task.isCancelled, !targets.isEmpty, item.fileExists else {
            return "Scene 文件或目标显示器不可用，未改变桌面"
        }
        var staged: [(display: DisplayDescriptor, session: DesktopPlaybackSession, ticket: UUID)] = []
        defer {
            for entry in staged where sceneRequestTickets[entry.display.id] == entry.ticket {
                sceneRequestTickets[entry.display.id] = nil
                pendingSceneSessions[entry.display.id] = nil
                if sessions[entry.display.id] !== entry.session { entry.session.tearDown() }
            }
        }
        do {
            for display in targets {
                invalidateSceneRequest(display.id)
                let ticket = UUID()
                let session = DesktopPlaybackSession(display: display, item: item,
                    settings: effectiveSettings(for: item.id, displayID: display.id),
                    appSettings: store.appSettings, previewOnly: previewOnly,
                    wallpaperFPS: wallpaperFPS, authorStorage: storage)
                sceneRequestTickets[display.id] = ticket
                pendingSceneSessions[display.id] = session
                staged.append((display, session, ticket))
                if let error = session.start(policySuspended: isPolicySuspended) {
                    throw SceneWallpaperFailure(message: error)
                }
            }
            for entry in staged { try await entry.session.waitForSceneReady() }
            try Task.checkCancellation()
            guard staged.allSatisfy({ sceneRequestTickets[$0.display.id] == $0.ticket && displayRegistry.descriptor(for: $0.display.id) != nil }),
                  store.item(withID: item.id)?.filePath == item.filePath else { throw CancellationError() }
            for entry in staged {
                entry.session.apply(settings: effectiveSettings(for: item.id, displayID: entry.display.id), allowPlay: !isPolicySuspended)
                sessions[entry.display.id]?.tearDown()
                sessions[entry.display.id] = entry.session
                suspendedAssignments[entry.display.id] = nil
                entry.session.revealPreparedScene()
                if persist { store.assign(itemID: item.id, to: entry.display.id) }
            }
            if persist { store.markPlayed(id: item.id); store.flush() }
            lastError = nil
            lastMessage = "已应用 Scene 壁纸"
            onUserPlaybackCommand?()
            return nil
        } catch {
            let message = error is CancellationError ? "Scene 准备已取消，原桌面保持不变" : error.localizedDescription
            lastError = message
            return message
        }
    }

    /// 停止并移除桌面播放（`nil` 表示全部）。仅关闭播放窗口，不改动系统桌面图片。
    ///
    /// 全部移除（R14）：同时清理「显示器断开期间的挂起分配」与保存的分配记录，
    /// 因此断开屏重连或下次启动都不会再恢复；并触发一次用户意图回调，
    /// 使聚合意图变为暂停（已启用的轮播计时随策略挂起停止，不会再次应用）。
    /// 隔离预览（`writesToLibrary == false`）只清理内存会话，绝不触碰保存的分配。
    func clear(displayIDs: [String]? = nil) {
        scheduledSceneIntent = UUID()
        for id in displayIDs ?? Array(sceneRequestTickets.keys) { invalidateSceneRequest(id) }
        if let displayIDs {
            for id in displayIDs {
                sessions[id]?.tearDown()
                sessions[id] = nil
                suspendedAssignments.removeValue(forKey: id)
                if writesToLibrary { store.assign(itemID: nil, to: id) }
            }
            lastMessage = sessions.isEmpty ? "已停止桌面播放" : "已停止 \(displayIDs.count) 台显示器的桌面播放"
        } else {
            for (_, session) in sessions {
                session.tearDown()
            }
            sessions.removeAll()
            suspendedAssignments.removeAll()
            if writesToLibrary {
                for id in Array(store.assignments.keys) {
                    store.assign(itemID: nil, to: id)
                }
            }
            lastMessage = "已停止桌面播放"
        }
        if writesToLibrary { store.flush() }
        onUserPlaybackCommand?()
    }

    /// Release players after a library deletion has already committed its document.
    /// Do not issue a second persistence write after that transaction succeeds.
    func discardDeletedWallpaperSessions(itemIDs: Set<UUID>) {
        scheduledSceneIntent = UUID()
        for (id, session) in pendingSceneSessions where itemIDs.contains(session.item.id) { invalidateSceneRequest(id) }
        for (id, session) in sessions where itemIDs.contains(session.item.id) {
            session.tearDown()
            sessions.removeValue(forKey: id)
        }
        suspendedAssignments = suspendedAssignments.filter { !itemIDs.contains($0.value) }
        lastMessage = "已停止已删除壁纸的桌面播放"
        onUserPlaybackCommand?()
    }

    /// 启动时恢复上次的分配（F06 持久化）。
    func restoreAssignmentsIfNeeded() {
        suspendedAssignments.removeAll()
        guard store.appSettings.autoApplyOnLaunch else { return }
        for display in displayRegistry.displays {
            guard let id = store.assignments[display.id], let item = store.item(withID: id) else { continue }
            if item.fileExists {
                var problems: [String] = []
                startSession(item: item, display: display, problems: &problems)
                if !problems.isEmpty {
                    lastError = problems.joined(separator: "；")
                }
            } else {
                lastError = "上次使用的素材文件已丢失：\(item.displayTitle)"
            }
        }
    }

    // MARK: - 屏幕变化（F06）

    /// 与系统枚举解耦的会话协调逻辑（便于在单显示器环境下自检）：
    /// - 断开的显示器：挂起其会话，等待重新连接（不残留孤儿窗口）。
    /// - 仍在线的显示器：按新的分辨率/排列更新窗口尺寸。
    /// - 重新连接的显示器：只恢复此前确实在播放的会话；不会因为屏幕参数变化而启动从未启动的分配。
    func reconcileSessions(onlineDisplayIDs: Set<String>, displays: [DisplayDescriptor]) {
        var messages: [String] = []
        for id in Array(sceneRequestTickets.keys) where !onlineDisplayIDs.contains(id) { invalidateSceneRequest(id) }

        for (id, session) in sessions where !onlineDisplayIDs.contains(id) {
            suspendedAssignments[id] = session.item.id
            let name = session.display.localizedName
            session.tearDown()
            sessions[id] = nil
            messages.append("「\(name)」已断开，播放会话已挂起")
        }

        for display in displays where onlineDisplayIDs.contains(display.id) {
            if let session = sessions[display.id] {
                session.updateFrame(for: display)
            }
        }

        for display in displays where onlineDisplayIDs.contains(display.id) {
            guard sessions[display.id] == nil, let itemID = suspendedAssignments[display.id] else { continue }
            guard let item = store.item(withID: itemID) else {
                suspendedAssignments.removeValue(forKey: display.id)
                continue
            }
            guard item.fileExists else {
                suspendedAssignments.removeValue(forKey: display.id)
                lastError = "「\(item.displayTitle)」文件已丢失，未能恢复播放"
                continue
            }
            var problems: [String] = []
            startSession(item: item, display: display, problems: &problems)
            if sessions[display.id] != nil {
                suspendedAssignments.removeValue(forKey: display.id)
                messages.append("「\(display.localizedName)」已重新连接，播放已恢复")
            } else {
                lastError = problems.joined(separator: "；")
            }
        }

        if !messages.isEmpty {
            lastMessage = messages.joined(separator: "；")
        }
    }

    func handleScreenChange() {
        reconcileSessions(
            onlineDisplayIDs: Set(displayRegistry.displays.map(\.id)),
            displays: displayRegistry.displays
        )
    }

    // MARK: - 播放控制（F07）

    /// 用户在界面上切换播放/暂停。
    ///
    /// 意图来源是**保存的设置**（单一事实来源），而不是当前 player.rate：
    /// 策略挂起期间 player.rate 恒为 0，若按 player.rate 推断，用户点击会得到相反的结果。
    /// 隔离预览模式下只翻转会话自身，不写任何保存状态。
    func playPause(displayID: String) {
        guard let session = sessions[displayID] else { return }
        guard writesToLibrary else {
            session.togglePlayPause()
            return
        }
        let willPause = !store.settings(for: displayID).isPaused
        store.updateSettings(for: displayID) { $0.isPaused = willPause }
        if willPause {
            session.pause()
        } else if !isPolicySuspended {
            session.play()
        }
        store.flush()
        onUserPlaybackCommand?()
    }

    func pauseAll() {
        guard writesToLibrary else {
            for (_, session) in sessions { session.pause() }
            lastMessage = "已暂停所有预览"
            return
        }
        for (id, session) in sessions {
            session.pause()
            store.updateSettings(for: id) { $0.isPaused = true }
        }
        store.flush()
        onUserPlaybackCommand?()
        lastMessage = "已暂停所有桌面播放"
    }

    func resumeAll() {
        guard writesToLibrary else {
            for (_, session) in sessions { session.play() }
            lastMessage = "已恢复所有预览"
            return
        }
        for (id, session) in sessions {
            store.updateSettings(for: id) { $0.isPaused = false }
            if !isPolicySuspended {
                session.play()
            }
        }
        store.flush()
        onUserPlaybackCommand?()
        lastMessage = isPolicySuspended ? "已记录播放意图，策略挂起解除后自动恢复" : "已恢复所有桌面播放"
    }

    /// Wallpaper controls override audio/speed/gravity; display pause intent always survives.
    private func effectiveSettings(for itemID: UUID, displayID: String,
                                   defaults: DisplayPlaybackSettings? = nil) -> DisplayPlaybackSettings {
        let base = defaults ?? store.settings(for: displayID)
        if !writesToLibrary, let previewPreference = previewVideoPreferences[itemID] {
            return previewPreference?.applying(to: base) ?? base
        }
        return store.videoPlaybackPreferences(for: itemID)?.applying(to: base) ?? base
    }

    /// Updates only sessions displaying this wallpaper. Nil returns to the display defaults.
    func updateVideoPlaybackPreferences(_ preferences: VideoPlaybackPreferences?, itemID: UUID) {
        guard store.item(withID: itemID) != nil else { return }
        if writesToLibrary {
            store.updateVideoPlaybackPreferences(preferences, itemID: itemID)
            store.flush()
        } else {
            previewVideoPreferences.updateValue(preferences?.normalized, forKey: itemID)
        }
        for (displayID, session) in sessions where session.item.id == itemID {
            var settings = effectiveSettings(for: itemID, displayID: displayID)
            if !writesToLibrary { settings.isPaused = !session.isPlaying }
            session.apply(settings: settings, allowPlay: !isPolicySuspended)
        }
    }

    /// 修改某显示器的播放设置：真实模式写入素材库；隔离预览只作用于会话本身。
    private func mutateSettings(for displayID: String, _ body: (inout DisplayPlaybackSettings) -> Void) {
        if writesToLibrary {
            store.updateSettings(for: displayID) { body(&$0) }
            if let session = sessions[displayID] {
                session.apply(settings: effectiveSettings(for: session.item.id, displayID: displayID), allowPlay: !isPolicySuspended)
            }
        } else {
            guard let session = sessions[displayID] else { return }
            var updated = session.settings
            body(&updated)
            session.apply(settings: effectiveSettings(for: session.item.id, displayID: displayID, defaults: updated), allowPlay: !isPolicySuspended)
        }
    }

    func setMuted(_ muted: Bool, displayID: String) {
        mutateSettings(for: displayID) { $0.isMuted = muted }
        mutateCurrentWallpaperPreference(displayID: displayID) { $0.isMuted = muted }
    }

    func setVolume(_ volume: Double, displayID: String) {
        mutateSettings(for: displayID) { $0.volume = min(max(volume, 0), 1) }
        mutateCurrentWallpaperPreference(displayID: displayID) { $0.volume = volume }
    }

    func setRate(_ rate: Double, displayID: String) {
        mutateSettings(for: displayID) { $0.rate = min(max(rate, 0.25), 4) }
        mutateCurrentWallpaperPreference(displayID: displayID) { $0.rate = rate }
    }

    func setGravity(_ gravity: VideoGravityMode, displayID: String) {
        mutateSettings(for: displayID) { $0.gravity = gravity }
        mutateCurrentWallpaperPreference(displayID: displayID) { $0.gravity = gravity }
    }

    /// Explicit current-playback commands must stay effective with a wallpaper override.
    /// Wallpapers shared by multiple displays intentionally share these four preferences.
    private func mutateCurrentWallpaperPreference(displayID: String, _ body: (inout VideoPlaybackPreferences) -> Void) {
        guard let session = sessions[displayID] else { return }
        let preferences: VideoPlaybackPreferences?
        if !writesToLibrary, let previewPreference = previewVideoPreferences[session.item.id] {
            preferences = previewPreference
        } else {
            preferences = store.videoPlaybackPreferences(for: session.item.id)
        }
        guard var updated = preferences else { return }
        body(&updated)
        updateVideoPlaybackPreferences(updated, itemID: session.item.id)
    }

    /// 用一份完整设置替换某显示器的设置（界面绑定直接调用）。
    func updateSettings(_ settings: DisplayPlaybackSettings, displayID: String) {
        mutateSettings(for: displayID) { $0 = settings }
    }

    func resetSettings(displayID: String) {
        if writesToLibrary {
            store.resetSettings(for: displayID)
            if let session = sessions[displayID] {
                session.apply(settings: effectiveSettings(for: session.item.id, displayID: displayID), allowPlay: !isPolicySuspended)
            }
        } else {
            if let session = sessions[displayID] {
                session.apply(settings: effectiveSettings(for: session.item.id, displayID: displayID, defaults: .default), allowPlay: !isPolicySuspended)
            }
        }
    }

    func applySettingsToAll(from displayID: String) {
        let settings: DisplayPlaybackSettings
        if writesToLibrary {
            settings = store.settings(for: displayID)
        } else {
            settings = sessions[displayID]?.settings ?? .default
        }
        for (id, session) in sessions where id != displayID {
            if writesToLibrary {
                store.updateSettings(for: id) { current in
                    current.isMuted = settings.isMuted
                    current.volume = settings.volume
                    current.rate = settings.rate
                    current.gravity = settings.gravity
                    current.isPaused = settings.isPaused
                }
                session.apply(settings: effectiveSettings(for: session.item.id, displayID: id), allowPlay: !isPolicySuspended)
            } else {
                var updated = session.settings
                updated.isMuted = settings.isMuted
                updated.volume = settings.volume
                updated.rate = settings.rate
                updated.gravity = settings.gravity
                updated.isPaused = settings.isPaused
                session.apply(settings: effectiveSettings(for: session.item.id, displayID: id, defaults: updated), allowPlay: !isPolicySuspended)
            }
        }
        if writesToLibrary { store.flush() }
        lastMessage = "已将播放设置应用到其他显示器"
    }

    /// 把素材库中保存的播放设置应用到当前所有会话（导入配置后刷新真实播放器）。
    /// 不改变任何用户暂停意图；策略挂起期间保持暂停。
    func applyStoredSettingsToSessions() {
        for (id, session) in sessions {
            session.apply(settings: effectiveSettings(for: session.item.id, displayID: id), allowPlay: !isPolicySuspended)
        }
    }

    // MARK: - 策略挂起层（F09 集成）

    /// 策略转换入口：按策略状态暂停/恢复真实会话。
    ///
    /// 约定（integration-contract）：
    /// - 只暂停/恢复会话，绝不写 `DisplayPlaybackSettings.isPaused`（该字段始终是用户意图）；
    /// - `displayShouldPlay` 的逐屏判断由调用方给出（用户的每屏暂停永远优先）；
    /// - 策略解除后按每屏保存的意图恢复，不会唤醒手动暂停的显示器。
    func applyPolicyState(isBlocked: Bool, displayShouldPlay: (String) -> Bool) {
        isPolicySuspended = isBlocked
        for (id, session) in sessions {
            if isBlocked || !displayShouldPlay(id) {
                session.pause()
            } else {
                session.play()
            }
        }
    }

    // MARK: - 退出清理

    /// 退出应用：拆除全部会话（无孤儿渲染会话），不做任何系统桌面图片写入。
    func tearDownAll() {
        guard !isTearingDown else { return }
        isTearingDown = true
        scheduledSceneIntent = UUID()
        for id in Array(sceneRequestTickets.keys) { invalidateSceneRequest(id) }
        for (_, session) in sessions {
            session.tearDown()
        }
        sessions.removeAll()
        isTearingDown = false
    }

    /// 自检：返回当前会话的诊断行。
    func diagnosticsLines() -> [String] {
        var lines: [String] = []
        lines.append("活动会话数: \(sessions.count)")
        if !suspendedAssignments.isEmpty {
            lines.append("挂起会话: \(suspendedDisplayIDs.map { String($0.prefix(8)) }.joined(separator: ", "))")
        }
        for (id, session) in sessions.sorted(by: { $0.key < $1.key }) {
            lines.append("— 会话 \(id.prefix(8)) —")
            lines.append(contentsOf: session.diagnostics())
        }
        if let lastMessage { lines.append("最近操作: \(lastMessage)") }
        if let lastError { lines.append("最近错误: \(lastError)") }
        return lines
    }

    func updateAuthorProperties(_ payload: Data, itemID: UUID) throws {
        for session in sessions.values where session.item.id == itemID {
            try session.updateAuthorProperties(payload)
        }
    }

    /// 预览窗口使用：列出会话承载视图（真实 AVPlayerLayer）。
    func previewHostView(for displayID: String) -> NSView? {
        sessions[displayID]?.sceneRuntime?.hostView ?? sessions[displayID]?.webHostView ?? sessions[displayID]?.hostView
    }
}
