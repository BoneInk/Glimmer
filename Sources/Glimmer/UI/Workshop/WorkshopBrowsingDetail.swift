import SwiftUI

struct WorkshopSearchResultDetail: View {
    let result: WorkshopSearchResult
    @Bindable var coordinator: WorkshopCoordinator
    let style: GlassStyle
    var onClose: (() -> Void)? = nil
    var immersive = false
    @Environment(\.workspaceContentTopInset) private var contentTopInset
    @Environment(\.wallpaperDetailChromeTopInset) private var chromeTopInset
    @Environment(\.dismiss) private var dismiss
    @GlassState private var showCover = false
    @GlassState private var videoPreview: WorkshopLocalVideoPreview?
    @GlassState private var showMetadata = false

    private var queueState: WorkshopDownloadState? {
        coordinator.downloadProgress.items.first { $0.publishedFileID == result.id }?.state
    }

    private var downloadDisabled: Bool {
        downloadPresentation.downloadDisabled || (!result.isSupportedWallpaper && !coordinator.hasLocalWallpaper(itemID: result.id))
    }
    private var downloadPresentation: WorkshopDownloadProgressPresentation {
        .init(item: coordinator.downloadProgress.items.first { $0.id == result.id })
    }

    var body: some View {
        Group {
            if immersive { immersiveCanvas }
            else { legacyDetail }
        }
        .frame(minWidth: 560, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { if let onClose { onClose() } else { dismiss() } }
        .background { if !immersive { PopupSurfaceBackground() } }
        .sheet(isPresented: $showCover) { WorkshopCoverLightbox(result: result) }
        .sheet(item: $videoPreview) { preview in WorkshopVideoPreviewSheet(preview: preview, coordinator: coordinator) }
    }

    private var immersiveCanvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                WorkshopCoverImage(result: result, fit: false, detailDestination: true, detailCornerRadius: 0)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityIdentifier("wallpaper-details-full-window-media")
                WallpaperDetailFloatingPanel(maxHeight: min(280, geometry.size.height * 0.4)) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(result.title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        if coordinator.hasLocalWallpaper(itemID: result.id) {
                            WorkshopApplyWallpaperControls(coordinator: coordinator, itemID: result.id)
                        }
                        actionBar
                        if let queueState {
                            Text(queueState.displayText).font(.caption).foregroundStyle(.secondary)
                        }
                        if !result.shortDescription.isEmpty {
                            Text(result.shortDescription).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                        HStack(spacing: 12) {
                            Text(result.declaredKind.title)
                            if let size = result.fileSizeText { Text(size) }
                            Spacer()
                            Button { coordinator.openSourcePage(for: result) } label: {
                                Label("在 Steam 查看", systemImage: "arrow.up.right.square")
                            }.buttonStyle(.glass).controlSize(.small)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 24).padding(.bottom, 24)
                .accessibilityIdentifier("wallpaper-details-floating-actions")
                WallpaperDetailBackButton {
                    if let onClose { onClose() } else { dismiss() }
                }
                .padding(.leading, 24).padding(.top, max(20, chromeTopInset + 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.black)
        }
    }

    private var legacyDetail: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        if coordinator.hasLocalWallpaper(itemID: result.id) { Task { await coordinator.openWallpaperDetails(itemID: result.id) } }
                        else { showCover = true }
                    } label: {
                        WorkshopCoverImage(result: result, fit: true, detailDestination: true)
                            .aspectRatio(16.0 / 9, contentMode: .fit)
                            .overlay {
                                LinearGradient(colors: [.clear, .clear, .black.opacity(0.88)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(result.title)
                                        .font(.system(size: 23, weight: .semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 8) {
                                        Spacer()
                                        Label(coordinator.hasLocalWallpaper(itemID: result.id) ? "详情与设置" : "放大", systemImage: coordinator.hasLocalWallpaper(itemID: result.id) ? "slider.horizontal.3" : "arrow.up.left.and.arrow.down.right")
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .modifier(WorkshopCoverControlSurface(cornerRadius: 16, tint: .black.opacity(0.15)))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                }
                                .foregroundStyle(.white)
                                .padding(22)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(coordinator.hasLocalWallpaper(itemID: result.id) ? "打开\(result.title)详情与设置" : "\(result.title)，放大作品静态预览图")
                    if coordinator.hasLocalWallpaper(itemID: result.id) {
                        WorkshopApplyWallpaperControls(coordinator: coordinator, itemID: result.id)
                    }
                    actionBar
                    if let queueState, !queueState.isSuccess || !coordinator.hasLocalWallpaper(itemID: result.id) {
                        Label(queueState.isSuccess ? "本地文件不可用" : queueState.displayText,
                              systemImage: queueState.isSuccess ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.callout).foregroundStyle(queueState.isSuccess && coordinator.hasLocalWallpaper(itemID: result.id) ? Color.green : Color.secondary)
                    }
                    if !result.shortDescription.isEmpty {
                        Text(result.shortDescription).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("作品信息", isExpanded: $showMetadata) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            row("文件大小", result.fileSizeText ?? "暂无信息")
                            row("订阅", result.subscriptions.map(WorkshopMetric.compact) ?? "暂无信息")
                            row("收藏", result.favorited.map(WorkshopMetric.compact) ?? "暂无信息")
                            row("浏览", result.views.map(WorkshopMetric.compact) ?? "暂无信息")
                            row("发布", result.createdText ?? "暂无信息")
                        }
                        .font(.callout)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !result.tags.isEmpty {
                            Text(result.tags.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }
                    .padding(14)
                    .workshopGlassSurface(cornerRadius: 18)
                    HStack {
                        Button { coordinator.openSourcePage(for: result) } label: {
                            Label("在 Steam 查看", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                }
                .padding(22)
                .padding(.top, immersive ? contentTopInset + 58 : 48)
            }
            detailToolbar
                .zIndex(2)
        }
    }

    private var detailToolbar: some View {
        HStack {
            if immersive {
                Button { onClose?() } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("wallpaper-details-back")
            }
            Spacer()
            if !immersive {
                Button { if let onClose { onClose() } else { dismiss() } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭作品详情")
            }
        }
        .padding(12)
        .workshopNavigationSurface(cornerRadius: 24)
        .padding(.horizontal, 20)
        .padding(.top, immersive ? contentTopInset : 16)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let local = coordinator.localPreview(for: result.id) {
                Button { videoPreview = local } label: { Label("预览视频", systemImage: "play.circle.fill") }
                    .buttonStyle(.glassProminent)
            } else if !coordinator.hasLocalWallpaper(itemID: result.id) {
                Button { coordinator.performDownloadAction(result) } label: {
                    Label(queueState?.isSuccess == true ? "本地文件不可用" : (downloadDisabled ? downloadPresentation.statusText ?? "已加入下载队列" : downloadPresentation.actionTitle), systemImage: downloadPresentation.symbolName)
                }
                .buttonStyle(.glassProminent).disabled(downloadDisabled)
            }
            if !result.isSupportedWallpaper && !coordinator.hasLocalWallpaper(itemID: result.id) {
                Text(result.declaredKind.unsupportedReason ?? "暂不支持此类型")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { coordinator.toggleSaved(result) } label: {
                Label(coordinator.isSaved(result.id) ? "已存到稍后查看" : "稍后查看",
                      systemImage: coordinator.isSaved(result.id) ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.glass)
            .help("仅保存在本机，不会同步到 Steam 收藏")
            Spacer(minLength: 0)
        }
        .padding(immersive ? 0 : 12)
        .background { if !immersive { RoundedRectangle(cornerRadius: 23).fill(.clear).workshopGlassSurface(cornerRadius: 23) } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

struct WorkshopCoverLightbox: View {
    let result: WorkshopSearchResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("预览图", systemImage: "photo").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            WorkshopCoverImage(result: result, fit: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(result.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 940, minHeight: 460, idealHeight: 640)
        .background { PopupSurfaceBackground() }
    }
}
