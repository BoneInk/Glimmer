import CryptoKit
import XCTest
import OWEEditor
@testable import OpenWallpaperEngine

/// Installing Depth Map Generation with a fake download and a fake compiler (never the network,
/// never Core ML): the pinned commit and checksums, every file checked before it is kept, the
/// atomic install, pruning to two versions, cancel and remove, as the Chromium engine's.
final class DepthMapPluginInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-depthmaps-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var pluginRoot: URL { root.appending(path: "support/Plugins/DepthMaps", directoryHint: .isDirectory) }

    private static let files: [String: Data] = [
        "Manifest.json": Data(#"{"fileFormatVersion":"1.0.0"}"#.utf8),
        "Data/com.apple.CoreML/model.mlmodel": Data("spec".utf8),
        "Data/com.apple.CoreML/weights/weight.bin": Data(repeating: 7, count: 4096),
    ]

    private static func sha256(_ data: Data) -> String {
        Digest.hex(SHA256.hash(data: data))
    }

    private func pin(revision: String = String(repeating: "a", count: 40)) -> DepthMapModelPin {
        DepthMapModelPin(revision: revision, packageName: "DepthAnythingV2SmallF16.mlpackage",
                         files: Self.files.keys.sorted().map { path in
                             DepthMapModelPin.File(path: path, sha256: Self.sha256(Self.files[path]!), size: Int64(Self.files[path]!.count))
                         })
    }

    @MainActor
    private func makeInstaller(pin: DepthMapModelPin, downloader: SteamCmdPackageDownloading = FakeFileServer(files: DepthMapPluginInstallerTests.files),
                               compiler: FakeCompiler = FakeCompiler()) -> DepthMapPluginInstaller {
        let scratch = root.appending(path: "compiled", directoryHint: .isDirectory)
        return DepthMapPluginInstaller(root: pluginRoot, pin: pin, downloader: downloader,
                                       compile: { try compiler.compile($0, into: scratch) },
                                       trash: { try FileManager.default.removeItem(at: $0) })
    }

    @MainActor
    private func install(_ pin: DepthMapModelPin) async -> DepthMapPluginInstaller {
        let installer = makeInstaller(pin: pin)
        installer.install()
        await installer.wait()
        return installer
    }

    private func entries(hidden: Bool = false) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pluginRoot.path)) ?? [])
            .filter { hidden ? $0.hasPrefix(DepthMapPluginLayout.stagingPrefix) : !$0.hasPrefix(".") }.sorted()
    }

    // MARK: The pin

    func testThePinnedModelIsApplesSmallPackageAtACommit() throws {
        let pin = DepthMapModelPin.pinned
        #if DEBUG
        if pin.isPlaceholder { throw XCTSkip("the pin is a placeholder; a Release build fails here") }
        #endif
        XCTAssertFalse(pin.isPlaceholder, "a release must pin a real commit and real checksums")
        XCTAssertEqual(DepthMapModelPin.repository, "apple/coreml-depth-anything-v2-small")
        XCTAssertEqual(pin.packageName, "DepthAnythingV2SmallF16.mlpackage", "Small only: Base and Large aren't Apache-2.0")
        XCTAssertEqual(pin.revision.count, 40)
        XCTAssertNotNil(pin.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression), "a commit, never main")
        XCTAssertEqual(Set(pin.files.map(\.path)), ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                                                    "Data/com.apple.CoreML/weights/weight.bin"])
        for file in pin.files {
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression), file.path)
            XCTAssertGreaterThan(file.size, 0)
            let url = pin.downloadURL(for: file).absoluteString
            XCTAssertEqual(url, "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/\(pin.revision)/DepthAnythingV2SmallF16.mlpackage/\(file.path)")
        }
        XCTAssertGreaterThan(pin.downloadSize, 40_000_000)
    }

    func testAPlaceholderIsRecognised() {
        let placeholder = DepthMapModelPin(revision: String(repeating: "0", count: 40), packageName: "x.mlpackage",
                                           files: [.init(path: "Manifest.json", sha256: DepthMapModelPin.placeholderSHA256, size: 1)])
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertTrue(DepthMapModelPin(revision: "main", packageName: "x", files: pin().files).isPlaceholder)
        XCTAssertFalse(pin().isPlaceholder)
    }

    func testIsolatedCopiesHaveTheirOwnPluginFolder() {
        let path = DepthMapPluginInstaller.defaultRoot.path
        XCTAssertTrue(path.hasSuffix("Plugins/DepthMaps"), path)
        XCTAssertTrue(path.contains("(isolated tests)"), "tests never touch the user's plugin: \(path)")
    }

    // MARK: Installing

    @MainActor
    func testInstallChecksEveryFileCompilesAndCommits() async throws {
        let pin = pin()
        let server = FakeFileServer(files: Self.files)
        let compiler = FakeCompiler()
        let installer = makeInstaller(pin: pin, downloader: server, compiler: compiler)
        XCTAssertNil(installer.installedVersion)
        installer.install()
        await installer.wait()

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertEqual(installer.installedVersion, pin.version)
        XCTAssertTrue(installer.isCurrent)
        XCTAssertNotNil(installer.installedSize)
        XCTAssertEqual(Set(server.requested.map(\.lastPathComponent)), ["Manifest.json", "model.mlmodel", "weight.bin"])
        XCTAssertTrue(server.requested.allSatisfy { $0.absoluteString.contains("/resolve/\(pin.revision)/") })
        XCTAssertEqual(compiler.compiled.count, 1)
        XCTAssertEqual(compiler.compiled.first?.lastPathComponent, "DepthAnythingV2SmallF16.mlpackage")
        XCTAssertEqual(compiler.assembledFiles, Set(Self.files.keys), "the package is assembled before it is compiled")

        let folder = pluginRoot.appending(path: pin.version, directoryHint: .isDirectory)
        let manifest = try XCTUnwrap(DepthMapPluginLayout.manifest(in: folder))
        XCTAssertEqual(manifest.revision, pin.revision)
        XCTAssertEqual(manifest.files, Dictionary(uniqueKeysWithValues: pin.files.map { ($0.path, $0.sha256) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: DepthMapPluginLayout.compiledModelName).path))
        let notice = try String(contentsOf: folder.appending(path: DepthMapPluginLayout.noticeName), encoding: .utf8)
        XCTAssertTrue(notice.contains("Apache License, Version 2.0"))
        XCTAssertEqual(entries(), [pin.version])
        XCTAssertEqual(entries(hidden: true), [], "no staging left")

        // What a generator reads, in this process or the editor's.
        let active = try XCTUnwrap(DepthMapPluginLayout.activeModel(in: pluginRoot))
        XCTAssertEqual(active.version, pin.version)
        XCTAssertEqual(active.url.lastPathComponent, DepthMapPluginLayout.compiledModelName)
    }

    @MainActor
    func testAMismatchedFileInstallsNothing() async throws {
        var files = Self.files
        files["Data/com.apple.CoreML/weights/weight.bin"] = Data(repeating: 8, count: 4096)
        let compiler = FakeCompiler()
        let installer = makeInstaller(pin: pin(), downloader: FakeFileServer(files: files), compiler: compiler)
        installer.install()
        await installer.wait()
        guard case .failed = installer.phase else { return XCTFail("installed a file that doesn't match its pin") }
        XCTAssertNil(installer.installedVersion)
        XCTAssertEqual(compiler.compiled, [], "nothing unverified is compiled")
        XCTAssertEqual(entries(), [])
        XCTAssertEqual(entries(hidden: true), [])
        XCTAssertNil(DepthMapPluginLayout.activeModel(in: pluginRoot))
    }

    @MainActor
    func testACompileFailureInstallsNothing() async throws {
        let compiler = FakeCompiler()
        compiler.fails = true
        let installer = makeInstaller(pin: pin(), compiler: compiler)
        installer.install()
        await installer.wait()
        guard case .failed = installer.phase else { return XCTFail("installed a model that didn't compile") }
        XCTAssertEqual(entries(), [])
        XCTAssertEqual(entries(hidden: true), [])
    }

    @MainActor
    func testUpdatesKeepTheActiveAndThePreviousVersion() async throws {
        let first = pin(revision: String(repeating: "1", count: 40))
        let second = pin(revision: String(repeating: "2", count: 40))
        let third = pin(revision: String(repeating: "3", count: 40))
        _ = await install(first)
        let older = makeInstaller(pin: second)
        XCTAssertTrue(older.needsUpdate, "a release pinning another commit offers Update")
        older.update()
        await older.wait()
        _ = await install(third)
        XCTAssertEqual(entries(), [second.version, third.version].sorted())
        let state = DepthMapPluginLayout.State.read(in: pluginRoot)
        XCTAssertEqual(state.active, third.version)
        XCTAssertEqual(state.previous, second.version)
    }

    @MainActor
    func testReinstallingTheSameVersionReplacesItInPlace() async throws {
        let pin = pin()
        _ = await install(pin)
        let installer = await install(pin)
        XCTAssertEqual(installer.phase, .installed)
        XCTAssertEqual(entries(), [pin.version])
        XCTAssertEqual(DepthMapPluginLayout.State.read(in: pluginRoot).previous, nil)
    }

    @MainActor
    func testCancelLeavesNothingBehind() async throws {
        let installer = makeInstaller(pin: pin(), downloader: HangingFileServer())
        installer.install()
        try await Task.sleep(nanoseconds: 50_000_000)
        installer.cancel()
        await installer.wait()
        XCTAssertEqual(installer.phase, .idle)
        XCTAssertNil(installer.installedVersion)
        XCTAssertEqual(entries(), [])
        XCTAssertEqual(entries(hidden: true), [])
    }

    @MainActor
    func testRemoveTakesEveryVersion() async throws {
        let installer = await install(pin())
        try installer.remove()
        XCTAssertNil(installer.installedVersion)
        XCTAssertNil(installer.installedSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.path))
        XCTAssertNil(DepthMapPluginLayout.activeModel(in: pluginRoot))
    }

    func testOfflineHTTPAndDiskFullErrorsSaySo() {
        XCTAssertTrue(DepthMapPluginInstaller.message(for: URLError(.notConnectedToInternet)).contains("Hugging Face"))
        XCTAssertTrue(DepthMapPluginInstaller.message(for: URLSessionSteamCmdDownloader.Failure.httpStatus(404)).contains("404"))
        let diskFull = DepthMapPluginInstaller.message(for: CocoaError(.fileWriteOutOfSpace))
        XCTAssertTrue(diskFull.contains("disk space"), diskFull)
        XCTAssertEqual(DepthMapPluginInstaller.message(for: URLError(.cannotWriteToFile)), diskFull,
                       "a download that can't be written is a full disk, as for the Chromium engine")
    }

    @MainActor
    func testAMismatchedFileSaysWhichDownloadWasWrong() async throws {
        var files = Self.files
        files["Manifest.json"] = Data("tampered".utf8)
        let installer = makeInstaller(pin: pin(), downloader: FakeFileServer(files: files))
        installer.install()
        await installer.wait()
        let mismatch = DepthMapPluginInstallJob.Failure.checksumMismatch(path: "Manifest.json").localizedDescription
        XCTAssertEqual(installer.phase, .failed(mismatch))
    }
}

