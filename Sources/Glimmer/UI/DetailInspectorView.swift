import SwiftUI
import AppKit

/// 详情检查器：预览、元数据、显示器分配与每屏播放控制（F07）。
struct DetailInspectorView: View {
    let store: VideoLibraryStore
    let item: WallpaperItem
    let displays: [DisplayDescriptor]
    let playback: DesktopPlaybackController
    let style: GlassStyle
    let onApplyAll: (WallpaperItem) async -> String?
    let onClearAll: () -> Void
    let onToggleFavorite: () -> Void
    let onRemove: () -> Void
    let onRelink: (WallpaperItem) -> Void
    var canDelete: Bool = true
    /// 电源策略正在挂起播放时的原因说明（只读）。
    var policyReasonText: String? = nil
    var onOpenDynamicLockScreen: ((WallpaperItem) -> Void)? = nil
    var sharedApplyState: DetailWallpaperApplyState? = nil
    var immersive = false
    var topContentInset: CGFloat = 0
    var wallpaperFPS = 30

    @GlassState private var selectedDisplayID: String?
    @GlassState private var isPreviewMuted = true
    @GlassState private var previewPaused = false
    @GlassState private var previewReady = false
    @GlassState private var snapshotUnavailable = false
    @GlassState private var previewError: String?
    @GlassState private var previewToast: TransientToast?
    @GlassState private var previewGeneration = UUID()
    @Environment(\.workspaceWallpaperDetails) private var detailPresentation
    @GlassState private var isRenaming = false
    @GlassState private var renameDraft = ""
    @GlassState private var renameItemID: UUID?
    @FocusState private var renameFocused: Bool
    @GlassState private var scenePreviewRelay = ScenePreviewControlsRelay()
    @GlassState private var localApplyState = DetailWallpaperApplyState()
    @GlassState private var information = WorkshopInformationModel()
    @GlassState private var projectDescription = ""
    @GlassState private var projectAuthor = ""
    private var applyState: DetailWallpaperApplyState { sharedApplyState ?? localApplyState }

    private var missing: Bool { !item.fileExists }
    private var targetDisplayID: String? {
        (selectedDisplayID == "__all_displays__" ? nil : selectedDisplayID)
            ?? displays.first(where: { $0.isPrimary })?.id ?? displays.first?.id
    }

    private var settings: DisplayPlaybackSettings {
        guard let targetDisplayID else { return .default }
        return store.effectiveSettings(for: item.id, displayID: targetDisplayID)
    }

