import AppKit
import Foundation

@main struct DisplayIdentityCompatibilityTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1
        }
        var identities = DisplaySessionIdentities()
        let first = identities.identifier(for: 7, stableUUID: nil)
        check(first.hasPrefix("session-display:"), "UUID-less display remains visible with session identity")
        identities.retainOnline([7, 8])
        check(identities.identifier(for: 7, stableUUID: nil) == first, "resolution/arrangement refresh keeps online session identity")
        check(identities.identifier(for: 8, stableUUID: nil) != first, "two UUID-less displays cannot share an identity")
        identities.retainOnline([8])
        let reconnected = identities.identifier(for: 7, stableUUID: nil)
        check(reconnected != first, "reused CoreGraphics ID after disconnect cannot inherit prior assignment")
        check(identities.identifier(for: 7, stableUUID: "STABLE-UUID") == "STABLE-UUID", "real UUID takes priority")
        check(identities.identifier(for: 7, stableUUID: nil) != reconnected, "stable-to-fallback transition cannot resurrect stale session")
        var anotherSession = DisplaySessionIdentities()
        check(anotherSession.identifier(for: 8, stableUUID: nil) != identities.identifier(for: 8, stableUUID: nil), "another registry session cannot correlate UUID-less displays")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimmer-display-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let item = WallpaperItem(title: "Legacy", filePath: root.appendingPathComponent("project.json").path, contentKind: .web)
        var document = LibraryDocument(items: [item], assignments: [first: item.id, "stable": item.id], displaySettings: [first: .default, "stable": .default])
        let raw = try LibraryPersistence.makeEncoder().encode(document)
        check(!String(decoding: raw, as: UTF8.self).contains("webAllowHTTPS"), "legacy item does not invent a network permission")
        let legacy = try LibraryPersistence.makeDecoder().decode(LibraryDocument.self, from: raw)
        check(legacy.items[0].webAllowHTTPS == nil, "legacy web permission remains nil and desktop stays offline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try raw.write(to: url)
        let cleaned = try LibraryPersistence.load(from: url)
        check(cleaned.assignments[first] == nil && cleaned.displaySettings[first] == nil && cleaned.assignments["stable"] == item.id, "load never restores a session display assignment")
        try LibraryPersistence.save(document, to: url)
        let saved = try LibraryPersistence.makeDecoder().decode(LibraryDocument.self, from: Data(contentsOf: url))
        check(saved.assignments[first] == nil && saved.displaySettings[first] == nil && saved.displaySettings["stable"] != nil, "all persistence entry points filter session IDs centrally")
        for permission in [true, false] {
            document.items[0].webAllowHTTPS = permission
            try LibraryPersistence.save(document, to: url)
            let restored = try LibraryPersistence.load(from: url)
            check(restored.items[0].webAllowHTTPS == permission, "explicit network permission survives save and restart")
        }
        print("DisplayIdentityCompatibilityTests: \(checks) checks passed; temporary files only")
    }
}
