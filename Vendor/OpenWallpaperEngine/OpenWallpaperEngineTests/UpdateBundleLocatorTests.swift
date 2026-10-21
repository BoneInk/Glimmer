import XCTest
@testable import OpenWallpaperEngine

/// The extracted update is found in Sparkle's installation cache by identifier and version.
final class UpdateBundleLocatorTests: XCTestCase {
    static func makeBundle(at url: URL, identifier: String, version: String) throws {
        let macOS = url.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleVersion": version, "CFBundleExecutable": "App"]
        try info.write(to: url.appending(path: "Contents/Info.plist"))
        let executable = macOS.appending(path: "App")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func testFindsTheBundleOfTheVersionInSparklesCache() throws {
        let caches = FileManager.default.temporaryDirectory.appending(path: "owe-locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) } // Optional: cleanup of a temp folder.
        let locator = UpdateBundleLocator(bundleIdentifier: "com.example.app", cachesDirectory: caches)
        XCTAssertEqual(locator.installationDirectory.path,
                       caches.appending(path: "com.example.app/org.sparkle-project.Sparkle/Installation").path)
        XCTAssertNil(locator.bundle(version: "42"), "no cache yet")
        let installation = locator.installationDirectory
        let wanted = installation.appending(path: "AbCdEf123/XyZ987/Example.app")
        try Self.makeBundle(at: wanted, identifier: "com.example.app", version: "42")
        try Self.makeBundle(at: installation.appending(path: "Old111/Old222/Example.app"), identifier: "com.example.app", version: "41")
        try Self.makeBundle(at: installation.appending(path: "Other1/Other2/Other.app"), identifier: "com.other.app", version: "42")
        XCTAssertEqual(locator.bundle(version: "42")?.standardizedFileURL, wanted.standardizedFileURL)
        XCTAssertNil(locator.bundle(version: "43"))
        XCTAssertEqual(UpdateBundleLocator.executable(of: wanted)?.lastPathComponent, "App")
    }
}
