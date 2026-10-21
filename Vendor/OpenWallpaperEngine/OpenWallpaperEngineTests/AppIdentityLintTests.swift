import XCTest
@testable import OpenWallpaperEngine

/// The app's identity: every target's bundle id is under `app.openwallpaperengine`, the code agrees
/// with the project, and the old bundle id and the old site are gone from the repository except
/// where the migration needs them.
final class AppIdentityLintTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let appIdentifier = "app.openwallpaperengine"

    /// What the lint scans: the sources, tests, scripts, workflows, docs and the site.
    static let scannedRoots = ["OpenWallpaperEngine", "OpenWallpaperEngineApp", "OpenWallpaperEngineSaver",
                               "OpenWallpaperEngineTests", "OWEChromiumHelper", "EditorHelper", "MCPServer",
                               "Packages", "Scripts", "Tests", "docs", "site", "resources", ".github",
                               "OpenWallpaperEngine.xcodeproj"]
    static let scannedExtensions: Set<String> = ["swift", "m", "h", "mm", "c", "plist", "pbxproj", "entitlements",
                                                 "md", "yml", "yaml", "py", "sh", "html", "xml", "json", "js",
                                                 "css", "txt", "xcstrings", "xcscheme"]
    static let skippedFolders: Set<String> = [".build", "build", "DerivedData", "node_modules"]

    // MARK: Bundle ids

    func testEveryTargetIsUnderTheAppIdentifier() throws {
        let project = try String(contentsOf: Self.repository.appending(path: "OpenWallpaperEngine.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;"#)
        let identifiers = Set(pattern.matches(in: project, range: NSRange(project.startIndex..., in: project)).compactMap {
            Range($0.range(at: 1), in: project).map { String(project[$0]) }
        })
        let app = Self.appIdentifier
        XCTAssertEqual(identifiers, [app, "\(app).editor", "\(app).saver", "\(app).chromium.helper", "\(app).mcp",
                                     "\(app).framework", "\(app).tests", "\(app).saver-extension", "\(app).saver-broker"])
        // CEF's helper apps, renamed by the build script.
        XCTAssertTrue(project.contains("\(app).chromium.helper${SUFFIX:+.$SUFFIX}.app"))
    }

    func testTheCodeAgreesWithTheProject() {
        let app = Self.appIdentifier
        XCTAssertEqual(Bundle.main.bundleIdentifier, app, "the test host is the app")
        XCTAssertEqual(AppStorageLocation.realBundleIdentifier, app)
        XCTAssertEqual(AppBundleLayout.editorIdentifier(for: app), "\(app).editor")
        XCTAssertEqual(ChromiumHelperIPC.serviceName, "\(app).chromium.helper")
        XCTAssertEqual(OWESignpost.subsystem, app)
        XCTAssertEqual(AppStorageLocation.current.appCachesDirectory.lastPathComponent, app)
        XCTAssertEqual(AppProcessChannel(isolationTag: nil).prefix, app)
    }

    func testTheBuiltBundlesCarryTheirIdentifiers() throws {
        let app = Bundle.main.bundleURL
        let editor = AppBundleLayout.editorURL(inApp: app)
        guard FileManager.default.fileExists(atPath: editor.path(percentEncoded: false)) else {
            throw XCTSkip("This build has no Wallpaper Editor app")
        }
        XCTAssertEqual(Bundle(url: editor)?.bundleIdentifier, "\(Self.appIdentifier).editor")
        let saver = Bundle.main.resourceURL?.appending(path: ScreenSaverInstaller.saverName, directoryHint: .isDirectory)
        if let saver, FileManager.default.fileExists(atPath: saver.path(percentEncoded: false)) {
            XCTAssertEqual(Bundle(url: saver)?.bundleIdentifier, "\(Self.appIdentifier).saver")
        }
    }

    // MARK: Leftovers

    /// The old bundle id appears only in the migration that moves away from it.
    func testTheOldBundleIdentifierIsOnlyInTheMigration() throws {
        // Built from pieces, so this file doesn't match itself.
        let old = ["com", "winddog"].joined(separator: ".")
        let allowed: Set<String> = ["OpenWallpaperEngine/App/IdentityMigration/AppIdentityMigration.swift"]
        XCTAssertEqual(AppIdentityMigration.legacyBundleIdentifier.lowercased().hasPrefix(old), true)
        let hits = try occurrences(of: old).filter { !allowed.contains($0.file) }
        XCTAssertTrue(hits.isEmpty, "The old bundle id outside the migration:\n" + hits.map(\.description).joined(separator: "\n"))
    }

    /// Links go to openwallpaperengine.app; only the releasing guide names the old Pages address,
    /// which now redirects there.
    func testTheOldSiteAddressIsGone() throws {
        let old = ["deepratna-awale", "github", "io"].joined(separator: ".")
        let hits = try occurrences(of: old).filter { $0.file != "docs/releasing.md" }
        XCTAssertTrue(hits.isEmpty, "The old site address:\n" + hits.map(\.description).joined(separator: "\n"))
    }

    private struct Occurrence: CustomStringConvertible {
        let file: String
        let line: Int
        var description: String { "\(file):\(line)" }
    }

    private func occurrences(of needle: String) throws -> [Occurrence] {
        var hits: [Occurrence] = []
        for file in try scannedFiles() {
            let url = Self.repository.appending(path: file)
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                continue // Not UTF-8 text (a binary resource with a text extension).
            }
            guard text.range(of: needle, options: .caseInsensitive) != nil else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.range(of: needle, options: .caseInsensitive) != nil {
                hits.append(Occurrence(file: file, line: index + 1))
            }
        }
        return hits
    }

    private func scannedFiles() throws -> [String] {
        var files = ["README.md", "CONTRIBUTING.md", "CHANGELOG.md", "SECURITY.md", "AUTHORS.md",
                     "OpenWallpaperEngine-Info.plist"]
        let manager = FileManager.default
        let repositoryDepth = Self.repository.standardizedFileURL.pathComponents.count
        for root in Self.scannedRoots {
            let url = Self.repository.appending(path: root, directoryHint: .isDirectory)
            guard let walker = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let item as URL in walker {
                if Self.skippedFolders.contains(item.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                guard Self.scannedExtensions.contains(item.pathExtension.lowercased()) else { continue }
                files.append(item.standardizedFileURL.pathComponents.dropFirst(repositoryDepth).joined(separator: "/"))
            }
        }
        return files.filter { manager.fileExists(atPath: Self.repository.appending(path: $0).path(percentEncoded: false)) }
    }
}
