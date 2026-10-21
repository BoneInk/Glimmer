import Foundation

enum AppConstants { static let applicationSupportFolderName = "Glimmer" }
struct WorkshopItemID { var value: String }
enum WorkshopInputValidator { static let wallpaperEngineAppID = 431960 }
enum WorkshopLog {
    static func sanitize(_ value: String) -> String { value }
    static func info(_ value: String) {}
    static func notice(_ value: String) {}
}
enum SteamHTML {
    static func collapseWhitespace(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}

@main
struct SteamCMDCapabilityProbeTests {
    static func main() async throws {
        if CommandLine.arguments.count > 1 {
            let layout = SteamCMDLayout(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            try FileManager.default.createDirectory(at: layout.homeURL, withIntermediateDirectories: true)
            let started = Date()
            let initial = SteamCMDCapabilityProbe.readArchitecture(at: layout.executableURL)
            let report = await SteamCMDCapabilityProbe(layout: layout).probe()
            let object: [String: Any] = [
                "initialArchitecture": initial.rawValue,
                "finalArchitecture": report.architecture?.rawValue ?? "unknown",
                "ready": report.status.isReady,
                "status": report.status.displayText,
                "rosetta": report.rosetta.displayText,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "evidence": report.evidence
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gw-macho-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        var checks = 0
        func check(_ bytes: [UInt8], _ expected: SteamCMDBinaryArchitecture) throws {
            try Data(bytes).write(to: temp)
            precondition(SteamCMDCapabilityProbe.readArchitecture(at: temp) == expected)
            checks += 1
        }
        try check([0xcf,0xfa,0xed,0xfe,0x07,0x00,0x00,0x01], .x86_64)
        try check([0xcf,0xfa,0xed,0xfe,0x0c,0x00,0x00,0x01], .arm64)
        for (magic, width) in [(UInt8(0xbe),20),(UInt8(0xbf),32)] {
            var bytes: [UInt8] = [0xca,0xfe,0xba,magic,0,0,0,2]
            bytes += [0x01,0,0,7] + Array(repeating: 0, count: width-4)
            bytes += [0x01,0,0,12] + Array(repeating: 0, count: width-4)
            try check(bytes, .universal)
        }
        try check([0xca,0xfe,0xba,0xbe,0,0,0,2,1], .unknown)
        try check([0xca,0xfe,0xba,0xbe,0xff,0xff,0xff,0xff], .unknown)
        print("PASS SteamCMD Mach-O architecture: \(checks) assertions")
    }
}
