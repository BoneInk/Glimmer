import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// Fixtures live in `Tests/Fixtures` at the repository root, outside the test target, so they are
/// read from the source checkout instead of being flattened into the test bundle.
enum Fixtures {
    /// Fixture scene folders that aren't scenes to render: the one whose script hangs on purpose.
    /// Every test that walks `Scenes/` skips these.
    static let unrenderableScenes: Set<String> = ["scripted-hang"]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tests/Fixtures", directoryHint: .isDirectory)

    static func url(_ path: String) -> URL { root.appending(path: path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    /// A writable copy, for code under test that writes caches next to its input.
    static func temporaryCopy(of path: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "owe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url(path), to: destination)
        return destination
    }
}

extension Fixtures {
    /// Removes what loading the wallpaper in `directory` stores in the app's defaults (its settings,
    /// under its identity), so tests leave nothing behind.
    static func removeStoredSettings(for directory: URL) {
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        for family in WallpaperSettingsIdentity.Family.allCases {
            UserDefaults.app.removeObject(forKey: identity.key(family))
        }
    }

    /// The Wallpaper Engine assets named by `OWE_ASSETS` (`TEST_RUNNER_OWE_ASSETS` through
    /// xcodebuild): an assets folder or a WE install. The repository ships none, so tests that need
    /// them skip without it, as on CI.
    static func assets() throws -> URL {
        guard let directory = WallpaperEngineAssets.directory else {
            throw XCTSkip("needs Wallpaper Engine assets: set OWE_ASSETS to an assets folder or a WE install")
        }
        return directory
    }

    /// True when WE's effect shader sources are reachable (`OWE_ASSETS`). Tests that need an effect
    /// to plan skip without them.
    static var hasWEShaderSources: Bool {
        guard let assets = WallpaperEngineAssets.directory else { return false }
        return FileManager.default.fileExists(atPath: assets.appending(path: "effects/tint/shaders/effects/tint.frag").path)
    }
}
