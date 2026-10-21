import Foundation

actor PaginationFixture {
    private(set) var calls:[WorkshopSearchRequest]=[]
    var mismatch=false
    func setMismatch(_ value:Bool){mismatch=value}
    func search(_ request:WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        calls.append(request)
        if request.query=="old" {try? await Task.sleep(for:.milliseconds(150))}
        var returned=request;if mismatch{returned.page+=1}
        return .init(request:returned,totalCount:90,totalPages:3,results:[.init(publishedFileID:String(request.page),title:request.query,shortDescription:"",tags:["Video"],childCount:0,isCollection:false)],discoveryPath:"fixture")
    }
}
@main @MainActor enum WorkshopPaginationTests {
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws{guard value else{throw TestError(message:name)};checks+=1}
    struct TestError:LocalizedError{let message:String;var errorDescription:String?{message}}
    static func html(_ queries:[[String:Any]])throws->String {
        let nested=try JSONSerialization.data(withJSONObject:["queries":queries])
        let outer=try JSONSerialization.data(withJSONObject:["renderContext":["queryData":String(decoding:nested,as:UTF8.self)]])
        return "<script id='valve-ssr-data'>"+String(decoding:outer,as:UTF8.self)+"</script>"
    }
    static func cached(_ request:WorkshopSearchRequest,id:String,current:Int?=nil)->[String:Any] {
        let tags=(request.filters.type.requiredTag.map{[$0]} ?? [])+request.filters.requiredTags
        let query:[String:Any]=["appid":431960,"browse_sort":request.sort.steamBrowseValue,"page":request.page,"num_per_page":30,"trend_days":request.filters.trendPeriod.rawValue,"search_text":request.query,"required_tags":tags]
        return ["queryKey":["workshop_browse",query,1],"state":["data":["results":[["publishedfileid":id,"title":"fixture","tags":tags]],"current_page":current ?? request.page,"total_count":90,"total_pages":3]]]
    }
    static func rejects(_ html:String,_ request:WorkshopSearchRequest,_ name:String)throws {
        var failed=false;do{_ = try WorkshopSSR.parseBrowsePage(html:html,request:request)}catch SteamHTTPError.structureChanged{failed=true}
        try check(failed,name)
    }
    static func wait(_ coordinator:WorkshopCoordinator)async throws {
        for _ in 0..<200{if !coordinator.isSearching{return};try await Task.sleep(for:.milliseconds(10))}
        throw TestError(message:"fixture search timeout")
    }
    static func offline()async throws {
        let filters=WorkshopSearchFilters(type:.web,resolution:.size1920X1080,genre:.nature,ageRating:.everyone,trendPeriod:.year)
        let requested=WorkshopSearchRequest(query:"rain & 雨",sort:.trend,page:2,pageSize:24,filters:filters)
        let parts=URLComponents(url:requested.url,resolvingAgainstBaseURL:false)!.queryItems!
        try check(parts.first{$0.name=="p"}?.value=="2" && !parts.contains{$0.name=="page"},"Steam canonical p advances real requested page")
        try check(parts.first{$0.name=="days"}?.value=="365" && !parts.contains{$0.name=="trend_days"},"Steam canonical days uses real year range")
        try check(parts.first{$0.name=="searchtext"}?.value==requested.query && parts.filter{$0.name.hasPrefix("requiredtags[")}.compactMap(\.value)==["Web","1920 x 1080","Nature","Everyone"],"pagination URL preserves query type and all tag filters")
        for period in WorkshopTrendPeriod.allCases {
            let r=WorkshopSearchRequest(filters:.init(trendPeriod:period)),q=URLComponents(url:r.url,resolvingAgainstBaseURL:false)!.queryItems!
            try check(q.first{$0.name=="days"}?.value==String(period.urlDays),"genuine Steam range URL \(period.title)")
        }
        var subscribed=requested;subscribed.sort = .mostsubscribed
        try check(URLComponents(url:subscribed.url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="browsesort"}?.value=="totaluniquesubscribers","subscription ranking uses supported Steam sort without renaming legacy enum")
        var nonTrend=requested;nonTrend.sort = .mostrecent
        try check(!URLComponents(url:nonTrend.url,resolvingAgainstBaseURL:false)!.queryItems!.contains{$0.name=="days"},"time window applies only to hot ranking")
        var first=requested;first.page=1
        let mixed=try html([cached(first,id:"11"),cached(requested,id:"22")])
        let page=try WorkshopSSR.parseBrowsePage(html:mixed,request:requested)
        try check(page.results.map(\.id)==["22"] && page.request.page==2,"SSR chooses matching query identity rather than first preloaded cache")
        try rejects(try html([cached(first,id:"11")]),requested,"first page response cannot masquerade as requested second page")
        try rejects(try html([cached(requested,id:"22",current:1)]),requested,"mismatched current_page rejects even when queryKey says page2")
        let legacy:[String:Any]=["results":[["publishedfileid":"11","title":"fixture","tags":["Web"]]],"total_count":90]
        try rejects(try html([legacy]),requested,"unidentified legacy results cannot masquerade as requested second page")
        var wrongRange=requested;wrongRange.filters.trendPeriod = .week
        try rejects(try html([cached(wrongRange,id:"33")]),requested,"SSR rejects stale trend period")
        var wrongType=requested;wrongType.filters.type = .video
        try rejects(try html([cached(wrongType,id:"44")]),requested,"SSR rejects wrong type query cache")
        var wrongTag=requested;wrongTag.filters.genre = .anime
        try rejects(try html([cached(wrongTag,id:"55")]),requested,"SSR rejects wrong genre cache")
        var wrongText=requested;wrongText.query="other"
        try rejects(try html([cached(wrongText,id:"66")]),requested,"SSR rejects wrong search text")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("GW-Pagination-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let fixture=PaginationFixture(),account=SteamAccountManager(layout:SteamCMDLayout(root:root.appendingPathComponent("SteamCMD")))
        let coordinator=WorkshopCoordinator(account:account,browserStore:.init(persistenceURL:nil),searchOperation:{try await fixture.search($0)},queuePersistence:.disabled)
        coordinator.searchText="forest";coordinator.applyFilters(filters);try await wait(coordinator)
        coordinator.nextPage();try await wait(coordinator)
        try check(coordinator.lastRequest.page==2 && coordinator.lastRequest.filters==filters && coordinator.lastRequest.query=="forest","next page preserves committed query type tags year")
        coordinator.selectTrendPeriod(.day);try await wait(coordinator)
        try check(coordinator.lastRequest.page==1 && coordinator.lastRequest.filters.trendPeriod == .day && coordinator.lastRequest.filters.type == .web && coordinator.lastRequest.filters.genre == .nature,"main-layer time choice returns first page preserving other filters")
        coordinator.selectSearchSort(.mostrecent);try await wait(coordinator)
        try check(coordinator.lastRequest.sort == .mostrecent && coordinator.lastRequest.filters.trendPeriod == .day,"nontrend sort retains last chosen time without applying it to URL")
        coordinator.selectTrendPeriod(.day);try await wait(coordinator)
        try check(coordinator.lastRequest.sort == .trend,"selecting a time returns to hot ranking")
        coordinator.nextPage();try await wait(coordinator);coordinator.previousPage();try await wait(coordinator)
        try check(coordinator.lastRequest.page==1 && coordinator.lastRequest.filters.trendPeriod == .day,"both paging directions preserve chosen period")
        coordinator.searchText="old";coordinator.search();try await Task.sleep(for:.milliseconds(10))
        coordinator.searchText="new";coordinator.search();try await wait(coordinator);try await Task.sleep(for:.milliseconds(200))
        try check(coordinator.results.first?.title=="new" && coordinator.lastRequest.query=="new","cancel-ignoring old search cannot overwrite current request")
        await fixture.setMismatch(true);coordinator.search();try await wait(coordinator)
        try check(coordinator.searchError != nil && coordinator.results.isEmpty && !coordinator.canGoToNextPage,"wrong returned request identity is failure with no stale pagination")
    }
    static func live() async throws -> [[String:Any]] {
        var http=SteamHTTPClient();http.maximumRetries=0;http.timeout=30
        let service=WorkshopService(http:http)
        let one=WorkshopSearchRequest(),first=try await service.search(one)
        var two=one;two.page=2
        let second=try await service.search(two)
        try check(!first.results.isEmpty && !second.results.isEmpty && first.results.map(\.id) != second.results.map(\.id),"REAL Steam page1/page2 have distinct actual item IDs")
        var rows:[[String:Any]]=[]
        func row(_ page:WorkshopSearchPage)->[String:Any]{["url":page.request.url.absoluteString,"page":page.request.page,"periodDays":page.request.filters.trendPeriod.rawValue,"ids":page.results.map(\.id),"count":page.results.count,"discoveryPath":page.discoveryPath]}
        rows += [row(first),row(second)]
        for period in WorkshopTrendPeriod.allCases where period != .week {
            let request=WorkshopSearchRequest(filters:.init(trendPeriod:period)),page=try await service.search(request)
            try check(!page.results.isEmpty,"REAL Steam returns matching SSR for period \(period.rawValue)")
            rows.append(row(page))
        }
        let filtered=WorkshopSearchRequest(filters:.init(resolution:.size1920X1080,genre:.nature,trendPeriod:.month))
        let page=try await service.search(filtered)
        try check(!page.results.isEmpty && page.results.allSatisfy{$0.tags.contains("1920 x 1080") && $0.tags.contains("Nature")},"REAL time ranking and resolution/genre tags remain combined")
        rows.append(row(page))
        for sort in WorkshopSearchSort.allCases where sort != .trend {
            let request=WorkshopSearchRequest(sort:sort),page=try await service.search(request)
            try check(!page.results.isEmpty,"REAL nontrend sort identity \(sort.rawValue)")
            rows.append(row(page))
        }
        let web=WorkshopSearchRequest(query:"rain",filters:.init(type:.web,trendPeriod:.year))
        let webPage=try await service.search(web)
        try check(!webPage.results.isEmpty && webPage.results.allSatisfy{$0.declaredKind == .web},"REAL text + Web + year query identity")
        rows.append(row(webPage));return rows
    }
    static func main()async {
        do {
            try await offline();let rows=CommandLine.arguments.contains("--live") ? try await live():[]
            let r:[String:Any]=["passed":checks,"live":!rows.isEmpty,"pages":rows,"boundary":"public cookie-free production HTTP/SSR only; no account, downloads or user library"]
            let bytes=try JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:bytes,as:UTF8.self))
            if let i=CommandLine.arguments.firstIndex(of:"--evidence"),CommandLine.arguments.count>i+1{try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]))}
        }catch{print("FAIL \(error.localizedDescription)");exit(1)}
    }
}
