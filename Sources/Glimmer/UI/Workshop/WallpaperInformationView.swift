import AppKit
import SwiftUI

enum WorkshopInformationRoute: Hashable {
    case author(WorkshopAuthor)
    case work(WorkshopSearchResult)
}

private struct WorkshopCreatorNavigationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (WorkshopAuthor) -> Void)? = nil
}
extension EnvironmentValues {
    var workshopCreatorNavigation: (@MainActor (WorkshopAuthor) -> Void)? {
        get { self[WorkshopCreatorNavigationKey.self] }
        set { self[WorkshopCreatorNavigationKey.self] = newValue }
    }
}

/// Shared by installed wallpaper details and Workshop previews. Only this
/// explicit action starts metadata requests; opening a preview stays immediate.
struct WallpaperInformationButton: View {
    var itemID: String? = nil
    var localItem: WallpaperItem? = nil
    var initialDetail: WorkshopItemDetail? = nil
    @GlassState private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "info.circle").font(.system(size: 15)).frame(width: 18, height: 18)
        }
            .buttonStyle(.glass).controlSize(.regular)
            .help("查看壁纸介绍、作者及作者的其他作品")
            .accessibilityLabel("壁纸信息")
            .accessibilityIdentifier("wallpaper-information-open")
            .modifier(WallpaperInformationPresentation(itemID: itemID, localItem: localItem, initialDetail: initialDetail, presented: $presented))
    }
}

private struct WallpaperInformationPresentation: ViewModifier {
    let itemID: String?
    let localItem: WallpaperItem?
    var initialDetail: WorkshopItemDetail?
    var initialAuthor: WorkshopAuthor? = nil
    @Binding var presented: Bool
    @GlassState private var pendingWork: WorkshopSearchResult?
    @GlassState private var pendingAuthor: WorkshopAuthor?
    @Environment(\.workspaceWallpaperDetails) private var presentation
    @Environment(\.workshopCreatorNavigation) private var openCreator

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented, onDismiss: {
            if let author = pendingAuthor { pendingAuthor = nil; openCreator?(author) }
            else if let work = pendingWork { pendingWork = nil; presentation?.open(work) }
        }) { sheet }
    }
    private var workAction: ((WorkshopSearchResult) -> Void)? {
        guard presentation != nil else { return nil }
        return { work in pendingWork = work; presented = false }
    }
    private var creatorAction: (@MainActor (WorkshopAuthor) -> Void)? {
        guard openCreator != nil else { return nil }
        return { author in pendingAuthor = author; presented = false }
    }
    private var sheet: some View {
        WallpaperInformationSheet(itemID: itemID, localItem: localItem, initialDetail: initialDetail, initialAuthor: initialAuthor,
            onOpenWork: workAction)
            .environment(\.workshopCreatorNavigation, creatorAction)
    }
}

struct WallpaperCreatorBadge: View {
    let item: WallpaperItem
    let detail: WorkshopItemDetail?
    var fallbackName = "本地壁纸"
    @GlassState private var presented = false
    @Environment(\.workshopCreatorNavigation) private var openCreator

