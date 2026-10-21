import SwiftUI

/// 素材卡片：缩略图 + 标题 + 关键信息 + 收藏。
///
/// 交互约定（R10）：**单击封面打开详情，键盘选择只选中，不会应用到桌面**；
/// 应用桌面必须通过卡片上的「应用」按钮（或右键菜单）显式触发。
///
/// - 缩略图通过 `ThumbnailCache` 异步生成；视图消失时任务被取消（F10 可取消要求）。
/// - 卡片支持拖出（把媒体文件拖到桌面/访达，复制而非移动）。
struct WallpaperCardView: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isMissing: Bool
    let style: GlassStyle
    let onToggleFavorite: () -> Void
    /// 仅选中（键盘导航）。
    let onSelect: () -> Void
    /// 显式应用（卡片按钮、右键菜单）。
    let onApply: () -> Void
    let onOpenDetails: () -> Void
    var onDelete: (() -> Void)? = nil

    @GlassState private var thumbnail: NSImage?
    @GlassState private var isLoadingThumbnail = false
    @GlassState private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: onOpenDetails) {
                thumbnailArea
                    .wallpaperCoverSource(WorkspaceWallpaperDetails.key(for: item), image: thumbnail)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.32),
                            .init(color: .black.opacity(0.12), location: 0.52),
                            .init(color: .black.opacity(style.reduceTransparency ? 1 : 0.82), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开\(item.displayTitle)的详情与设置")
            .accessibilityIdentifier("library-card-details")

            VStack(alignment: .leading, spacing: 12) {
                Button(action: onOpenDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.displayTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .lineSpacing(2).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.isWebWallpaper ? "本地网页 · \(item.fileSizeText)" : "\(item.resolutionText) · \(item.fileSizeText)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                    }
                    .multilineTextAlignment(.leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                    .accessibilityLabel("打开\(item.displayTitle)的详情与设置")
                HStack(spacing: 8) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(item.isFavorite ? Color.yellow : Color.white)
                            .modifier(LibraryCardControlSurface(style: style))
                    }
                    .help(item.isFavorite ? "取消收藏" : "加入收藏")
                    .accessibilityLabel(item.isFavorite ? "取消收藏\(item.displayTitle)" : "收藏\(item.displayTitle)")
                    .accessibilityIdentifier("library-card-favorite")
                    Spacer(minLength: 0)
                    Button(action: onApply) {
                        Label("设为壁纸", systemImage: "display").modifier(LibraryCardControlSurface(style: style))
                    }
                    .disabled(isMissing).opacity(isMissing ? 0.45 : 1)
                    .help(isMissing ? "文件丢失，无法应用" : "将这张壁纸应用到全部显示器；指定单屏请打开详情")
                    .accessibilityLabel("将\(item.displayTitle)应用到全部显示器")
                    .accessibilityIdentifier("library-card-apply-all")
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain).controlSize(.small)
                .environment(\.colorScheme, .dark)
            }
            .foregroundStyle(.white).padding(16)
        }
        .aspectRatio(WallpaperCardLayout.aspectRatio, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                if isMissing {
                    Label("文件丢失", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(style.reduceTransparency ? 1 : 0.65), in: Capsule())
                } else {
                    Spacer(minLength: 4)
                    Text(item.isSceneWallpaper ? SceneWallpaperPresentation.badge(for: AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).first) : item.isWebWallpaper ? "Web" : item.durationText).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(style.reduceTransparency ? 1 : 0.65), in: Capsule())
                }
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.white)
            .padding(12).allowsHitTesting(false)
        }
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(isHovering ? 0.5 : 0.18),
                              lineWidth: isSelected ? 2.5 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(isHovering ? 0.16 : 0.08), radius: isHovering ? 14 : 8, y: 5)
        .animation(style.cardAnimation, value: isSelected)
        .animation(style.cardAnimation, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("详情与设置", action: onOpenDetails)
            Divider()
            Button("应用到全部显示器", action: onApply).disabled(isMissing)
            Button(item.isFavorite ? "取消收藏" : "加入收藏", action: onToggleFavorite)
            Divider()
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                .disabled(!item.fileExists)
            if let original = item.originalURL {
                Button("显示原始文件") { NSWorkspace.shared.activateFileViewerSelecting([original]) }
                    .disabled(!item.originalExists)
            }
            if let onDelete {
                Divider()
                Button("删除壁纸…", role: .destructive, action: onDelete)
            }
        }
        .help("\(item.displayTitle) · 单击打开详情与设置")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: "\(item.id):\(item.filePath):\(isMissing)") {
            thumbnail = nil
            await loadThumbnail()
        }
        .draggable(item.isProjectWallpaper ? item.fileURL.deletingLastPathComponent() : item.fileURL) {
            Label(item.displayTitle, systemImage: item.isSceneWallpaper ? "square.3.layers.3d" : item.isWebWallpaper ? "globe" : "film").padding(6)
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.displayTitle]
        if isMissing { parts.append("文件丢失") }
        parts.append(item.isSceneWallpaper ? SceneWallpaperPresentation.badge(for: AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).first) : item.isWebWallpaper ? "Web" : item.durationText)
        parts.append(item.resolutionText)
        if item.isFavorite { parts.append("已收藏") }
        return parts.joined(separator: "，")
    }

    private var thumbnailArea: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.85)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if isLoadingThumbnail {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: isMissing ? "exclamationmark.triangle" : item.isSceneWallpaper ? "square.3.layers.3d" : item.isWebWallpaper ? "globe" : "film")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.45))
                        .offset(y: -30)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func loadThumbnail() async {
        guard !isMissing else { return }
        if let cached = await ThumbnailCache.shared.cachedThumbnail(for: item) {
            guard !Task.isCancelled else { return }
            thumbnail = cached
            return
        }
        guard !Task.isCancelled else { return }
        isLoadingThumbnail = true
        defer { isLoadingThumbnail = false }
        let image = await ThumbnailCache.shared.thumbnail(for: item)
        guard !Task.isCancelled else { return }
        thumbnail = image
    }
}

/// Dark local control appearance keeps labels legible over every cover while
/// retaining the shared native glass / opaque accessibility fallback.
private struct LibraryCardControlSurface: ViewModifier {
    let style: GlassStyle
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(minWidth: 34, minHeight: 34)
            .background(style.controlBackground(capsule: false))
            .environment(\.colorScheme, .dark)
    }
}
