import CryptoKit
import XCTest
@testable import OpenWallpaperEngine

/// Every `.mdl` of the library, loose or inside a `.pkg`, decodes field for field as
/// `Scripts/mdl-reference.py` decodes it (docs/models-plan.md §1): the Workshop folder,
/// OpenWallpaperStorage, and WE's default projects and assets. The committed decode
/// (`Tests/Fixtures/Models/library.json`, long arrays as digests) is checked for each file whose
/// bytes are the ones it was made from. The library keeps gaining and updating wallpapers: the
/// script is run now for the files that are new or changed, and they are checked against its
/// output; without a python3 they are skipped, and the attachment says so. Skipped when no root
/// is present (CI).
final class MDLLibrarySweepTests: XCTestCase {
    private struct LibraryModel {
        let root: String
        let item: String
        let file: String
        /// The SHA-256 of the file's bytes when the decode was written.
        let sha256: String
        let inline: Int?
        let model: [String: Any]

        var key: String { "\(root) \(item) \(file)" }

        init?(_ json: [String: Any]) {
            guard let root = json["root"] as? String, let item = json["item"] as? String, let file = json["file"] as? String,
                  let sha256 = json["sha256"] as? String, let model = json["model"] as? [String: Any] else { return nil }
            self.root = root
            self.item = item
            self.file = file
            self.sha256 = sha256
            self.inline = json["inline"] as? Int
            self.model = model
        }
    }

    private static var roots: [String: URL] {
        let environment = ProcessInfo.processInfo.environment
        let steam = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"
        let install = URL(fileURLWithPath: environment["OWE_WE_INSTALL"] ?? "\(steam)/common/wallpaper_engine")
        return ["workshop": URL(fileURLWithPath: environment["OWE_WORKSHOP"] ?? "\(steam)/workshop/content/431960"),
                "storage": URL(fileURLWithPath: environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage"),
                "default": install.appending(path: "projects/defaultprojects"),
                "assets": install.appending(path: "assets")]
    }

    private static func models(_ data: Data) throws -> [LibraryModel] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try json.map { try XCTUnwrap(LibraryModel($0), "a malformed entry") }
    }

    /// The file's bytes, nil when the library no longer has it.
    private func bytes(of model: LibraryModel, packages: inout [URL: PKGParser]) throws -> Data? {
        guard let root = Self.roots[model.root] else { return nil }
        let base = model.item == "-" ? root : root.appending(path: model.item, directoryHint: .isDirectory)
        let parts = model.file.components(separatedBy: "::")
        let file = base.appending(path: parts[0])
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard parts.count == 2 else { return try Data(contentsOf: file) }
        if packages[file] == nil { packages = [file: try PKGParser(url: file)] } // one package open at a time
        return packages[file]?.extractFile(named: parts[1])
    }

    func testEveryLibraryModelMatchesTheReference() throws {
        let committed = try Self.models(Fixtures.data("Models/library.json"))
        XCTAssertEqual(committed.count, 122, "the survey's 122 files (docs/models-plan.md §1.6)")
        XCTAssert(committed.allSatisfy { $0.model["error"] == nil }, "every library file parses")
        try XCTSkipUnless(Self.roots.values.contains { FileManager.default.fileExists(atPath: $0.path) },
                          "wallpaper library not present")

        var packages: [URL: PKGParser] = [:]
        var checked = 0
        var removed: [String] = [], changed: [String] = []
        for model in committed {
            guard let data = try bytes(of: model, packages: &packages) else {
                removed.append(model.key)
                continue
            }
            guard Self.digest(data) == model.sha256 else {
                changed.append(model.key)
                continue
            }
            MDLParseTests.check(data, expected: model.model, inline: model.inline, label: model.key)
            checked += 1
        }

        var notes: [String] = []
        if ReferenceScript.python != nil {
            let output = FileManager.default.temporaryDirectory.appending(path: "owe-mdl-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) } // scratch cleanup
            try ReferenceScript.run("mdl-reference.py",
                                    arguments: ["library", "--known", Fixtures.url("Models/library.json").path, "--out", output.path],
                                    environment: ["OWE_LIBRARY": Self.roots["storage"]?.path ?? "",
                                                  "OWE_WORKSHOP": Self.roots["workshop"]?.path ?? "",
                                                  "OWE_WE_INSTALL": Self.roots["default"]?.deletingLastPathComponent()
                                                      .deletingLastPathComponent().path ?? ""])
            let beyond = try Self.models(Data(contentsOf: output))
            for model in beyond {
                let data = try XCTUnwrap(try bytes(of: model, packages: &packages), "\(model.key): listed by the script, not readable here")
                MDLParseTests.check(data, expected: model.model, inline: model.inline, label: model.key)
                checked += 1
            }
            if !beyond.isEmpty {
                notes.append("\(beyond.count) models new or changed since library.json, checked against "
                             + "Scripts/mdl-reference.py run now: \(beyond.map(\.key).joined(separator: ", "))")
            }
        } else {
            if !changed.isEmpty {
                notes.append("\(changed.count) models changed since library.json NOT checked (no python3 to run "
                             + "Scripts/mdl-reference.py): \(changed.joined(separator: ", "))")
            }
            notes.append("models new since library.json not looked for: no python3 to run Scripts/mdl-reference.py")
        }
        if !removed.isEmpty {
            notes.append("\(removed.count) models of library.json no longer in the library, skipped: \(removed.joined(separator: ", "))")
        }
        if !notes.isEmpty { notes.append("Refresh the fixture: Scripts/mdl-reference.py library") }
        LibraryReport.attach("Models: beyond library.json", notes)
        try XCTSkipIf(checked == 0, "no library model found")
    }

    private static func digest(_ data: Data) -> String {
        Digest.hex(SHA256.hash(data: data))
    }
}
