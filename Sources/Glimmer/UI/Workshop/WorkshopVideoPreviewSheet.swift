import AppKit
import AVKit
import SwiftUI

/// 只预览已完成校验的本地视频；设为壁纸必须另行明确点击。
struct WorkshopVideoPreviewSheet: View {
    let preview: WorkshopLocalVideoPreview
    let coordinator: WorkshopCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @GlassState private var player: AVPlayer?
    @GlassState private var metadata = "正在读取本地视频…"
    @GlassState private var error: String?
    @GlassState private var loops = false
    @GlassState private var muted = true
    @GlassState private var paused = false
    @GlassState private var position = 0.0
    @GlassState private var duration = 0.0
    @GlassState private var scrubbing = false
    @GlassState private var reload = UUID()
    @GlassState private var suspended = false
    @GlassState private var loadGeneration = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title).font(.headline).lineLimit(2)
                    Text(metadata).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { invalidateLoad(); releasePlayer(); dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass).controlSize(.small)
                    .help("关闭预览").accessibilityLabel("关闭预览")
            }
            WorkshopApplyWallpaperControls(coordinator: coordinator, itemID: preview.id)
                .padding(.vertical, 4)
            Group {
                if let error {
                    ContentUnavailableView {
                        Label(suspended ? "预览已暂停" : "无法预览", systemImage: "film")
                    } description: {
                        if !suspended { Text(error) }
                    } actions: {
                        Button(suspended ? "继续" : "重试") { suspended = false; reload = UUID() }
                    }
                } else if let player {
                    WorkshopVideoSurface(player: player)
                        .accessibilityLabel("本地视频播放器，支持播放、暂停和拖动进度")
                } else {
                    ProgressView("正在打开本地视频")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 320)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                WallpaperPreviewControls(paused: $paused, muted: $muted, loops: $loops)
                Slider(value: Binding(
                    get: { position },
                    set: { value in
                        position = value
                        player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                    }), in: 0...max(duration, 0.01), onEditingChanged: { scrubbing = $0 })
                .disabled(duration <= 0 || player == nil)
                .accessibilityLabel("预览进度")
                Text(WallpaperItem.formatDuration(position)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
            }

        }
        .padding(20)
        .frame(minWidth: 650, idealWidth: 800, minHeight: 450, idealHeight: 560)
        .background { PopupSurfaceBackground() }
        .task(id: reload) { await loadPlayer() }
        .onChange(of: muted) { _, value in player?.isMuted = value }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard !scrubbing, let player else { return }
            let seconds = player.currentTime().seconds
            if seconds.isFinite { position = min(max(0, seconds), max(duration, 0)) }
        }
        .onChange(of: paused) { _, value in
            if value { player?.pause() } else { player?.play() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            if loops {
                player?.seek(to: .zero)
                if !paused { player?.play() }
            } else { paused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            releasePlayer()
            error = "视频播放中断。请检查本地文件是否仍可读取。"
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in suspendPlayer() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in suspendPlayer() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { suspendPlayer() } }
        .onDisappear { invalidateLoad(); releasePlayer() }
    }

    @MainActor private func loadPlayer() async {
        guard !suspended else { return }
        let generation = UUID()
        loadGeneration = generation
        releasePlayer()
        error = nil
        metadata = "正在读取本地视频…"
        guard preview.fileURL.isFileURL, FileManager.default.isReadableFile(atPath: preview.fileURL.path) else {
            error = "本地视频已移动、删除或不可读取。请返回下载管理检查该作品。"
            metadata = "文件不可用"
            return
        }
        do {
            let asset = AVURLAsset(url: preview.fileURL)
            guard try await asset.load(.isPlayable) else {
                error = "系统无法播放这个本地视频。"; return
            }
            let mediaDuration = try await asset.load(.duration)
            var pieces: [String] = []
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let displaySize = size.applying(transform)
                pieces.append("\(Int(abs(displaySize.width)))×\(Int(abs(displaySize.height)))")
            }
            if mediaDuration.seconds.isFinite { pieces.append(WallpaperItem.formatDuration(mediaDuration.seconds)) }
            if let size = try? preview.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                pieces.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            try Task.checkCancellation()
            guard !suspended, loadGeneration == generation else { return }
            metadata = pieces.joined(separator: " · ")
            duration = mediaDuration.seconds.isFinite ? max(0, mediaDuration.seconds) : 0
            position = 0
            let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            next.isMuted = muted
            next.actionAtItemEnd = .pause
            player = next
            if !paused { next.play() }
        } catch is CancellationError {
            if loadGeneration == generation { releasePlayer() }
        } catch {
            guard !suspended, loadGeneration == generation else { return }
            metadata = "文件不可用"
            self.error = "无法读取视频内容。请检查文件，或返回下载管理重新下载。"
        }
    }

    @MainActor private func suspendPlayer() {
        invalidateLoad()
        releasePlayer()
        error = "预览已暂停"
    }

    @MainActor private func invalidateLoad() {
        suspended = true
        loadGeneration = UUID()
    }

    @MainActor private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

/// Native video surface with one shared set of preview controls.
private struct WorkshopVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