/// Serves `files` by their path inside the package, and records what was asked for.
private final class FakeFileServer: SteamCmdPackageDownloading, @unchecked Sendable {
    let files: [String: Data]
    private let lock = NSLock()
    private var _requested: [URL] = []
    var requested: [URL] { lock.withLock { _requested } }

    init(files: [String: Data]) {
        self.files = files
    }

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        lock.withLock { _requested.append(url) }
        guard let (_, data) = files.first(where: { url.path.hasSuffix("/" + $0.key) }) else { throw URLError(.fileDoesNotExist) }
        progress(0.5)
        try data.write(to: destination)
        progress(1)
    }
}

private struct HangingFileServer: SteamCmdPackageDownloading {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Stands in for `MLModel.compileModel`: an `.mlmodelc` folder next to nothing it was given.
private final class FakeCompiler: @unchecked Sendable {
    private let lock = NSLock()
    private var _compiled: [URL] = []
    private var _assembled: Set<String> = []
    var fails = false
    var compiled: [URL] { lock.withLock { _compiled } }
    var assembledFiles: Set<String> { lock.withLock { _assembled } }

    struct Failure: Error {}

    func compile(_ package: URL, into scratch: URL) throws -> URL {
        if fails { throw Failure() }
        var found = Set<String>()
        let root = package.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.insert(String(url.standardizedFileURL.path.dropFirst(root.count + 1)))
            }
        }
        lock.withLock {
            _compiled.append(package)
            _assembled = found
        }
        let output = scratch.appending(path: "\(UUID().uuidString)/DepthAnythingV2SmallF16.mlmodelc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: output.appending(path: "model.mil"))
        return output
    }
}
