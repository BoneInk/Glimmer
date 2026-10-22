import SwiftUI

/// The creator destination uses the same cards and explicit download actions as
/// Workshop discovery. It remains mounted behind opened wallpaper details.
struct WorkshopAuthorGalleryView: View {
    @Bindable var session: WorkshopAuthorGallerySession
    @Bindable var coordinator: WorkshopCoordinator
    let onBack: () -> Void
    @Environment(\.workspaceWallpaperDetails) private var presentation
    private var author: WorkshopAuthor { session.author }
    private var model: WorkshopInformationModel { session.model }
    private var page: Int { session.page }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass).help("返回之前的壁纸")
                    .accessibilityLabel("返回之前的壁纸").accessibilityIdentifier("creator-gallery-back")
                WorkshopAuthorAvatar(author: author, transitionRole: .gallery)
                VStack(alignment: .leading, spacing: 4) {
                    Text(author.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(model.works.map { "Wallpaper Engine · \($0.totalCount.formatted()) 件公开作品" } ?? "Wallpaper Engine 公开作品")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("最新发布").font(.callout).foregroundStyle(.secondary)
                Link(destination: author.profileURL) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.glass).help("在 Steam 查看作者主页")
            }
            ScrollView {
                if model.isLoading { ProgressView("正在获取作者作品…").frame(maxWidth: .infinity, minHeight: 240) }
                if let error = model.error {
                    ContentUnavailableView {
                        Label("暂时无法获取作者作品", systemImage: "exclamationmark.circle")
                    } description: { Text(error) } actions: {
                        Button("重试") { session.load(page: page, refresh: true) }.buttonStyle(.glass)
                    }.frame(minHeight: 240)
                }
                if let works = model.works {
                    if works.results.isEmpty {
                        ContentUnavailableView("暂无公开作品", systemImage: "rectangle.stack", description: Text("此作者目前没有可访问的 Wallpaper Engine 作品。"))
                            .frame(minHeight: 240)
                    } else {
                        LazyVGrid(columns: WallpaperCardLayout.columns, spacing: WallpaperCardLayout.spacing) {
                            ForEach(works.results) { result in
                                WorkshopResultCard(result: result, isSaved: coordinator.isSaved(result.id),
                                    downloadItem: coordinator.downloadProgress.items.first { $0.id == result.id },
                                    onSelect: { open(result) }, onSave: { coordinator.toggleSaved(result) },
                                    onDownload: { coordinator.performDownloadAction(result) },
                                    onOpenSource: { coordinator.openSourcePage(for: result) },
                                    detailSourceKey: "workshop:\(result.id):creator:\(author.id)")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            HStack {
                Button("上一页") { session.load(page: page - 1) }.disabled(page <= 1 || model.isLoading)
                Spacer()
                Text("第 \(page) 页" + (model.works.map { " / \($0.totalPages)" } ?? ""))
                    .font(.callout.monospacedDigit()).accessibilityIdentifier("creator-gallery-page")
                Spacer()
                Button("下一页") { session.load(page: page + 1) }.disabled(model.isLoading || model.works.map { page >= $0.totalPages } != false)
            }.buttonStyle(.glass)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("creator-workshop-gallery")
    }

    private func open(_ result: WorkshopSearchResult) {
        presentation?.prepareSource("workshop:\(result.id):creator:\(author.id)")
        if coordinator.hasLocalWallpaper(itemID: result.id) {
            Task { await coordinator.openWallpaperDetails(itemID: result.id) }
        } else {
            coordinator.cancelOpeningWallpaperDetails()
            presentation?.open(result)
        }
    }
}
