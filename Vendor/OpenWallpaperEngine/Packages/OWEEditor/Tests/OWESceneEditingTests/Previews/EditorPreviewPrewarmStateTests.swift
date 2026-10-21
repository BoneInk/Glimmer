import XCTest
@testable import OWESceneEditing

/// The background pre-warm's state on disk and in order: the queue (catalog order, visible tiles
/// first), the inputs' fingerprints and carrying previews over to a new assets build (only what
/// changed renders again), the editor's requests and the lock.
final class EditorPreviewPrewarmStateTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // Optional: a scratch folder.
    }

    private let tint = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
    private let blur = EditorPreviewSubject.effect(file: "effects/blur/effect.json", wallpaper: nil)
    private let rain = EditorPreviewSubject.particlePreset(directory: "/assets/presets/rain", variant: 0, is3D: false)
    private let example = EditorPreviewSubject.particleSystem(path: "particles/example.json", is3D: false)

    // MARK: Queue

    func testTheQueueKeepsTheCatalogsOrderAndSkipsWhatIsDone() {
        var queue = EditorPreviewPrewarmQueue([tint, blur, tint, example, rain])
        XCTAssertEqual(queue.count, 4, "a subject is queued once")
        XCTAssertEqual(queue.next { _, _ in true }?.subject, tint)
        XCTAssertEqual(queue.next { subject, _ in subject != blur }?.subject, example, "a preview cached meanwhile is skipped")
        XCTAssertEqual(queue.next { _, _ in true }?.subject, rain)
        XCTAssertNil(queue.next { _, _ in true }?.subject)
        XCTAssertTrue(queue.isEmpty)
    }

    func testABrowsersTilesJumpTheQueueTheLatestFirst() {
        var queue = EditorPreviewPrewarmQueue([tint, blur, example, rain])
        let workshop = EditorPreviewSubject.effect(file: "effects/workshop/1/x/effect.json", wallpaper: "/w/1")
        queue.prioritize([rain, example])
        queue.prioritize([workshop, rain])
        var order: [EditorPreviewSubject] = []
        var urgent: [Bool] = []
        while let next = queue.next(where: { _, _ in true }) {
            order.append(next.subject)
            urgent.append(next.isUrgent)
        }
        XCTAssertEqual(order, [workshop, rain, example, tint, blur],
                       "the latest request first, then the earlier one's rest, then the catalog; a Workshop effect is added")
        XCTAssertEqual(urgent, [true, true, true, false, false])
    }

    func testAPausedLanesSubjectGoesBackToTheFront() throws {
        var queue = EditorPreviewPrewarmQueue([tint, blur])
        let first = queue.next { _, _ in true }?.subject
        queue.putBack(try XCTUnwrap(first))
        XCTAssertEqual(queue.next { _, _ in true }?.subject, tint)
        XCTAssertEqual(queue.next { _, _ in true }?.subject, blur)
    }

    // MARK: Fingerprints

    func testOnlyAChangedInputChangesAFingerprint() throws {
        let assets = try assetsTree()
        let subjects = [tint, blur, example, preset(in: assets)]
        let before = EditorPreviewInputs.fingerprints(of: subjects, assets: assets)
        XCTAssertEqual(before.count, 4)
        XCTAssertEqual(EditorPreviewInputs.fingerprints(of: subjects, assets: assets), before, "stable")
        XCTAssertNil(EditorPreviewInputs.fingerprints(of: [.effect(file: "effects/x/effect.json", wallpaper: "/w")], assets: assets).first,
                     "a Workshop effect reads its wallpaper, not the assets")
        XCTAssertTrue(before[tint]!.hasPrefix("r\(EditorPreviewCache.effectRevision)-"))
        XCTAssertTrue(before[example]!.hasPrefix("r\(EditorPreviewCache.particleRevision)-"))

        try write("changed", to: "effects/tint/shaders/effects/tint.frag", in: assets)
        let ownChange = EditorPreviewInputs.fingerprints(of: subjects, assets: assets)
        XCTAssertNotEqual(ownChange[tint], before[tint], "the effect's own file changed")
        XCTAssertEqual(ownChange[blur], before[blur])
        XCTAssertEqual(ownChange[example], before[example])

        try write("changed", to: "materials/particle/halo.json", in: assets)
        let particleShared = EditorPreviewInputs.fingerprints(of: subjects, assets: assets)
        XCTAssertEqual(particleShared[blur], ownChange[blur], "effects don't read the particles' materials")
        XCTAssertNotEqual(particleShared[example], ownChange[example])
        XCTAssertNotEqual(particleShared[preset(in: assets)], ownChange[preset(in: assets)])

        try write("// new include", to: "shaders/common.h", in: assets)
        let includes = EditorPreviewInputs.fingerprints(of: subjects, assets: assets)
        XCTAssertNotEqual(includes[blur], particleShared[blur], "every effect reads the shared includes")
    }

    // MARK: Carrying previews over

    func testANewAssetsBuildCarriesOverOnlyTheUnchangedPreviews() throws {
        let old = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        try FileManager.default.createDirectory(at: old.directory, withIntermediateDirectories: true)
        for (subject, fileExtension) in [(tint, "heic"), (blur, "heic"), (example, "mov")] {
            try Data(fileExtension.utf8).write(to: old.outputBase(for: subject).appendingPathExtension(fileExtension))
        }
        try old.record([tint.cacheName: .init(fingerprint: "r2-a"), blur.cacheName: .init(fingerprint: "r2-b"),
                        example.cacheName: .init(fingerprint: "r2-c"), rain.cacheName: .init(fingerprint: "r2-d", failedAt: Date())])
        XCTAssertEqual(old.inputs()[tint.cacheName]?.fingerprint, "r2-a")

        let new = EditorPreviewCache(cachesDirectory: scratch, build: "steam-8")
        let carried = try new.carryOver([tint: "r2-a", blur: "r2-changed", example: "r2-c", rain: "r2-d"])
        XCTAssertEqual(carried, [tint, example])
        XCTAssertEqual(new.cachedPreview(for: tint)?.pathExtension, "heic")
        XCTAssertEqual(new.cachedPreview(for: example)?.pathExtension, "mov")
        XCTAssertNil(new.cachedPreview(for: blur), "its inputs changed: rendered again")
        XCTAssertEqual(new.inputs()[tint.cacheName]?.fingerprint, "r2-a")
        XCTAssertNotNil(new.inputs()[rain.cacheName]?.failedAt, "a failure with the same inputs isn't tried again")
        XCTAssertNil(new.inputs()[blur.cacheName])

        try new.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path(percentEncoded: false)))
        XCTAssertNotNil(new.cachedPreview(for: tint))
    }

    func testAFolderWithoutRecordsCarriesNothingOver() throws {
        let old = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        try FileManager.default.createDirectory(at: old.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: old.outputBase(for: tint).appendingPathExtension("heic"))
        let new = EditorPreviewCache(cachesDirectory: scratch, build: "steam-8")
        XCTAssertEqual(try new.carryOver([tint: "r2-a"]), [])
        XCTAssertNil(new.cachedPreview(for: tint))
    }

    func testTheRevisionNamesBothKinds() {
        XCTAssertEqual(EditorPreviewCache.revision, "\(EditorPreviewCache.effectRevision).\(EditorPreviewCache.particleRevision)")
        XCTAssertEqual(EditorPreviewCache.revision(of: tint), EditorPreviewCache.effectRevision)
        XCTAssertEqual(EditorPreviewCache.revision(of: rain), EditorPreviewCache.particleRevision)
    }

    // MARK: Requests and the lock

    func testRequestsAreTakenOnceTheLatestFirst() throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        let wants = EditorPreviewWants(cache: cache)
        XCTAssertEqual(wants.take(), [])
        try wants.post([tint, blur], at: Date(timeIntervalSince1970: 100))
        try wants.post([rain], at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(wants.take(), [rain, tint, blur])
        XCTAssertEqual(wants.take(), [], "taken once")
    }

    func testTheLockIsSeenHeldOnlyWhileItIsHeld() {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        XCTAssertFalse(EditorPreviewPrewarmLock.isHeld(for: cache))
        let lock = EditorPreviewPrewarmLock(cache: cache)
        XCTAssertTrue(lock.lock())
        XCTAssertTrue(EditorPreviewPrewarmLock.isHeld(for: cache))
        XCTAssertFalse(EditorPreviewPrewarmLock(cache: cache).lock(), "one pre-warm at a time")
        lock.unlock()
        XCTAssertFalse(EditorPreviewPrewarmLock.isHeld(for: cache))
    }

    // MARK: Fixtures

    private func preset(in assets: URL) -> EditorPreviewSubject {
        .particlePreset(directory: assets.appending(path: "presets/rain").path(percentEncoded: false), variant: 0, is3D: false)
    }

    private func assetsTree() throws -> URL {
        let root = scratch.appending(path: "assets", directoryHint: .isDirectory)
        for name in ["tint", "blur"] {
            try write(#"{"group": "blur"}"#, to: "effects/\(name)/effect.json", in: root)
            try write("void main() {}", to: "effects/\(name)/shaders/effects/\(name).frag", in: root)
        }
        try write("// common", to: "shaders/common.h", in: root)
        try write("png", to: "materials/util/noise.png", in: root)
        try write(#"{"material": "materials/particle/halo.json"}"#, to: "particles/example.json", in: root)
        try write("{}", to: "materials/particle/halo.json", in: root)
        try write(#"{"variants": []}"#, to: "presets/rain/preset.json", in: root)
        return root
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
