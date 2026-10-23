import Foundation

@main
struct UpdateConfigurationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/UpdateConfiguration.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        precondition(GWAppUpdateConfiguration(infoDictionary: info).validationError == nil)
        precondition(info["SUEnableAutomaticChecks"] as? Bool == true)
        precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
        precondition(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        precondition(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        precondition(info["SURequireSignedFeed"] as? Bool == true)
        precondition(info["SUEnableSystemProfiling"] as? Bool == false)
        for invalidURL in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/feed", "https:///", "https://example.com/feed#fragment"] {
            var invalid = info
            invalid["SUFeedURL"] = invalidURL
            precondition(GWAppUpdateConfiguration(infoDictionary: invalid).validationError != nil, invalidURL)
        }
        for invalidKey in ["", "not-base64", Data(repeating: 0, count: 31).base64EncodedString(), Data(repeating: 0, count: 64).base64EncodedString()] {
            var invalid = info
            invalid["SUPublicEDKey"] = invalidKey
            precondition(GWAppUpdateConfiguration(infoDictionary: invalid).validationError != nil)
        }
        precondition(GWAppUpdateConfiguration(infoDictionary: [:]).validationError != nil)
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = GWAppUpdateConfiguration.shouldCheckAtLaunch
        precondition(!policy(false, nil, now))
        precondition(policy(true, nil, now))
        precondition(!policy(true, now.addingTimeInterval(-3_599), now))
        precondition(policy(true, now.addingTimeInterval(-3_600), now))
        precondition(policy(true, now.addingTimeInterval(-86_400), now))
        precondition(!policy(true, now.addingTimeInterval(1), now))
        print("UpdateConfigurationTests: HTTPS, keys, signed-update defaults and launch throttling passed")
    }
}
