import Foundation
import AppKit
import Darwin

@main
enum DisplayLockScreenConfigurationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Glimmer-Display-LockScreen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1; print("PASS \(name)")
        }
        func asset(live: Bool = false) throws -> [String: Any] {
            let id = UUID()
            var config: [String: Any] = ["schemaVersion": live ? 2 : 1, "assetID": id.uuidString,
                "videoFileName": live ? "" : id.uuidString + ".mp4", "gravity": "fill", "isMuted": true]
            if live {
                let name = "live-" + id.uuidString
                config["liveDirectoryName"] = name
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                let file = root.appendingPathComponent(id.uuidString + ".mp4")
                try Data([1, 2, 3]).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            return config
        }
        func write(_ object: [String: Any]) throws {
            let url = root.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let a = "AAAAAAAA-1111-1111-1111-111111111111", b = "BBBBBBBB-2222-2222-2222-222222222222"
        let other = "CCCCCCCC-3333-3333-3333-333333333333"
        let first = try asset(), second = try asset(live: true), fallback = try asset()
        if let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() {
            let identifier = CFUUIDCreateString(nil, uuid) as String
            try write(["schemaVersion": 3, "displayConfigurations": [identifier: second]])
            check(try GWConfiguration.load(directory: root, isolatedProbe: true, displayID: CGMainDisplayID()).0.assetID.uuidString == second["assetID"] as? String,
                  "the real CoreGraphics display ID resolves to its persisted UUID assignment")
        }
        try write(first)
        check(try GWConfiguration.load(directory: root, isolatedProbe: true).0.assetID.uuidString == first["assetID"] as? String,
              "legacy global video configuration remains readable")
        var document: [String: Any] = ["schemaVersion": 3, "displayConfigurations": [a: first, b: second]]
        try write(document)
        let video = try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: a.lowercased())
        check(video.0.assetID.uuidString == first["assetID"] as? String && video.1.pathExtension == "mp4",
              "A resolves its video using its stable UUID regardless of letter case")
        let live = try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: b)
        check(live.0.assetID.uuidString == second["assetID"] as? String && live.1.lastPathComponent.hasPrefix("live-"),
              "B independently resolves a live Scene or Web package")
        do {
            _ = try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: other)
            preconditionFailure("unassigned display borrowed another display's wallpaper")
        } catch { checks += 1 }
        do {
            _ = try GWConfiguration.load(directory: root, isolatedProbe: true)
            preconditionFailure("unknown host display borrowed another wallpaper")
        } catch { checks += 1 }
        check((try? GWConfiguration.load(directory: root, isolatedProbe: true, allowPreviewFallback: true)) != nil,
              "settings and explicit preview can resolve an individual assignment")
        document["defaultConfiguration"] = fallback
        try write(document)
        check(try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: other).0.assetID.uuidString == fallback["assetID"] as? String,
              "unassigned displays retain the previous global fallback")
        check(try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: a).0.assetID.uuidString == first["assetID"] as? String,
              "a display override takes precedence over the global fallback")
        var unsafe = first
        unsafe["videoFileName"] = "../outside.mp4"
        document["displayConfigurations"] = [a: unsafe, b: second]
        try write(document)
        do {
            _ = try GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: a)
            preconditionFailure("unsafe selected display path accepted")
        } catch { checks += 1 }
        check((try? GWConfiguration.load(directory: root, isolatedProbe: true, displayUUID: b)) != nil,
              "a rejected A configuration cannot replace B's live asset")
        print("DisplayLockScreenConfigurationTests: \(checks) checks passed")
    }
}
