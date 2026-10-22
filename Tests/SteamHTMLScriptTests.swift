import Foundation

@main enum SteamHTMLScriptTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1; print("PASS \(name)")
        }
        for title in ["İstanbul", "Kelvin", "Ⱥ", "İ İ K 中文 🎨", "普通的卡通壁纸"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["title": title, "path": "MixedCASE/İ/K"])
            let payload = String(decoding: bytes, as: UTF8.self)
            for prefix in ["", "<title>İ K Ⱥ 中文 🎨</title>"] {
                let html = prefix + "<script>ignored</script><SCRIPT TYPE='application/json' ID = 'valve-ssr-data'>" + payload + "</SCRIPT><div>after</div>"
                check(SteamHTML.scriptContent(in: html, id: "VALVE-SSR-DATA") == payload,
                      "Unicode case conversion never shifts script bounds: \(title), prefix=\(!prefix.isEmpty)")
            }
        }
        check(SteamHTML.scriptContent(in: "<script data-id='valve-ssr-data'>wrong</script>", id: "valve-ssr-data") == nil,
              "data-id is not mistaken for the script id")
        let request = WorkshopSearchRequest(filters: .init(genre: .cartoon))
        let root: [String: Any] = ["results": [["publishedfileid": "123", "title": "İstanbul Cartoon", "tags": ["Video", "Cartoon"]]], "total_count": 1]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        let page = try WorkshopSSR.parseBrowsePage(html: "<script id='valve-ssr-data'>" + payload + "</script>", request: request)
        check(page.results.first?.title == "İstanbul Cartoon" && page.results.first?.tags.contains("Cartoon") == true,
              "the full SSR parser preserves Unicode titles and Cartoon results")
        var rejected = false
        do { _ = try WorkshopSSR.parseBrowsePage(html: "<script id='valve-ssr-data'>not JSON</script>", request: request) }
        catch SteamHTTPError.decoding { rejected = true }
        check(rejected, "malformed SSR remains an explicit error")
        if let index = CommandLine.arguments.firstIndex(of: "--html"), CommandLine.arguments.count > index + 1 {
            let html = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
            let actual = try WorkshopSSR.parseBrowsePage(html: html, request: request)
            check(!actual.results.isEmpty && actual.results.allSatisfy { $0.tags.contains("Video") && $0.tags.contains("Cartoon") },
                  "captured live Steam Cartoon response parses matching Video and Cartoon items")
            print("LIVE Cartoon count=\(actual.results.count), total=\(actual.totalCount), IDs=\(actual.results.map(\.id).joined(separator: ","))")
        }
        print("RESULT \(checks) Steam script/SSR checks passed")
    }
}
