import AppKit
import SwiftUI

enum WorkshopMetric {
    static func compact(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        if value >= 1_000 { return String(format: "%.1f千", Double(value) / 1_000) }
        return String(value)
    }
}

struct WorkshopChoiceChip: View {
    let title: String
    let selected: Bool
    var tint: Color = .blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark" : "circle.fill")
                    .font(.system(size: selected ? 10 : 5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                Text(title).lineLimit(1)
            }
                .font(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .workshopNavigationSurface(cornerRadius: 18,
                    tint: tint.opacity(selected ? 0.25 : 0.11), interactive: true)
                .overlay {
                    Capsule().strokeBorder(tint.opacity(selected ? 0.8 : 0.2), lineWidth: selected ? 1.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkshopFilterLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(width: 82, alignment: .leading)
    }
}

enum WorkshopChipPalette {
    static func type(_ type: WorkshopSearchType) -> Color {
        switch type { case .video: .blue; case .web: .teal; case .scene: .purple; case .all: .gray }
    }
    static func genre(_ genre: WorkshopGenre) -> Color {
        switch genre.rawValue {
        case "Anime", "Cartoon", "MMD", "Girls": .pink
        case "Nature", "Landscape", "Animal": .green
        case "Abstract", "Fantasy", "Medieval": .purple
        case "Cyberpunk", "Sci-Fi", "Technology", "Game": .cyan
        case "Music", "Television", "Boys": .indigo
        case "Retro", "Pixel art", "Meme", "Sports", "Vehicle": .orange
        default: .teal
        }
    }
    static func rating(_ rating: WorkshopAgeRating) -> Color {
        switch rating.rawValue { case "Everyone": .green; case "Questionable": .orange; default: .pink }
    }
}

struct WorkshopHorizontalFilterGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            WorkshopFilterLabel(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content }
                    .padding(.vertical, 1)
            }
        }
    }
}

struct WorkshopHistoryChip: View {
    let query: String
    let onReuse: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onReuse) {
                Label(query, systemImage: "clock")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("再次搜索“\(query)”")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("移除“\(query)”搜索记录")
            .accessibilityLabel("移除搜索记录，\(query)")
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .workshopNavigationSurface(cornerRadius: 18, tint: .indigo.opacity(0.10), interactive: true)
    }
}

struct WorkshopCoverImage: View {
    let result: WorkshopSearchResult
    var fit = false
    var detailSourceKey: String? = nil
    var detailDestination = false
    var detailCornerRadius: CGFloat = 24
    @GlassState private var imageData: Data?
    @GlassState private var image: NSImage?
    @GlassState private var loading = false
    @GlassState private var imageLoadFailed = false
    @GlassState private var retryGeneration = UUID()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .wallpaperCoverSource(detailSourceKey, data: imageData, remoteURL: result.previewURL)
        .wallpaperCoverDestination(enabled: detailDestination, ready: imageData != nil,
            mode: fit ? .fit : .fill, cornerRadius: detailCornerRadius)
        .overlay(alignment: .top) {
            if detailDestination, imageLoadFailed {
                HStack {
                    Text("预览图暂未就绪，可重新加载").font(.caption)
                    Spacer()
                    Button("重新加载") { retryGeneration = UUID() }.buttonStyle(.glass).controlSize(.small)
                }
                .foregroundStyle(.white).padding(12)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 560)
                .padding(.horizontal, 12).padding(.top, detailCornerRadius == 0 ? 80 : 12)
            }
        }
        .task(id: "\(result.previewURL?.absoluteString ?? ""):\(retryGeneration)") {
            imageData = nil; image = nil; imageLoadFailed = false
            loading = true
            defer { loading = false }
            var previewURL = result.previewURL
            let parts = previewURL?.path.split(separator: "/") ?? []
            if detailDestination, previewURL == nil || (parts.first == "ugc" && parts.count < 3),
               let id = WorkshopItemID(result.id) {
                // Repair legacy saved entries which lost the image key. This
                // runs only after opening details, never for every grid tile.
                let service = WorkshopService(http: .init(timeout: 12, maximumRetries: 0))
                if let detail = try? await service.detail(itemID: id) { previewURL = detail.previewImageURL }
            }
            guard !Task.isCancelled else { return }
            guard let url = previewURL else { imageLoadFailed = true; return }
            let data = await WorkshopPreviewCache.shared.data(for: url)
            guard !Task.isCancelled else { return }
            imageData = data
            image = data.flatMap(NSImage.init(data:))
            imageLoadFailed = image == nil
        }
        .task(id: retryGeneration) {
            guard detailDestination else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, imageData == nil else { return }
            imageLoadFailed = true
        }
        .accessibilityLabel("\(result.title)的预览图")
    }
}

