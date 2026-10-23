import Foundation

/// Public update metadata only. The signing private key never enters the app.
struct GWAppUpdateConfiguration: Sendable {
    let feedURL: URL?
    let publicEDKey: String

    init(infoDictionary: [String: Any]) {
        feedURL = (infoDictionary["SUFeedURL"] as? String).flatMap(URL.init(string:))
        publicEDKey = (infoDictionary["SUPublicEDKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationError: String? {
        guard let feedURL, let host = feedURL.host, !host.isEmpty,
              feedURL.user == nil, feedURL.password == nil, feedURL.fragment == nil else {
            return "此构建未配置有效的更新地址。"
        }
        var secure = feedURL.scheme?.lowercased() == "https"
        #if DEBUG
        // Isolated integration tests serve signed updates on loopback only.
        secure = secure || (feedURL.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
        #endif
        guard secure else { return "更新地址必须使用 HTTPS。" }
        guard Data(base64Encoded: publicEDKey)?.count == 32 else {
            return "此构建未配置有效的更新签名公钥。"
        }
        return nil
    }

    /// Sparkle owns the recurring schedule. An additional launch check is only
    /// made when enabled and the previous check is at least one hour old.
    static func shouldCheckAtLaunch(automaticChecks: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard automaticChecks else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 3_600
    }
}
