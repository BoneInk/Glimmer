import XCTest
import CryptoKit
@testable import OpenWallpaperEngine

/// Shader and pipeline caches are keyed on `ShaderVariantTranslator.revision` (plus the toolchain,
/// device and OS build), never on the app version. This fails when translated MSL changes while the
/// revision stays the same, so users never keep stale variants across an update.
///
/// The expected pair lives in `Tests/Fixtures/ShaderRevision/expected.json`. Re-record with
/// `OWE_RECORD_SHADER_HASH=1` (see CONTRIBUTING.md, rule 6).
final class ShaderRevisionGuardTests: XCTestCase {
    private struct Expected: Codable, Equatable {
        var revision: Int
        var hash: String
        var assetsHash: String?
        /// The WE assets' own shader sources the assets hash was recorded from. A new Wallpaper Engine
        /// build changes these; its hash then can't be compared and needs re-recording, not a bump.
        var assetsSourcesHash: String?
    }

    private struct Job {
        let root: URL
        let path: String
        let combos: [String: Int]?
    }

    private static let fixtureURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/ShaderRevision/expected.json")

    private static let recordCommand: String = """
        OWE_RECORD_SHADER_HASH=1 (through xcodebuild: TEST_RUNNER_OWE_RECORD_SHADER_HASH=1 \
        TEST_RUNNER_OWE_ASSETS=<assets folder> xcodebuild test -project OpenWallpaperEngine.xcodeproj \
        -scheme OpenWallpaperEngine -destination 'platform=macOS' \
        -only-testing:OpenWallpaperEngineTests/ShaderRevisionGuardTests), then commit \
        Tests/Fixtures/ShaderRevision/expected.json
        """

    private static var recording: Bool {
        ProcessInfo.processInfo.environment["OWE_RECORD_SHADER_HASH"] == "1"
    }

