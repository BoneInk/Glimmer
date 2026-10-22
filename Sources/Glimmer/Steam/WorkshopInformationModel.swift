import Foundation
import Observation

/// Per-presentation state. Network results from a previous item/page cannot
/// replace the current selection, even when a transport ignores cancellation.
@MainActor @Observable
final class WorkshopInformationModel {
    typealias DetailLoader = @Sendable (WorkshopItemID) async throws -> WorkshopItemDetail
    typealias WorksLoader = @Sendable (WorkshopAuthor, Int) async throws -> WorkshopAuthorWorksPage
    private(set) var detail: WorkshopItemDetail?
    private(set) var works: WorkshopAuthorWorksPage?
    private(set) var error: String?
    private(set) var isLoading = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let detailLoader: DetailLoader
    @ObservationIgnored private let worksLoader: WorksLoader

    init(initialDetail: WorkshopItemDetail? = nil,
         detailLoader: @escaping DetailLoader = { try await WorkshopService.shared.detail(itemID: $0) },
         worksLoader: @escaping WorksLoader = { try await WorkshopService.shared.authorWorks(author: $0, page: $1) }) {
        detail = initialDetail
        self.detailLoader = detailLoader; self.worksLoader = worksLoader
    }

    func loadDetail(_ id: WorkshopItemID, refresh: Bool = false) async {
        if !refresh, detail?.id == id.value, error == nil { return }
        let ticket = UUID(); generation = ticket
        detail = nil; error = nil; isLoading = true
        do {
            let value = try await detailLoader(id)
            guard generation == ticket, !Task.isCancelled else { return }
            guard value.id == id.value else { throw SteamHTTPError.structureChanged("返回的壁纸 ID 与请求不一致。") }
            detail = value; isLoading = false
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }

    func loadWorks(_ author: WorkshopAuthor, page: Int, refresh: Bool = false) async {
        if !refresh, works?.author.id == author.id, works?.page == page, error == nil { return }
        let ticket = UUID(); generation = ticket
        works = nil; error = nil; isLoading = true
        do {
            let value = try await worksLoader(author, page)
            guard generation == ticket, !Task.isCancelled else { return }
            guard value.author.id == author.id, value.page == page else { throw SteamHTTPError.structureChanged("返回的作者或页码与请求不一致。") }
            works = value; isLoading = false
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }

    func cancel() { generation = UUID(); isLoading = false }
}

/// Owns the request independently of the destination view's mounting/animation.
/// The avatar click starts it; opening a wallpaper keeps this session and page.
@MainActor @Observable
final class WorkshopAuthorGallerySession {
    let author: WorkshopAuthor
    let model: WorkshopInformationModel
    private(set) var page = 1
    @ObservationIgnored private var request: Task<Void, Never>?

    init(author: WorkshopAuthor, model: WorkshopInformationModel = WorkshopInformationModel()) {
        self.author = author
        self.model = model
    }

    @discardableResult
    func load(page: Int = 1, refresh: Bool = false) -> Task<Void, Never> {
        request?.cancel()
        self.page = max(1, page)
        let requestedPage = self.page
        let task = Task { [author, model] in
            guard !Task.isCancelled else { return }
            await model.loadWorks(author, page: requestedPage, refresh: refresh)
        }
        request = task
        return task
    }

    func cancel() {
        request?.cancel(); request = nil
        model.cancel()
    }
}
