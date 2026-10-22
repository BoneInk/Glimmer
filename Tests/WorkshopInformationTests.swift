import Foundation
import AppKit

actor InformationGate {
    var pending: [String: CheckedContinuation<WorkshopItemDetail, Never>] = [:]
    var pages: [Int: CheckedContinuation<WorkshopAuthorWorksPage, Never>] = [:]
    func load(_ id: WorkshopItemID) async -> WorkshopItemDetail {
        await withCheckedContinuation { pending[id.value] = $0 }
    }
    func has(_ id: String) -> Bool { pending[id] != nil }
    func finish(_ value: WorkshopItemDetail) { pending.removeValue(forKey: value.id)?.resume(returning: value) }
    func loadPage(_ page: Int) async -> WorkshopAuthorWorksPage { await withCheckedContinuation { pages[page] = $0 } }
    func hasPage(_ page: Int) -> Bool { pages[page] != nil }
    func finishPage(_ value: WorkshopAuthorWorksPage) { pages.removeValue(forKey: value.page)?.resume(returning: value) }
}

@main @MainActor
enum WorkshopInformationTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks += 1; print("PASS \(message)"); fflush(stdout)
    }
    static func fails(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { try check(true, message); return }
        throw Failure(message: message)
    }
    static let profile = URL(string: "https://steamcommunity.com/id/test_author")!
    static let author = WorkshopAuthor(profileURL: profile, name: "测试作者", accountID: 42)!
    static func detail(_ id: String) -> WorkshopItemDetail {
        .init(publishedFileID: id, title: "Wallpaper \(id)", description: "Intro", kind: .scene, tags: [], diagnostics: [], authors: [author])
    }
    static func pageHTML(page: Int = 1, total: Int = 65) -> String {
        let first = (page - 1) * 30 + 1, last = min(page * 30, total)
        let cards = (first...last).map { index in
            """
            <div class="workshopItem"><a class="ugc" data-appid="431960" data-publishedfileid="\(1000 + index)" href="https://steamcommunity.com/sharedfiles/filedetails/?id=\(1000 + index)">
            <div class="workshopItemPreviewHolder"><img class="workshopItemPreviewImage" src="https://images.steamusercontent.com/ugc/\(index)/image.jpg"></div></a>
            <a><div class="workshopItemTitle ellipsis">作品 \(index) &amp; 测试</div></a></div>
            """
        }.joined()
        return "<div class='workshopBrowsePagingInfo'>Showing \(first)-\(last) of \(total) entries</div><div class='workshopBrowseItems'>\(cards)</div>"
    }
    static func run() async throws {
        let html = """
        <div class="workshopItemTitle">Synthetic Wallpaper</div><a href="https://store.steampowered.com/app/431960/">App</a>
        <div class="workshopItemDescriptionTitle">Description</div><div class="workshopItemDescription">First line<br>Before <a href="https://example.com/">link</a><div>Nested paragraph</div>After &amp; end</div><div>Outside text</div>
        <div class="creatorsBlock"><div class="friendBlock persona" data-miniprofile="42"><a class="friendBlockLinkOverlay" href="https://steamcommunity.com/id/test_author"></a><div class="playerAvatar"><img src="https://avatars.fastly.steamstatic.com/avatar.jpg"></div><div class="friendBlockContent">测试作者<br><span>Offline</span></div></div>
        <div class="friendBlock" data-miniprofile="43"><a class="friendBlockLinkOverlay" href="https://steamcommunity.com/profiles/76561197960265771"></a><div class="friendBlockContent">Co-author<br>Online</div></div></div>
        <div class="friendBlock" data-miniprofile="44"><a class="friendBlockLinkOverlay" href="https://steamcommunity.com/id/commenter"></a><div class="friendBlockContent">Commenter<br>Online</div></div>
        <div class="detailsStatLeft">File Size</div><div class="detailsStatRight">15.5 MB</div>
        """
        let parsed = try WorkshopItemPageParser.parse(html: html, requestedID: "123")
        try check(parsed.authors.count == 2 && parsed.authors.first?.id == author.id && parsed.authors.first?.name == "测试作者", "creator block supports co-authors and excludes comment authors/status")
        try check(parsed.authors.first?.avatarURL?.host == "avatars.fastly.steamstatic.com", "creator avatar uses validated Steam image metadata")
        try check(parsed.description == "First line\nBefore link\nNested paragraph\nAfter & end" && !parsed.description.contains("Outside"), "full description retains leading text, nested paragraphs and line breaks without adjacent panels")
        try check(parsed.fileSizeText == "15.5 MB", "public detail metadata includes file size")
        let imageURL = "https://images.steamusercontent.com/ugc/123456/ABCDEF0123456789/?imw=512&ima=fit"
        let metadata = "<meta property=\"og:image\" content=\"" + imageURL.replacingOccurrences(of: "&", with: "&amp;") + "\">"
        try check(WorkshopItemPageParser.extractPreviewURL(from: metadata)?.absoluteString == imageURL,
                  "preview metadata preserves the complete image key and decoded query")
        try check(WorkshopItemPageParser.extractPreviewURL(from: "<meta property='og:image' content='https://images.steamusercontent.com/ugc/123456/'>") == nil,
                  "an owner-only UGC directory is never accepted as an image")
        try check(WorkshopItemPageParser.extractPreviewURL(from: "<img id='previewImage' src='https://steamuserimages-a.akamaihd.net/ugc/123456/ABCDEF/'>")?.path.contains("ABCDEF") == true,
                  "legacy primary preview preserves its image key")
        try check(WorkshopItemPageParser.extractPreviewURL(from: "<meta property='og:image' content='https://evil.example/image.jpg'>") == nil,
                  "untrusted preview image hosts are rejected")
        for url in ["https://evil.example/id/name", "https://steamcommunity.com.evil.test/id/name", "http://steamcommunity.com/id/name", "https://steamcommunity.com/id/../login", "https://steamcommunity.com/id/a%2Fb", "https://user@steamcommunity.com/id/name"] {
            try check(WorkshopAuthor(profileURL: URL(string: url)!, name: "Test") == nil, "unsafe author URL rejected: \(url)")
        }
        try check(WorkshopAuthor(profileURL: profile, name: "X", accountID: UInt64.max) == nil, "untrusted mini-profile overflow is rejected")
        try check(WorkshopAuthor(profileURL: URL(string: "https://steamcommunity.com/profiles/76561197960265771")!, name: "X", accountID: 42) == nil, "conflicting creator identities are rejected")
        let url = author.worksURL(page: 2)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        try check(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "profiles/76561197960265770/myworkshopfiles" && query.contains(.init(name: "appid", value: "431960")) && query.contains(.init(name: "p", value: "2")), "author URL targets canonical public Wallpaper Engine creations and explicit page")
        let page = try WorkshopAuthorPageParser.parse(html: pageHTML(page: 2), author: author, page: 2)
        try check(page.results.count == 30 && page.totalCount == 65 && page.totalPages == 3 && page.results.first?.id == "1031", "author list parses the real page range and preserves order")
        try fails("wrong page response fails closed") { _ = try WorkshopAuthorPageParser.parse(html: pageHTML(), author: author, page: 2) }
        try fails("cross-application cards fail closed") { _ = try WorkshopAuthorPageParser.parse(html: pageHTML().replacingOccurrences(of: "data-appid=\"431960\"", with: "data-appid=\"570\""), author: author, page: 1) }
        try fails("login/error pages are not an empty author list") { _ = try WorkshopAuthorPageParser.parse(html: "<title>Sign in</title>", author: author, page: 1) }
        let empty = try WorkshopAuthorPageParser.parse(html: "<div class='workshopBrowseItems'></div>", author: author, page: 1)
        try check(empty.results.isEmpty && empty.totalCount == 0, "explicit empty author list has an empty state")

        let gate = InformationGate()
        let model = WorkshopInformationModel(detailLoader: { await gate.load($0) })
        let old = Task { await model.loadDetail(WorkshopItemID("1")!) }
        while !(await gate.has("1")) { await Task.yield() }
        let current = Task { await model.loadDetail(WorkshopItemID("2")!) }
        while !(await gate.has("2")) { await Task.yield() }
        await gate.finish(detail("2")); await current.value
        await gate.finish(detail("1")); await old.value
        try check(model.detail?.id == "2" && !model.isLoading, "late metadata cannot overwrite a different selected wallpaper")
        let cancelled = Task { await model.loadDetail(WorkshopItemID("3")!) }
        while !(await gate.has("3")) { await Task.yield() }
        model.cancel(); await gate.finish(detail("3")); await cancelled.value
        try check(model.detail == nil && !model.isLoading && model.error == nil, "dismissing information cancels presentation ownership")
        let mismatchDetail = detail("999")
        let mismatch = WorkshopInformationModel(detailLoader: { _ in mismatchDetail })
        await mismatch.loadDetail(WorkshopItemID("4")!)
        try check(mismatch.detail == nil && mismatch.error != nil, "mismatched item identity is surfaced as an error")
        let worksModel = WorkshopInformationModel(worksLoader: { _, page in await gate.loadPage(page) })
        let oldPage = Task { await worksModel.loadWorks(author, page: 1) }
        while !(await gate.hasPage(1)) { await Task.yield() }
        let newPage = Task { await worksModel.loadWorks(author, page: 2) }
        while !(await gate.hasPage(2)) { await Task.yield() }
        let second = try WorkshopAuthorPageParser.parse(html: pageHTML(page: 2), author: author, page: 2)
        let first = try WorkshopAuthorPageParser.parse(html: pageHTML(), author: author, page: 1)
        await gate.finishPage(second); await newPage.value
        await gate.finishPage(first); await oldPage.value
        let prefetchGate = InformationGate()
        let prefetchModel = WorkshopInformationModel(worksLoader: { _, page in await prefetchGate.loadPage(page) })
        let gallery = WorkshopAuthorGallerySession(author: author, model: prefetchModel)
        let initialRequest = gallery.load()
        while !(await prefetchGate.hasPage(1)) { await Task.yield() }
        try check(prefetchModel.isLoading && gallery.page == 1,
                  "avatar navigation starts the first author request before any gallery view mounts")
        await prefetchGate.finishPage(first); await initialRequest.value
        try check(prefetchModel.works?.page == 1 && !prefetchModel.isLoading,
                  "the gallery consumes the already-started first-page request")
        let nextRequest = gallery.load(page: 2)
        while !(await prefetchGate.hasPage(2)) { await Task.yield() }
        await prefetchGate.finishPage(second); await nextRequest.value
        try check(gallery.page == 2 && prefetchModel.works?.page == 2,
                  "the retained gallery session owns pagination independently of opened details")
        let leavingRequest = gallery.load(page: 1, refresh: true)
        while !(await prefetchGate.hasPage(1)) { await Task.yield() }
        gallery.cancel()
        await prefetchGate.finishPage(first); await leavingRequest.value
        try check(prefetchModel.works == nil && !prefetchModel.isLoading && prefetchModel.error == nil,
                  "leaving a gallery cancels ownership even when its transport ignores cancellation")
        try check(worksModel.works?.page == 2 && !worksModel.isLoading, "late author page cannot replace the selected page")
        let wrongPage = WorkshopInformationModel(worksLoader: { _, _ in first })
        await wrongPage.loadWorks(author, page: 2)
        try check(wrongPage.works == nil && wrongPage.error != nil, "mismatched author page response remains an error rather than stale works")

        if CommandLine.arguments.contains("--live") {
            var http = SteamHTTPClient(); http.maximumRetries = 0; http.timeout = 15
            let service = WorkshopService(http: http)
            let value = try await service.detail(itemID: WorkshopItemID("3818965540")!)
            try check(!value.description.isEmpty && value.authors.first?.id == "profiles/76561198284605466", "LIVE public item provides full description, creator name and canonical identity")
            guard let preview = value.previewImageURL else { throw Failure(message: "LIVE missing preview URL") }
            var request = URLRequest(url: preview); request.timeoutInterval = 15
            let (bytes, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            try check((response as? HTTPURLResponse)?.statusCode == 200 && NSImage(data: bytes) != nil,
                      "LIVE author-work preview URL downloads and decodes a real image")
            let single = try await service.authorWorks(author: value.authors[0], page: 1)
            try check(single.results.contains { $0.id == value.id }, "LIVE author's creations include the source wallpaper")
            let prolific = WorkshopAuthor(profileURL: URL(string: "https://steamcommunity.com/profiles/76561199052584728")!, name: "Live author")!
            let first = try await service.authorWorks(author: prolific, page: 1)
            let next = try await service.authorWorks(author: prolific, page: 2)
            try check(first.results.count == 30 && next.results.count == 30 && Set(first.results.map(\.id)).isDisjoint(with: next.results.map(\.id)), "LIVE author pagination returns distinct validated first and second pages")
        }
        print("RESULT \(checks) workshop information checks passed; metadata only, no account/download/playback changes")
    }
    static func main() async throws { try await run() }
}
