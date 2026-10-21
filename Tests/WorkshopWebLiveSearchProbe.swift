import Foundation
import Darwin

/// Opt-in, real public-network evidence. No fixtures, previews, downloads or account APIs.
@main
struct WorkshopWebLiveSearchProbe {
    struct Item: Codable {
        let id: String
        let tags: [String]
        let declaredType: String?
        let declaredKind: String
        let consumerAppID: Int?
    }
    struct Evidence: Codable {
        var status: String
        let startedAtUTC: String
        var elapsedSeconds: Double
        let endpoint: String
        let query: String
        let requestedType: String
        let page: Int
        var resultCount: Int?
        var totalCount: Int?
        var discoveryPath: String?
        var items: [Item]
        var error: String?
        let transport: String
        let boundary: String
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.contains("--live"),
              let outputFlag = arguments.firstIndex(of: "--evidence"),
              arguments.indices.contains(outputFlag + 1) else {
            print("Explicit opt-in required: --live --evidence <output.json>")
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[outputFlag + 1])
        let request = WorkshopSearchRequest(query: "nature", page: 1,
            filters: WorkshopSearchFilters(type: .web))
        let started = Date()
        var evidence = Evidence(status: "running", startedAtUTC: ISO8601DateFormatter().string(from: started),
            elapsedSeconds: 0, endpoint: request.url.absoluteString, query: request.query,
            requestedType: request.filters.type.rawValue, page: request.page,
            items: [], transport: "Production SteamHTTPClient: ephemeral URLSession, cookies disabled, cache bypassed; maximumRetries=0. Search completion requires HTTP 2xx; exact status/redirect target is not exposed by this API.",
            boundary: "Public browse metadata only; no account/cookies, preview images, workshop downloads, Steam cache, or user library access. Page tags are declarations, not downloaded project validation.")
        var code: Int32 = 0
        do {
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let tags = components?.queryItems?.filter { $0.name.hasPrefix("requiredtags") }.compactMap(\.value) ?? []
            guard tags.contains("Web"), !tags.contains("Video") else {
                throw ProbeFailure("Request does not exclusively request Web: \(tags)")
            }
            var http = SteamHTTPClient()
            http.maximumRetries = 0
            http.timeout = 25
            let page = try await WorkshopService(http: http).search(request)
            evidence.resultCount = page.results.count
            evidence.totalCount = page.totalCount
            evidence.discoveryPath = page.discoveryPath
            evidence.items = page.results.map {
                Item(id: $0.publishedFileID, tags: $0.tags, declaredType: $0.declaredTypeTag,
                     declaredKind: $0.declaredKind.rawValue, consumerAppID: $0.consumerAppID)
            }
            guard page.request == request else { throw ProbeFailure("Service changed the search request") }
            guard !page.results.isEmpty else {
                evidence.status = "inconclusive_empty_live_results"
                evidence.error = "HTTP search completed but returned no items; Web filtering cannot be proven."
                code = 3
                return finish(evidence, started: started, output: output, code: code)
            }
            guard page.results.allSatisfy({ result in
                result.declaredKind == .web && result.tags.contains(where: { $0.caseInsensitiveCompare("Web") == .orderedSame })
                    && !result.isCollection && result.childCount == 0
            }) else { throw ProbeFailure("Live results include non-Web or collection declarations; see original tags") }
            evidence.status = "passed_real_public_network"
        } catch let error as ProbeFailure {
            evidence.status = "failed_live_assertion"
            evidence.error = error.message
            code = 1
        } catch {
            evidence.status = "failed_network_or_live_page_parse"
            evidence.error = String(describing: error) + ": " + error.localizedDescription
            code = 2
        }
        finish(evidence, started: started, output: output, code: code)
    }

    struct ProbeFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    static func finish(_ initial: Evidence, started: Date, output: URL, code: Int32) {
        var evidence = initial
        evidence.elapsedSeconds = Date().timeIntervalSince(started)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(evidence).write(to: output, options: .atomic)
            print("\(evidence.status): \(evidence.resultCount ?? 0) results, \(String(format: "%.3f", evidence.elapsedSeconds)) seconds")
            print("GET \(evidence.endpoint)")
            print("Evidence: \(output.path)")
            if let error = evidence.error { print(error) }
            exit(code)
        } catch {
            print("Cannot write evidence: \(error.localizedDescription)")
            exit(74)
        }
    }
}
