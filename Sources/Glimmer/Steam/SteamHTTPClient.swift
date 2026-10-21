import Foundation

/// Steam 公开页面的 HTTP 客户端。
///
/// 约束：
/// - 全部请求通过 URLSession 真实执行，不使用外部 shell，不拼接不可信内容。
/// - 只访问 steamcommunity.com 的公开页面；不携带任何账号 Cookie 或令牌。
/// - 明确区分网络失败、限流（429）、服务器错误与页面结构变化。
enum SteamHTTPError: LocalizedError, Equatable {
    case rateLimited(retryAfterSeconds: Int?)
    case httpStatus(Int)
    case network(String)
    case decoding(String)
    case structureChanged(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let seconds):
            if let seconds {
                return "Steam 请求过于频繁（429 限流）。请在约 \(seconds) 秒后重试。"
            }
            return "Steam 请求过于频繁（429 限流），请稍后重试。"
        case .httpStatus(let code):
            if code == 403 {
                return "Steam 返回 403（拒绝访问）。可能被网络环境或代理拦截，请稍后重试。"
            }
            if (500...599).contains(code) {
                return "Steam 服务端错误（\(code)），请稍后重试。"
            }
            return "Steam 返回异常状态码 \(code)。"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .decoding(let detail):
            return "无法解析 Steam 返回内容：\(detail)"
        case .structureChanged(let detail):
            return "Steam 页面结构可能已变化：\(detail)"
        }
    }

    /// 是否适合自动重试。
    var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .httpStatus(let code): return code >= 500
        case .decoding, .structureChanged: return false
        }
    }
}

/// 带有限次重试的 Steam 页面抓取。
struct SteamHTTPClient: Sendable {
    var userAgent: String = SteamHTTPClient.defaultUserAgent
    var language: String = "zh-CN,zh;q=0.9,en;q=0.8"
    var timeout: TimeInterval = 30
    var maximumRetries: Int = 2
    /// 重试基础间隔（秒），实际等待 = base * attempt。
    var retryBaseDelay: TimeInterval = 1.5
    /// 允许测试注入的最小限流等待（秒），避免自检时长时间阻塞。
    var maximumRetryWait: TimeInterval = 20

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 抓取一个公开页面（HTML 字符串）。
    func fetchPage(_ url: URL, acceptLanguage: Bool = true, allowRetries: Bool = true) async throws -> String {
        var attempt = 0
        let maxAttempts = allowRetries ? max(1, maximumRetries + 1) : 1
        while true {
            attempt += 1
            do {
                let (data, response) = try await SteamHTTPClient.session.data(for: makeRequest(url, acceptLanguage: acceptLanguage))
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let retryAfter = Self.retryAfterSeconds(from: http)
                    if http.statusCode == 429 {
                        throw SteamHTTPError.rateLimited(retryAfterSeconds: retryAfter)
                    }
                    throw SteamHTTPError.httpStatus(http.statusCode)
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw SteamHTTPError.decoding("返回内容不是有效的 UTF-8 文本")
                }
                return text
            } catch let error as SteamHTTPError {
                guard error.isTransient, attempt < maxAttempts else { throw error }
                let wait = Self.retryDelay(attempt: attempt, error: error, base: retryBaseDelay, cap: maximumRetryWait)
                WorkshopLog.info("Steam 请求第 \(attempt) 次失败（\(error.errorDescription ?? "未知")），\(String(format: "%.1f", wait)) 秒后重试")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch let error as URLError {
                guard attempt < maxAttempts else {
                    throw SteamHTTPError.network(Self.describe(urlError: error))
                }
                let wait = Self.retryDelay(attempt: attempt, error: nil, base: retryBaseDelay, cap: maximumRetryWait)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func makeRequest(_ url: URL, acceptLanguage: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if acceptLanguage {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        return request
    }

    static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(trimmed), seconds >= 0 { return seconds }
        return nil
    }

    static func retryDelay(attempt: Int, error: SteamHTTPError?, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        if case .rateLimited(let retryAfter)? = error, let retryAfter {
            return min(Double(retryAfter), cap)
        }
        return min(base * Double(attempt), cap)
    }

    static func describe(urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet: return "设备未连接网络"
        case .timedOut: return "请求超时"
        case .cannotFindHost, .cannotConnectToHost: return "无法连接 Steam 服务器"
        case .networkConnectionLost: return "网络连接中断"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS 连接失败（\(urlError.code.rawValue)）"
        default: return "\(urlError.localizedDescription)（\(urlError.code.rawValue)）"
        }
    }
}
