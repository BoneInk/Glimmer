import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The browsers' previews: a cached one shows at once, a missing one is rendered once, in a
/// batch, and a failed one falls back to the symbol.
@MainActor
final class EditorPreviewProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "EditorPreviewProviderTests-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // Optional: a scratch folder.
    }

    private let tint = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
    private let rain = EditorPreviewSubject.particlePreset(directory: "/assets/presets/rain", variant: 0, is3D: false)
    private let broken = EditorPreviewSubject.effect(file: "effects/broken/effect.json", wallpaper: nil)

    func testPreviewsAreReadFromTheCacheOrRenderedOnce() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-1")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: cache.outputBase(for: tint).appendingPathExtension("heic"))
        let log = RenderLog()
        let broken = self.broken
        let provider = EditorPreviewProvider(cache: cache) { items, finished in
            await log.record(items.map(\.subject))
            for item in items where item.subject != broken {
                FileManager.default.createFile(atPath: item.outputBase.appendingPathExtension("mov").path(percentEncoded: false),
                                               contents: Data("mov".utf8))
                finished(item.subject)
            }
        }
        provider.request(tint)
        provider.request(rain)
        provider.request(broken)
        provider.request(rain)
        XCTAssertEqual(provider.state(of: rain), .generating, "a spinner meanwhile")
        try await waitUntil { [self] in
            provider.state(of: rain) != .generating && provider.state(of: broken) != .generating
                && provider.state(of: tint) != .generating
        }
        XCTAssertEqual(provider.state(of: tint), .ready(cache.outputBase(for: tint).appendingPathExtension("heic")))
        XCTAssertEqual(provider.state(of: rain), .ready(cache.outputBase(for: rain).appendingPathExtension("mov")))
        XCTAssertEqual(provider.state(of: broken), .failed)
        let batches = await log.batches
        XCTAssertEqual(Set(batches.flatMap { $0 }), [rain, broken], "a cached preview isn't rendered again")
        XCTAssertEqual(batches.flatMap { $0 }.count, 2, "each one once")
    }

    // MARK: Measuring a browser's open

    func testABrowsersOpenIsLoggedOnceItsTilesAreShown() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-1")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: cache.outputBase(for: tint).appendingPathExtension("heic"))
        let broken = self.broken
        let logs = LogLines()
        let provider = EditorPreviewProvider(cache: cache, renderer: { items, finished in
            for item in items where item.subject != broken {
                FileManager.default.createFile(atPath: item.outputBase.appendingPathExtension("mov").path(percentEncoded: false),
                                               contents: Data("mov".utf8))
                finished(item.subject)
            }
        }, log: { logs.lines.append($0) }, now: { logs.tick() })
        provider.beginOpen(.effects)
        provider.request(tint)
        provider.request(rain)
        provider.request(broken)
        try await waitUntil { !logs.lines.isEmpty }
        XCTAssertEqual(logs.lines, ["Add Effect opened in 0.25 s: 3 tiles shown, 1 cached, 1 rendered, 1 failed"])

        // A second open in the same window finds every tile shown already.
        provider.endOpen()
        provider.beginOpen(.effects)
        provider.request(tint)
        provider.request(rain)
        try await waitUntil { logs.lines.count == 2 }
        XCTAssertEqual(logs.lines.last, "Add Effect opened in 0.25 s: 2 tiles shown, 2 cached, 0 rendered, 0 failed")
    }

    func testABrowserClosedBeforeItsTilesAreShownSaysSo() {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-1")
        let logs = LogLines()
        let provider = EditorPreviewProvider(cache: cache, renderer: { _, _ in }, log: { logs.lines.append($0) })
        provider.beginOpen(.particleSystems)
        provider.request(rain)
        // Closed before the cache was even read.
        provider.endOpen()
        XCTAssertEqual(logs.lines.count, 1)
        XCTAssertTrue(logs.lines[0].hasPrefix("Add Particle System closed after "), logs.lines[0])
        XCTAssertTrue(logs.lines[0].hasSuffix(" with 1 of 1 tiles still rendering"), logs.lines[0])
    }

    func testNoOpenIsLoggedWithoutBeginOpen() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-1")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: cache.outputBase(for: tint).appendingPathExtension("heic"))
        let logs = LogLines()
        let provider = EditorPreviewProvider(cache: cache, renderer: { _, _ in }, log: { logs.lines.append($0) })
        provider.request(tint)
        try await waitUntil { provider.state(of: tint) != .generating }
        provider.endOpen()
        XCTAssertEqual(logs.lines, [])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor RenderLog {
    private(set) var batches: [[EditorPreviewSubject]] = []

    func record(_ batch: [EditorPreviewSubject]) { batches.append(batch) }
}

/// What a provider logged, and a clock that moves a quarter second each time it is read.
@MainActor
private final class LogLines {
    var lines: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_000)

    func tick() -> Date {
        clock.addTimeInterval(0.25)
        return clock
    }
}