/// Image-overlay controls always use white glyphs, including opaque accessibility mode.
struct WorkshopCoverControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.windowGlassReduceTransparencyOverride) private var reviewReduceTransparency
    var cornerRadius: CGFloat = 17
    var tint: Color = .black.opacity(0.18)

    @ViewBuilder func body(content: Content) -> some View {
        if systemReduceTransparency || reviewReduceTransparency {
            content
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.24), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .environment(\.colorScheme, .dark)
        } else {
            content
                .workshopGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: true)
                .environment(\.colorScheme, .dark)
        }
    }
}

struct WorkshopResultCard: View {
    let result: WorkshopSearchResult
    let isSaved: Bool
    let downloadItem: WorkshopDownloadItem?
    let onSelect: () -> Void
    let onSave: () -> Void
    let onDownload: () -> Void
    let onOpenSource: () -> Void
    var detailSourceKey: String? = nil
    @GlassState private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var downloadPresentation: WorkshopDownloadProgressPresentation {
        WorkshopDownloadProgressPresentation(item: downloadItem)
    }

    private var displayKind: WorkshopItemKind { downloadItem?.validatedProject?.kind ?? result.declaredKind }
    private var downloadSupported: Bool { downloadItem?.validatedProject != nil ? displayKind.isSupportedWallpaper : result.isSupportedWallpaper }
    private var downloadDisabled: Bool { downloadPresentation.downloadDisabled || !downloadSupported }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: onSelect) {
                WorkshopCoverImage(result: result, detailSourceKey: detailSourceKey ?? "workshop:\(result.id)")
                    .overlay {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.25),
                                    .init(color: .black.opacity(0.22), location: 0.48),
                                    .init(color: .black.opacity(reduceTransparency ? 0.94 : 0.86), location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
            }
            .buttonStyle(.plain)
            .help("查看作品详情与静态预览图")
            .accessibilityLabel("查看\(result.title)详情与预览图")

            VStack(alignment: .leading, spacing: 10) {
                Button(action: onSelect) {
                    Text(result.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineSpacing(3)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .bottomLeading)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看作品详情")
                HStack(spacing: 8) {
                    Text(displayKind.title)
                        .foregroundStyle(downloadSupported ? Color.white.opacity(0.8) : Color.orange)
                    if let count = result.subscriptions {
                        Label(WorkshopMetric.compact(count), systemImage: "person.2")
                            .help("\(count) 次订阅")
                    }
                    if let size = result.fileSizeText { Text(size) }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

                HStack(spacing: 7) {
                    if let status = downloadPresentation.statusText {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(downloadItem?.state.isSuccess == true ? Color.mint : .white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(action: onSave) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSaved ? Color.yellow : Color.white)
                            .frame(width: 34, height: 34)
                            .modifier(WorkshopCoverControlSurface())
                    }
                    .buttonStyle(.plain)
                    .help(isSaved ? "从稍后查看移除（本机）" : "稍后查看（仅本机）")
                    .accessibilityLabel(isSaved ? "从稍后查看移除\(result.title)" : "保存\(result.title)到本机稍后查看")
                    Button(action: onDownload) {
                        Image(systemName: downloadPresentation.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .modifier(WorkshopCoverControlSurface(tint: .white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadDisabled)
                    .overlay {
                        WorkshopDownloadProgressRing(presentation: downloadPresentation)
                            .frame(width: 38, height: 38)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .help(!downloadSupported ? displayKind.unsupportedReason ?? "暂不支持此类型" : (downloadPresentation.downloadDisabled ? (downloadPresentation.statusText ?? "加入下载队列") : downloadPresentation.actionTitle))
                    .accessibilityLabel("\(downloadPresentation.actionTitle)：\(result.title)")
                    .accessibilityValue(downloadSupported ? downloadPresentation.accessibilityValue : displayKind.unsupportedReason ?? "暂不支持此类型")
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .aspectRatio(WallpaperCardLayout.aspectRatio, contentMode: .fit)
        .background(.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.6 : 0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isHovered ? 0.20 : 0.10), radius: isHovered ? 18 : 10, y: 7)
        .offset(y: isHovered && !reduceMotion ? -3 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("查看详情", action: onSelect)
            Button(isSaved ? "从稍后查看移除" : "稍后查看（本机）", action: onSave)
            Button("加入下载队列", action: onDownload).disabled(downloadDisabled)
            Divider()
            Button("在 Steam 查看", action: onOpenSource)
        }
    }
}