    var body: some View {
        // Keep the split-view proposal authoritative even when AVPlayerView or a
        // long menu label advertises a larger intrinsic width at compact sizes.
        GeometryReader { geometry in
            if immersive {
                immersiveCanvas(size: geometry.size)
            } else {
            let panelWidth = max(0, geometry.size.width - 26)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !immersive { header }
                    if missing {
                        missingBanner
                    }
                    previewSection(width: max(0, panelWidth - (immersive ? 72 : 56)))
                    if immersive { header }
                    if !missing { displaySection }
                    if !missing, item.isProjectWallpaper {
                        AuthorWallpaperSettingsSection(store: store, item: item, playback: playback)
                    }
                    if !missing, item.isVideoWallpaper { playbackSettings }
                }
                .frame(width: max(0, panelWidth - (immersive ? 48 : 32)), alignment: .leading)
                .padding(immersive ? 24 : 16)
                .padding(.top, topContentInset)
            }
            .frame(width: panelWidth, height: max(0, geometry.size.height - (immersive ? 0 : 32)))
            .scrollContentBackground(.hidden)
            .padding(.vertical, immersive ? 0 : 16)
            .padding(.leading, immersive ? 0 : 10)
            .padding(.trailing, immersive ? 0 : 16)
            }
        }
        .onChange(of: item.id, initial: true) { _, _ in
            applyState.cancel()
            scenePreviewRelay.activate(itemID: item.id)
            previewPaused = false
            cancelRename()
        }
        .task(id: "\(item.id):\(item.workshopID ?? "")") {
            projectDescription = ""; projectAuthor = ""
            if item.isProjectWallpaper {
                let selected = item
                let summary = await Task.detached(priority: .utility) {
                    let project = try? AuthorPropertyProject.load(projectURL: selected.fileURL, allowedRoot: selected.fileURL.deletingLastPathComponent())
                    return (project?.rawJSON.objectValue?["description"]?.stringValue ?? "",
                            project?.rawJSON.objectValue?["author"]?.stringValue ?? "")
                }.value
                guard !Task.isCancelled else { return }
                projectDescription = summary.0; projectAuthor = summary.1
            }
            if let id = WorkshopItemID(item.workshopID ?? "") { await information.loadDetail(id) }
        }
        .onDisappear { applyState.cancel(); information.cancel(); cancelRename() }
        .onChange(of: previewError) { _, error in
            if let error { previewToast = TransientToast(SceneWallpaperPresentation.errorSummary(error), tone: .error) }
        }
        .transientToast($previewToast)
    }

    private func immersiveCanvas(size: CGSize) -> some View {
        let compact = size.width < 920
        let availableWidth = min(1160, max(0, size.width - 48))
        let columnWidth = compact ? availableWidth : max(0, (availableWidth - 16) / 2)
        let maxHeight = min(320, size.height * (compact ? 0.29 : 0.44))
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
        return ZStack(alignment: .bottom) {
            previewSurface
                .frame(width: size.width, height: size.height)
                .accessibilityIdentifier("wallpaper-details-full-window-media")
            layout {
                WallpaperDetailFloatingPanel(maxHeight: maxHeight) {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        HStack(alignment: .top, spacing: 14) {
                            WallpaperCreatorBadge(item: item, detail: information.detail,
                                fallbackName: !projectAuthor.isEmpty ? projectAuthor
                                    : item.workshopID == nil ? "本地壁纸" : information.isLoading ? "正在加载作者…" : "作者信息暂不可用")
                            VStack(alignment: .leading, spacing: 10) {
                                if missing { missingBanner }
                                else { displaySection }
                                Text(wallpaperDescription)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("wallpaper-description-summary")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: columnWidth)
                .accessibilityIdentifier("wallpaper-details-floating-actions")
                if !missing, item.isProjectWallpaper {
                    AuthorWallpaperSettingsSection(store: store, item: item, playback: playback,
                        floatingPanelMaxHeight: maxHeight)
                        .frame(width: columnWidth)
                } else if !missing, item.isVideoWallpaper {
                    WallpaperDetailFloatingPanel(maxHeight: maxHeight) {
                        playbackSettings
                    }
                    .frame(width: columnWidth)
                    .accessibilityIdentifier("wallpaper-details-floating-settings")
                }

            }
            .equalWallpaperPanelHeights()
            .frame(maxWidth: 1160)
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
    }

    private var wallpaperDescription: String {
        let description = information.detail?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty { return description }
        if !projectDescription.isEmpty { return projectDescription }
        return information.isLoading ? "正在加载作品简介…" : "暂无作品简介"
    }

    private var previewControls: some View {
        HStack(spacing: 10) {
            WallpaperPreviewControls(paused: $previewPaused,
                muted: (item.isVideoWallpaper || item.isSceneWallpaper) ? $isPreviewMuted : nil,
                canTogglePause: !missing && (!item.isSceneWallpaper || scenePreviewRelay.controls.canTogglePause))
            if previewError != nil {
                Button(action: reloadPreview) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).help("重新加载预览")
                    .accessibilityLabel("重新加载预览")
                    .accessibilityIdentifier("wallpaper-preview-reload")
            }
            Spacer(minLength: 0)
        }
    }
    private func reloadPreview() {
        previewReady = false; snapshotUnavailable = false; previewError = nil; previewGeneration = UUID()
        if item.isSceneWallpaper, let model = detailPresentation?.route?.scenePreviewModel {
            Task { @MainActor in
                await model.retry(item: item, paused: previewPaused, storage: store.storage,
                                  wallpaperFPS: wallpaperFPS)
            }
        }
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("播放")
                Spacer()
                if !inheritsDisplaySettings {
                    Button { playback.updateVideoPlaybackPreferences(nil, itemID: item.id) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.glass).controlSize(.small)
                    .help("重置播放设置").accessibilityLabel("重置播放设置")
                }
            }
            playbackSection
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isRenaming {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("名称", text: $renameDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .focused($renameFocused)
                                .onSubmit { saveRename() }
                                .accessibilityLabel("壁纸名称")
                                .accessibilityIdentifier("wallpaper-rename-draft")
                                .task {
                                    guard isRenaming, renameItemID == item.id, !Task.isCancelled else { return }
                                    renameFocused = true
                                }
                            HStack(spacing: 8) {
                                Button("取消") { cancelRename() }
                                    .accessibilityIdentifier("wallpaper-rename-cancel")
                                Button("保存") { saveRename() }
                                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityIdentifier("wallpaper-rename-save")
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                        .onExitCommand { cancelRename() }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(item.displayTitle)
                                .font(.title3.weight(.semibold))
                                .lineLimit(immersive ? 2 : nil)
                                .textSelection(.enabled)

                        }
                    }
                    Text(item.isSceneWallpaper ? "Scene · \(item.resolutionText) · \(item.fileSizeText)" : item.isWebWallpaper ? "Web · \(item.fileSizeText)" : "\(item.resolutionText) · \(item.durationText) · \(item.fileSizeText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(immersive ? 1 : nil)
                }
                Spacer()
                Button(action: onToggleFavorite) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(item.isFavorite ? "取消收藏" : "加入收藏")
                .accessibilityLabel(item.isFavorite ? "取消收藏" : "加入收藏")
                Menu {
                    Button("重命名") {
                        renameDraft = item.title; renameItemID = item.id; isRenaming = true
                    }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        .disabled(!item.fileExists)
                    if missing, item.isVideoWallpaper { Button("重新定位文件…") { onRelink(item) } }
                    if canDelete {
                        Divider()
                        Button("删除壁纸…", role: .destructive, action: onRemove)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("更多操作").accessibilityLabel("更多操作")
            }
        }
    }

    private func cancelRename() {
        isRenaming = false
        renameFocused = false
        renameDraft = ""
        renameItemID = nil
    }

    private func saveRename() {
        guard renameItemID == item.id,
              !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.rename(id: item.id, to: renameDraft)
        cancelRename()
    }

    private var missingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("文件不可访问", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 8) {
                if item.isProjectWallpaper {
                    Text(item.isSceneWallpaper ? "请通过「导入 → Scene 壁纸项目」重新选择完整项目。" : "请通过「导入 → Web 壁纸项目」重新选择完整项目。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Button("重新定位文件…") { onRelink(item) } }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.groupedBackground(cornerRadius: 16))
    }

    // MARK: - 预览

    private func previewSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            previewSurface.frame(height: 230)
            previewControls
        }
        .padding(12)
        .background(style.groupedBackground(cornerRadius: 16))
    }

    private var previewSurface: some View {
        let expectedRouteID = detailPresentation?.route?.id
        let expectedGeneration = previewGeneration
        let scenePreviewModel = detailPresentation?.route?.scenePreviewModel
        let ready: () -> Void = {
            guard detailPresentation?.route?.id == expectedRouteID, previewGeneration == expectedGeneration else { return }
            guard !snapshotUnavailable else { return }
            previewReady = true; previewError = nil
        }
        let unavailable: (String) -> Void = { message in
            guard detailPresentation?.route?.id == expectedRouteID, previewGeneration == expectedGeneration else { return }
            previewReady = false; previewError = message
            if let expectedRouteID { detailPresentation?.acceptSnapshot(nil, routeID: expectedRouteID) }
        }
        let heldForHandoff = immersive && detailPresentation?.coverImage != nil && detailPresentation?.livePreviewOpacity == 0
        return GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                    if missing {
                        VStack(spacing: 6) {
                            Image(systemName: "film").font(.system(size: 26)).foregroundStyle(.secondary)
                            Text("文件丢失，无法预览").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if item.isSceneWallpaper {
                        SceneWallpaperPreviewView(item: item, isPaused: previewPaused || heldForHandoff,
                            storage: store.storage, wallpaperFPS: wallpaperFPS,
                            soundEnabled: !isPreviewMuted,
                            soundVolume: settings.volume.isFinite ? settings.volume : 1,
                            previewModel: scenePreviewModel,
                            onControlsStateChange: { itemID, state in
                                scenePreviewRelay.accept(itemID: itemID, state: state)
                            }, onReady: ready, onFailure: unavailable)
                    } else {
                        PlayerPreviewView(
                            item: item,
                            isPaused: previewPaused || heldForHandoff,
                            isMuted: isPreviewMuted,
                            volume: settings.volume.isFinite ? settings.volume : 1,
                            rate: settings.clampedRate.isFinite ? Double(settings.clampedRate) : 1,
                            gravity: immersive ? .fill : settings.gravity,
                            wallpaperFPS: wallpaperFPS,
                            storage: store.storage, onReady: ready, onFailure: unavailable,
                            onTransitionSnapshot: immersive && item.isWebWallpaper ? { image in
                                guard let expectedRouteID, previewGeneration == expectedGeneration else { return }
                                if let image { detailPresentation?.acceptSnapshot(image, routeID: expectedRouteID) }
                                else {
                                    snapshotUnavailable = true
                                    unavailable("预览画面尚未就绪，可重新加载；其他设置仍可使用。")
                                }
                            } : nil
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .id(previewGeneration)
            // A failed preview must reveal its error/retry surface instead of
            // retaining a magnified thumbnail over it indefinitely.
            .wallpaperCoverDestination(ready: missing || previewReady || previewError != nil,
                mode: !immersive && item.isVideoWallpaper && settings.gravity == .fit ? .fit : .fill,
                cornerRadius: immersive ? 0 : 12, requiresSnapshot: immersive && item.isWebWallpaper && !missing)
            // This sits above the transition cover. A spinner inside the Scene
            // host is otherwise hidden by the magnified thumbnail while loading.
            .overlay(alignment: .top) {
                if item.isSceneWallpaper, !missing, !previewReady, previewError == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载场景…").font(.callout)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 24)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("scene-preview-loading")
                }
            }
            .task(id: previewGeneration) {
                guard immersive, !missing else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !previewReady,
                      detailPresentation?.route?.id == expectedRouteID, previewGeneration == expectedGeneration else { return }
                if let expectedRouteID { detailPresentation?.acceptSnapshot(nil, routeID: expectedRouteID) }
                previewError = "预览尚未就绪，可重新加载；其他设置仍可使用。"
            }
            .clipShape(RoundedRectangle(cornerRadius: immersive ? 0 : 12, style: .continuous))
    }

    // MARK: - 显示器分配

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    if displays.count > 1 { displayPicker }
                    applyButtons.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if displays.count > 1 { displayPicker }
                    applyButtons
                }
            }
            .controlSize(.regular)
            if let feedback = applyState.error ?? (item.isSceneWallpaper ? nil : playback.lastError) {
                Label(SceneWallpaperPresentation.errorSummary(feedback), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let policyReasonText, !policyReasonText.isEmpty {
                Label("已因\(policyReasonText)暂停", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayPicker: some View {
        Picker("显示器", selection: Binding(
            get: { selectedDisplayID ?? targetDisplayID ?? "" },
            set: { selectedDisplayID = $0 }
        )) {
            ForEach(displays) { display in Text(display.localizedName).tag(display.id) }
            Text("全部显示器").tag("__all_displays__")
        }
        .labelsHidden().pickerStyle(.menu)
        .frame(minWidth: 120, maxWidth: 190)
        .disabled(applyState.isPreparing)
    }

    private var applyButtons: some View {
        HStack(alignment: .top, spacing: 10) {
                Button {
                    let selected = item
                    if selectedDisplayID == "__all_displays__" {
                        applyState.begin(itemID: selected.id, target: .allDisplays) { await onApplyAll(selected) }
                    } else if let displayID = targetDisplayID {
                        applyState.begin(itemID: selected.id, target: .display(displayID)) {
                            await playback.applyAndWait(item: selected, to: [displayID])
                        }
                    }
                } label: {
                    WallpaperActionLabel(title: "设为壁纸", symbol: "display", busy: applyState.isPreparing)
                }
                .buttonStyle(.glassProminent)
                .disabled(applyState.isPreparing || displays.isEmpty)
                .accessibilityIdentifier("wallpaper-apply")
                if item.isVideoWallpaper || item.isWebWallpaper || item.isSceneWallpaper {
                    LockScreenApplyControls(item: item, onFeedback: { previewToast = $0 })
                }
                WallpaperInformationButton(itemID: item.workshopID, localItem: item, initialDetail: information.detail)
        }
    }

    private var inheritsDisplaySettings: Bool {
        store.videoPlaybackPreferences(for: item.id) == nil
    }

    private var videoPreferences: VideoPlaybackPreferences {
        store.videoPlaybackPreferences(for: item.id) ?? VideoPlaybackPreferences(settings: settings)
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("静音", isOn: binding(for: \.isMuted)).toggleStyle(.switch)
            HStack(spacing: 12) {
                Text("音量").frame(width: 48, alignment: .leading)
                Slider(value: binding(for: \.volume), in: 0...1)
                    .accessibilityLabel("壁纸音量")
                Text(String(format: "%.0f%%", settings.volume * 100))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .disabled(settings.isMuted)
            HStack(spacing: 12) {
                Text("速度").frame(width: 48, alignment: .leading)
                Slider(value: binding(for: \.rate), in: 0.25...4, step: 0.05)
                    .accessibilityLabel("播放速度")
                Text(String(format: "%.2f×", settings.rate))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text("画面").frame(width: 48, alignment: .leading)
                Picker("画面", selection: binding(for: \.gravity)) {
                    ForEach(VideoGravityMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
        }
        .font(.callout)
        .padding(immersive ? 0 : 16)
        .background { if !immersive { style.groupedBackground(cornerRadius: 16) } }
    }

    private func binding<Value>(for keyPath: WritableKeyPath<VideoPlaybackPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { videoPreferences[keyPath: keyPath] },
            set: { newValue in
                var updated = videoPreferences
                updated[keyPath: keyPath] = newValue
                playback.updateVideoPlaybackPreferences(updated, itemID: item.id)
            }
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