    var body: some View {
        let author = detail?.authors.first
        Button {
            if let author, let openCreator { openCreator(author) }
            else { presented = true }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let author { WorkshopAuthorAvatar(author: author, transitionRole: .detail) }
                else { Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(.secondary) }
                Text(author?.name ?? fallbackName).font(.caption.weight(.medium)).lineLimit(2)
                    .multilineTextAlignment(.leading).foregroundStyle(.primary)
            }
            .frame(width: 84, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(author == nil ? "查看壁纸信息" : "查看作者的作品列表")
        .accessibilityLabel(author.map { "查看作者\($0.name)的作品列表" } ?? "查看壁纸作者信息")
        .accessibilityIdentifier("wallpaper-creator-open")
        .modifier(WallpaperInformationPresentation(itemID: item.workshopID, localItem: item, initialDetail: detail, initialAuthor: author, presented: $presented))
    }
}

struct WallpaperInformationSheet: View {
    let itemID: String?
    var localItem: WallpaperItem? = nil
    var initialDetail: WorkshopItemDetail? = nil
    var initialAuthor: WorkshopAuthor? = nil
    var onOpenWork: ((WorkshopSearchResult) -> Void)? = nil
    @GlassState private var path: [WorkshopInformationRoute] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            WorkshopWallpaperInformationPage(itemID: itemID, localItem: localItem, model: WorkshopInformationModel(initialDetail: initialDetail))
                .navigationTitle("壁纸信息")
                .navigationDestination(for: WorkshopInformationRoute.self) { route in
                    switch route {
                    case .author(let author): WorkshopAuthorWorksView(author: author).id(author.id)
                    case .work(let result):
                        WorkshopWallpaperInformationPage(itemID: result.id, seed: result, onOpenWork: onOpenWork)
                            .id(result.id)
                            .navigationTitle("壁纸信息")
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: .infinity, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .background { PopupSurfaceBackground() }
        .accessibilityIdentifier("wallpaper-information-sheet")
        .onAppear { if path.isEmpty, let initialAuthor { path = [.author(initialAuthor)] } }
    }
}

struct WorkshopWallpaperInformationPage: View {
    let itemID: String?
    var localItem: WallpaperItem? = nil
    var seed: WorkshopSearchResult? = nil
    var onOpenWork: ((WorkshopSearchResult) -> Void)? = nil
    @GlassState var model = WorkshopInformationModel()
    @GlassState private var localDescription = ""
    @GlassState private var localAuthor = ""
    @GlassState private var refresh = UUID()
    @Environment(\.workshopCreatorNavigation) private var openCreator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(model.detail?.title ?? localItem?.displayTitle ?? seed?.title ?? "壁纸信息")
                    .font(.title2.weight(.semibold)).textSelection(.enabled)
                if let item = localItem { localMetadata(item) }
                if model.isLoading { ProgressView("正在获取壁纸详情与作者…").controlSize(.small) }
                if let error = model.error {
                    informationError(error) { refresh = UUID() }
                }
                if let detail = model.detail {
                    authorSection(detail.authors)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("壁纸介绍").font(.headline)
                        Text(detail.description.isEmpty ? "作者没有提供介绍。" : detail.description)
                            .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        infoRow("类型", detail.kind.title)
                        if let value = detail.fileSizeText { infoRow("文件大小", value) }
                        if let value = detail.createdText { infoRow("发布", value) }
                        if let value = detail.updatedText { infoRow("更新", value) }
                        if let value = detail.subscriptions { infoRow("订阅", value.formatted()) }
                        if let value = detail.favorited { infoRow("收藏", value.formatted()) }
                        if let value = detail.views { infoRow("浏览", value.formatted()) }
                    }.font(.callout)
                    if !detail.tags.isEmpty {
                        Text(detail.tags.map { "\($0.key)：\($0.value)" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if !localDescription.isEmpty || !localAuthor.isEmpty {
                    if !localAuthor.isEmpty { LabeledContent("作者", value: localAuthor).textSelection(.enabled) }
                    if !localDescription.isEmpty { Text(localDescription).textSelection(.enabled) }
                } else if WorkshopItemID(itemID ?? "") == nil {
                    Text("这是一张本地壁纸，没有关联的创意工坊作者和作品列表。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let id = WorkshopItemID(itemID ?? "") {
                        Link(destination: id.detailsURL) { Label("在 Steam 查看", systemImage: "arrow.up.right.square") }
                            .buttonStyle(.glass)
                    }
                    Spacer()
                    if seed != nil, let onOpenWork, let detail = model.detail {
                        Button("打开这张壁纸") {
                            var work = detail.searchResult
                            if work.previewURL == nil { work.previewURL = seed?.previewURL }
                            onOpenWork(work)
                        }.buttonStyle(.glassProminent)
                            .accessibilityIdentifier("author-work-open-detail")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .task(id: "\(itemID ?? localItem?.id.uuidString ?? "local"):\(refresh)") {
            if let item = localItem, item.isProjectWallpaper {
                let values = await Task.detached(priority: .utility) {
                    let project = try? AuthorPropertyProject.load(projectURL: item.fileURL, allowedRoot: item.fileURL.deletingLastPathComponent())
                    return (project?.rawJSON.objectValue?["description"]?.stringValue ?? "",
                            project?.rawJSON.objectValue?["author"]?.stringValue ?? "")
                }.value
                guard !Task.isCancelled else { return }
                localDescription = values.0; localAuthor = values.1
            }
            if let id = WorkshopItemID(itemID ?? "") { await model.loadDetail(id) }
        }
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("wallpaper-information-content")
    }

    private func localMetadata(_ item: WallpaperItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            infoRow("来源", item.workshopID == nil ? "本地导入" : "Steam 创意工坊")
            infoRow("本地文件", item.fileSizeText)
            if item.pixelWidth != nil { infoRow("分辨率", item.resolutionText) }
            if let fps = item.frameRate { infoRow("帧率", "\(fps.formatted(.number.precision(.fractionLength(0...2)))) FPS") }
        }.font(.callout)
    }

    @ViewBuilder private func authorSection(_ authors: [WorkshopAuthor]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(authors.count > 1 ? "共同作者" : "作者").font(.headline)
            if authors.isEmpty { Text("Steam 暂未提供可识别的作者信息。").foregroundStyle(.secondary) }
            ForEach(authors) { author in
                Group {
                    if let openCreator { Button { openCreator(author) } label: { authorRow(author) } }
                    else { NavigationLink(value: WorkshopInformationRoute.author(author)) { authorRow(author) } }
                }
                .buttonStyle(.plain).accessibilityLabel("查看作者\(author.name)的作品列表")
                .accessibilityIdentifier("wallpaper-author-\(author.id)")
            }
        }
    }

    private func authorRow(_ author: WorkshopAuthor) -> some View {
                    HStack(spacing: 12) {
                        WorkshopAuthorAvatar(author: author)
                        Text(author.name).font(.body.weight(.medium)).lineLimit(2)
                        Spacer()
                        Text("查看作品").font(.callout).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }.padding(12).workshopGlassSurface(cornerRadius: 16)
    }
}

struct WorkshopAuthorWorksView: View {
    let author: WorkshopAuthor
    @GlassState var model = WorkshopInformationModel()
    @GlassState private var page = 1
    @GlassState private var refresh = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                WorkshopAuthorAvatar(author: author)
                VStack(alignment: .leading, spacing: 4) {
                    Text(author.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(model.works.map { "Wallpaper Engine · \($0.totalCount.formatted()) 件公开作品" } ?? "Wallpaper Engine 公开作品")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: author.profileURL) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.glass).help("在 Steam 查看作者主页")
            }.padding(24)
            Divider()
            ScrollView {
                if model.isLoading { ProgressView("正在获取作者作品…").padding(32) }
                if let error = model.error { informationError(error) { refresh = UUID() }.padding(24) }
                if let works = model.works {
                    if works.results.isEmpty {
                        ContentUnavailableView("暂无公开作品", systemImage: "rectangle.stack", description: Text("此作者目前没有可访问的 Wallpaper Engine 作品。"))
                            .padding(30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 20) {
                            ForEach(works.results) { work in
                                NavigationLink(value: WorkshopInformationRoute.work(work)) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        WorkshopCoverImage(result: work).aspectRatio(16.0 / 10, contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(work.title).font(.callout.weight(.medium)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain).accessibilityLabel("查看壁纸\(work.title)")
                                .accessibilityIdentifier("author-work-\(work.id)")
                            }
                        }.padding(24)
                    }
                }
            }
            Divider()
            HStack {
                Button("上一页") { page -= 1 }.disabled(page <= 1 || model.isLoading)
                Spacer()
                Text("第 \(page) 页" + (model.works.map { " / \($0.totalPages)" } ?? ""))
                    .font(.callout.monospacedDigit()).accessibilityIdentifier("author-works-page")
                Spacer()
                Button("下一页") { page += 1 }.disabled(model.isLoading || model.works.map { page >= $0.totalPages } != false)
            }.buttonStyle(.glass).padding(16)
        }
        .navigationTitle("作者作品")
        .task(id: "\(author.id):\(page):\(refresh)") { await model.loadWorks(author, page: page) }
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("workshop-author-works")
    }
}

struct WorkshopAuthorAvatar: View {
    let author: WorkshopAuthor
    var transitionRole: WorkshopCreatorAvatarRole? = nil
    @GlassState private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
        .modifier(WorkshopCreatorAvatarAnchor(authorID: author.id, role: transitionRole, image: image))
        .accessibilityHidden(true)
        .task(id: author.avatarURL) {
            guard let url = author.avatarURL else { return }
            let data = await WorkshopPreviewCache.shared.data(for: url)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

private func infoRow(_ label: String, _ value: String) -> some View {
    GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
}

private func informationError(_ message: String, retry: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Label("暂时无法获取信息", systemImage: "exclamationmark.circle").font(.callout.weight(.medium))
        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        Button("重试", action: retry).buttonStyle(.glass)
    }.frame(maxWidth: .infinity, alignment: .leading)
}