    /// Every vert/frag pair under `root` (relative paths, sorted).
    private static func pairs(under root: URL) -> [String] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var paths: [String] = []
        let base: String = root.standardizedFileURL.path
        for case let url as URL in files where url.pathExtension == "vert" {
            let fragment: URL = url.deletingPathExtension().appendingPathExtension("frag")
            guard FileManager.default.fileExists(atPath: fragment.path) else { continue }
            let full: String = url.deletingPathExtension().standardizedFileURL.path
            paths.append(String(full.dropFirst(base.count + 1)))
        }
        return paths.sorted()
    }

    /// Hashes the MSL, uniform layout, texture slots and attributes of each pair with its default
    /// combos and with each declared combo switched on by itself. A pair whose includes can't be
    /// found contributes only that.  Only relative paths go in.
    private static func corpusHash(root: URL, includeRoots: [URL]) throws -> (hash: String, count: Int) {
        let loader = ShaderSourceLoader(roots: [root] + includeRoots)
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        var hasher = SHA256()
        var count: Int = 0
        for path in pairs(under: root) {
            // Optional: a fixture that includes WE's own headers can't load without them.
            guard let vertex = try? loader.load(path, stage: .vertex),
                  let fragment = try? loader.load(path, stage: .fragment) else {
                hasher.update(data: Data("\(path)|unloadable\u{0}".utf8))
                continue
            }
            let defaults: [String: Int] = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                                                 overrides: [], boundTextureSlots: [0])
            var comboSets: [[String: Int]] = [defaults]
            for combo in Set((vertex.combos + fragment.combos).map(\.name)).sorted() where defaults[combo] != 1 {
                var combos: [String: Int] = defaults
                combos[combo] = 1
                comboSets.append(combos)
            }
            for combos in comboSets {
                hasher.update(data: Data("\(path)|\(combos.sorted { $0.key < $1.key })\u{0}".utf8))
                // Optional: a pair that fails to translate contributes that it failed.
                guard let variant = try? translator.variant(vertex: vertex, fragment: fragment, combos: combos) else {
                    hasher.update(data: Data("failed\u{0}".utf8))
                    continue
                }
                hasher.update(data: Data(variant.vertexMSL.utf8))
                hasher.update(data: Data("\u{0}".utf8))
                hasher.update(data: Data(variant.fragmentMSL.utf8))
                hasher.update(data: Data("\u{0}".utf8))
                for (name, member) in (variant.uniforms?.members ?? [:]).sorted(by: { $0.key < $1.key }) {
                    hasher.update(data: Data("\(name):\(member.type):\(member.offset):\(member.count)\u{0}".utf8))
                }
                let attributes: [(key: String, value: Int)] = variant.attributes.sorted { $0.key < $1.key }
                hasher.update(data: Data("\(variant.textureSlots)\(attributes)\u{0}".utf8))
                count += 1
            }
        }
        let hash: String = Digest.hex(hasher.finalize())
        return (hash, count)
    }

    /// Fixture shaders shipped in the repository: runs everywhere, CI included.
    private static func baseHash() throws -> (hash: String, count: Int) {
        let fixtures: URL = Fixtures.url("")
        return try corpusHash(root: fixtures, includeRoots: [Fixtures.url("ShaderAssets")])
    }

    /// Every pair in WE's assets (`OWE_ASSETS`); nil without them.
    private static func assetsHash() throws -> (hash: String, count: Int)? {
        guard let assets = try? Fixtures.assets() else { return nil }
        return try corpusHash(root: assets, includeRoots: [])
    }

    /// The raw shader sources under `root` (paths and contents, sorted): what the translator reads.
    private static func sourcesHash(root: URL) -> String {
        var hasher = SHA256()
        let base: String = root.standardizedFileURL.path
        var files: [URL] = []
        if let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in all where ["vert", "frag", "geom", "h"].contains(url.pathExtension) {
                files.append(url)
            }
        }
        for url in files.sorted(by: { $0.path < $1.path }) {
            let relative: String = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            hasher.update(data: Data("\(relative)\u{0}".utf8))
            hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
        }
        return Digest.hex(hasher.finalize())
    }

    private static func loadExpected() throws -> Expected {
        let data: Data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    func testTranslatedOutputChangesOnlyWithARevisionBump() throws {
        let revision: Int = ShaderVariantTranslator.revision
        let base: (hash: String, count: Int) = try Self.baseHash()
        XCTAssertGreaterThan(base.count, 10, "the base corpus translated too few variants")
        let assets: (hash: String, count: Int)? = try Self.assetsHash()

        if Self.recording {
            let previous: Expected? = try? Self.loadExpected()
            // Without assets, keep the recorded assets hash only if the revision is unchanged.
            let keptAssets: String? = previous?.revision == revision ? previous?.assetsHash : nil
            let keptSources: String? = previous?.revision == revision ? previous?.assetsSourcesHash : nil
            let sources: String? = (try? Fixtures.assets()).map(Self.sourcesHash(root:))
            let expected = Expected(revision: revision, hash: base.hash, assetsHash: assets?.hash ?? keptAssets,
                                    assetsSourcesHash: assets == nil ? keptSources : sources)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data: Data = try encoder.encode(expected)
            data.append(Data("\n".utf8))
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL, options: .atomic)
            throw XCTSkip("recorded revision \(revision), hash \(base.hash) (\(base.count) variants)"
                + (assets.map { ", assetsHash \($0.hash) (\($0.count) variants)" } ?? ", no assets: assetsHash "
                    + (keptAssets == nil ? "cleared" : "kept")) + " to \(Self.fixtureURL.path)")
        }

        let expected: Expected = try Self.loadExpected()
        guard expected.revision == revision else {
            XCTFail("""
                ShaderVariantTranslator.revision is \(revision) but \(Self.fixtureURL.lastPathComponent) records \
                \(expected.revision): the revision and the translated-output hash move together. Re-record with \
                \(Self.recordCommand)
                """)
            return
        }
        XCTAssertEqual(base.hash, expected.hash, """
            Translated shader output changed: bump ShaderVariantTranslator.revision and re-record: \
            \(Self.recordCommand). A new or changed fixture shader under Tests/Fixtures changes this hash \
            without any translator change: then re-record without a bump.
            """)
        if let assets {
            let sources: String = Self.sourcesHash(root: try Fixtures.assets())
            if let recordedSources = expected.assetsSourcesHash, recordedSources != sources {
                // A different Wallpaper Engine build: its shaders differ, so the output does too.
                print("ShaderRevisionGuardTests: the WE assets differ from the recorded ones; re-record: \(Self.recordCommand)")
                return
            }
            if let recorded = expected.assetsHash {
                XCTAssertEqual(assets.hash, recorded, """
                    Translated shader output of the WE assets changed: bump ShaderVariantTranslator.revision and \
                    re-record: \(Self.recordCommand)
                    """)
            } else {
                XCTFail("expected.json has no assetsHash for revision \(revision): re-record with assets: \(Self.recordCommand)")
            }
        }
    }

    /// Two runs over the base corpus hash the same: nothing machine- or time-dependent reaches it.
    func testBaseCorpusHashIsDeterministic() throws {
        let first: String = try Self.baseHash().hash
        let second: String = try Self.baseHash().hash
        XCTAssertEqual(first, second)
    }
}
