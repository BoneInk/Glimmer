#if GW_SCENE_PREVIEW_PRELOAD_TESTS
import AppKit
import Foundation
import Observation
import SwiftUI

// These substitutes keep this probe on the route/model state machine. No real
// Scene helper, renderer, user library, desktop or lock-screen service is used.
struct WallpaperItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var workshopID: String?
    let scene: Bool
    let exists: Bool
    let fileURL: URL

    init(id: UUID = UUID(), workshopID: String? = nil, scene: Bool = true,
         exists: Bool = true) {
        self.id = id
        self.workshopID = workshopID
        self.scene = scene
        self.exists = exists
        self.fileURL = URL(fileURLWithPath: "/tmp/scene-preview-\(id.uuidString)")
    }

    var isSceneWallpaper: Bool { scene }
    var fileExists: Bool { exists }
}

struct WorkshopSearchResult: Identifiable {
    let id: String
}

struct AppStorage: Sendable {
    let root: URL
}

struct SceneVector2: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct SceneEngineAssetBundle: Sendable {}

private struct MotionOverride: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var windowGlassReduceMotionOverride: Bool {
        get { self[MotionOverride.self] }
        set { self[MotionOverride.self] = newValue }
    }
}

actor PreviewGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class AuthorPropertyServices {
    static let shared = AuthorPropertyServices()
    var revisions: [UUID: Int] = [:]
    static var payloadGate: PreviewGate?
    static var payloadCount = 0

    static func resetPayload() {
        payloadGate = nil
        payloadCount = 0
    }

    static func payload(item: WallpaperItem, storage: AppStorage) async throws -> Data {
        payloadCount += 1
        if let gate = payloadGate { await gate.wait() }
        return Data("{}".utf8)
    }

    func registerScene(_ runtime: SceneWallpaperRuntime, itemID: UUID,
                       onConfigurationChange: (@MainActor () -> Void)? = nil) -> UUID {
        UUID()
    }

    func unregisterScene(itemID: UUID, token: UUID) {}
}

@MainActor
final class SceneWallpaperRuntime {
    enum State: String {
        case idle, loading, ready, paused, failed, disposed
    }

    static var initCount = 0
    static var loadCount = 0
    static var applyCount = 0
    static var disposeCount = 0
    static var loadGate: PreviewGate?
    static var applyGate: PreviewGate?

    static func resetCounters() {
        initCount = 0
        loadCount = 0
        applyCount = 0
        disposeCount = 0
        loadGate = nil
        applyGate = nil
    }

    static func physicalScreenResolution(displayID: UInt32) -> SceneVector2? {
        SceneVector2(x: 3840, y: 2160)
    }

    let projectURL: URL
    let followsHostScreen: Bool
    let screenResolution: SceneVector2?
    let hostView = NSView()
    private(set) var state: State = .idle
    private(set) var lastError: String?
    var isAnimated: Bool { state == .ready || state == .paused }

    // Keep the argument order aligned with SceneRuntimeFacade so this fake
    // cannot hide a production argument-order error.
    init(projectURL: URL, inspectionBarrier: (@Sendable () async throws -> Void)? = nil,
         workerExecutableURL: URL? = nil, screenResolution: SceneVector2? = nil,
         followsHostScreen: Bool = false, engineAssets: SceneEngineAssetBundle? = nil) throws {
        Self.initCount += 1
        self.projectURL = projectURL
        self.followsHostScreen = followsHostScreen
        self.screenResolution = screenResolution
    }

    func setFrameRateLimit(_ value: Int) throws {}
    func setSceneSound(enabled: Bool, volume: Double) {}
    func setPaused(_ value: Bool) {
        if value, state == .ready { state = .paused }
        else if !value, state == .paused { state = .ready }
    }

    func load(propertiesJSON: Data) async throws {
        Self.loadCount += 1
        state = .loading
        if let gate = Self.loadGate { await gate.wait() }
        try Task.checkCancellation()
        state = .ready
    }

    func applyPropertiesAndWait(_ payload: Data) async throws {
        Self.applyCount += 1
        if let gate = Self.applyGate { await gate.wait() }
        try Task.checkCancellation()
        state = .ready
    }

    func dispose() {
        if state != .disposed { Self.disposeCount += 1 }
        state = .disposed
    }
}

@MainActor
final class FakeRoutePreviewOwner: WorkspaceScenePreviewOwning {
    let itemID: UUID
    let wallpaperFPS: Int
    let screenResolution: SceneVector2?
    private(set) var cancelCount = 0

    init(itemID: UUID, wallpaperFPS: Int, screenResolution: SceneVector2?) {
        self.itemID = itemID
        self.wallpaperFPS = wallpaperFPS
        self.screenResolution = screenResolution
    }

    func cancel() { cancelCount += 1 }
}

@main
@MainActor
enum ScenePreviewPreloadTests {
    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, "FAIL: \(name)")
        print("PASS: \(name)")
    }

    static func waitUntil(_ condition: @MainActor () -> Bool,
                          iterations: Int = 2_000) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func main() async {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScenePreviewPreload-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = AppStorage(root: root)

            // Route ownership: preparation starts synchronously in open(item),
            // carries the injected FPS/display, and is cancelled before a new
            // route replaces it or before close completes.
            let presentation = WorkspaceWallpaperDetails()
            presentation.configureScenePreview(storage: storage, wallpaperFPS: 42)
            presentation.scenePreviewScreenResolutionProvider = {
                SceneVector2(x: 3840, y: 2160)
            }
            var owners: [FakeRoutePreviewOwner] = []
            presentation.scenePreviewPreparationFactory = { item, _, fps, resolution in
                let owner = FakeRoutePreviewOwner(
                    itemID: item.id, wallpaperFPS: fps, screenResolution: resolution)
                owners.append(owner)
                return owner
            }
            let sceneA = WallpaperItem(workshopID: "88")
            let sceneB = WallpaperItem(workshopID: "99")
            presentation.open(sceneA)
            check(owners.count == 1, "Scene preparation starts synchronously at open(item)")
            check(owners[0].wallpaperFPS == 42 &&
                  owners[0].screenResolution == SceneVector2(x: 3840, y: 2160),
                  "open(item) uses injected FPS and clicked-window physical resolution")

            presentation.open(sceneB)
            check(owners.count == 2 && owners[0].cancelCount == 1,
                  "rapid A to B cancels the previous route preparation")
            let routeB = presentation.route!.id
            presentation.dismiss()
            check(owners[1].cancelCount == 1, "close cancels the active route preparation immediately")
            presentation.finishDismissal(routeB)
            check(presentation.route == nil, "close clears the owned route")

            var remoteFactoryCalls = 0
            presentation.scenePreviewPreparationFactory = { _, _, _, _ in
                remoteFactoryCalls += 1
                return FakeRoutePreviewOwner(itemID: UUID(), wallpaperFPS: 30, screenResolution: nil)
            }
            presentation.open(WorkshopSearchResult(id: "remote-only"))
            check(remoteFactoryCalls == 0, "undownloaded Workshop result never preheats Scene")
            let authorRoute = WorkspaceWallpaperDetails()
            authorRoute.scenePreviewScreenResolutionProvider = { nil }
            authorRoute.configureScenePreview(storage: storage, wallpaperFPS: 30)
            var authorOwners = [FakeRoutePreviewOwner]()
            authorRoute.scenePreviewPreparationFactory = { item, _, fps, resolution in
                let owner = FakeRoutePreviewOwner(itemID: item.id, wallpaperFPS: fps, screenResolution: resolution)
                authorOwners.append(owner); return owner
            }
            authorRoute.localWallpaperLookup = { $0 == sceneA.workshopID ? sceneA : nil }
            authorRoute.open(WorkshopSearchResult(id: sceneA.workshopID!))
            check(authorRoute.route?.item?.id == sceneA.id && authorRoute.route?.result == nil && authorOwners.count == 1,
                  "opening an installed author work selects local preview and starts Scene preloading")
            authorRoute.localWallpaperLookup = { _ in WallpaperItem(workshopID: "88", exists: false) }
            authorRoute.open(WorkshopSearchResult(id: "88"))
            check(authorRoute.route?.result?.id == "88" && authorRoute.route?.item == nil,
                  "an unavailable local author work falls back to its Workshop cover")

            // Downloads finish before their automatic library import. Promote
            // only the still-visible matching result when that import arrives.
            var newlyImported: WallpaperItem?
            authorRoute.localWallpaperLookup = { _ in newlyImported }
            authorRoute.prepareSource("workshop:88:creator:example")
            authorRoute.open(WorkshopSearchResult(id: "88"))
            let publicRouteID = authorRoute.route!.id
            let publicKey = authorRoute.route!.key
            let ownersBeforeImport = authorOwners.count
            check(!authorRoute.promoteDownloadedResult() && authorRoute.route?.id == publicRouteID,
                  "completed download without imported library item keeps the current public detail")
            newlyImported = sceneB
            check(!authorRoute.promoteDownloadedResult(), "a different imported work cannot replace the current detail")
            newlyImported = WallpaperItem(workshopID: "88", exists: false)
            check(!authorRoute.promoteDownloadedResult(), "missing imported files cannot promote a public detail")
            newlyImported = sceneA
            check(authorRoute.promoteDownloadedResult() && authorRoute.route?.item?.id == sceneA.id && authorRoute.route?.result == nil,
                  "download import replaces the public preview with unified local details")
            check(authorRoute.route?.id == publicRouteID && authorRoute.route?.key == publicKey,
                  "download promotion preserves route identity and the browsing return source")
            check(authorOwners.count == ownersBeforeImport + 1 && !authorRoute.promoteDownloadedResult(),
                  "download promotion starts Scene preparation once without repeated route replacement")
            authorRoute.open(WorkshopSearchResult(id: "99"))
            authorRoute.dismiss()
            newlyImported = sceneB
            check(!authorRoute.promoteDownloadedResult() && authorRoute.route?.result?.id == "99",
                  "an import finishing during Back cannot reopen or replace the closing detail")
            authorRoute.finishDismissal(authorRoute.route!.id)
            check(!authorRoute.promoteDownloadedResult() && authorRoute.route == nil,
                  "an import finishing after Back leaves the browser visible")
            newlyImported = nil
            authorRoute.open(WorkshopSearchResult(id: "88"))
            authorRoute.open(WorkshopSearchResult(id: "another-work"))
            newlyImported = sceneA
            check(!authorRoute.promoteDownloadedResult() && authorRoute.route?.result?.id == "another-work",
                  "late import cannot steal the detail after selecting another work")
            newlyImported = nil
            authorRoute.open(WorkshopSearchResult(id: "video"))
            newlyImported = WallpaperItem(workshopID: "video", scene: false)
            let sceneOwnerCount = authorOwners.count
            check(authorRoute.promoteDownloadedResult() && authorOwners.count == sceneOwnerCount,
                  "video download promotion uses local details without starting a Scene renderer")
            authorRoute.open(sceneA)
            let navigatingOwner = authorOwners.last!
            authorRoute.coverImage = NSImage(size: NSSize(width: 10, height: 10))
            authorRoute.dismissForCreatorNavigation()
            check(authorRoute.route == nil && !authorRoute.closing && authorRoute.coverImage == nil && navigatingOwner.cancelCount == 1,
                  "creator navigation clears wallpaper ownership directly without its returning flight")

            // Concurrent takeover awaits the single initial load. It must not
            // initialize/load again, and must not apply properties over it.
            SceneWallpaperRuntime.resetCounters()
            AuthorPropertyServices.resetPayload()
            let payloadGate = PreviewGate()
            AuthorPropertyServices.payloadGate = payloadGate
            let takeoverItem = WallpaperItem()
            let takeover = SceneWallpaperPreviewModel()
            let firstUpdate = Task { @MainActor in
                await takeover.update(item: takeoverItem, paused: false, storage: storage)
            }
            try await waitUntil { AuthorPropertyServices.payloadCount == 1 }
            let secondUpdate = Task { @MainActor in
                await takeover.update(item: takeoverItem, paused: true, storage: storage)
            }
            try await Task.sleep(for: .milliseconds(20))
            check(SceneWallpaperRuntime.initCount == 0 &&
                  SceneWallpaperRuntime.loadCount == 0 &&
                  SceneWallpaperRuntime.applyCount == 0,
                  "detail takeover waits in the existing payload task")
            await payloadGate.release()
            await firstUpdate.value
            await secondUpdate.value
            check(SceneWallpaperRuntime.initCount == 1 &&
                  SceneWallpaperRuntime.loadCount == 1 &&
                  SceneWallpaperRuntime.applyCount == 0,
                  "takeover initializes and loads exactly once without apply interference")
            check(takeover.runtime?.state == .paused,
                  "latest paused intent is applied after the one initial load")

            AuthorPropertyServices.payloadGate = nil
            await takeover.update(item: takeoverItem, paused: true, storage: storage)
            check(SceneWallpaperRuntime.initCount == 1 &&
                  SceneWallpaperRuntime.loadCount == 1 &&
                  SceneWallpaperRuntime.applyCount == 0,
                  "repeated view task reuses the ready instance")

            AuthorPropertyServices.shared.revisions[takeoverItem.id] = 1
            await takeover.update(item: takeoverItem, paused: true, storage: storage)
            check(SceneWallpaperRuntime.initCount == 1 &&
                  SceneWallpaperRuntime.loadCount == 1 &&
                  SceneWallpaperRuntime.applyCount == 1,
                  "author revision applies after initialization without another load")
            AuthorPropertyServices.shared.revisions[takeoverItem.id] = 2
            await takeover.update(item: takeoverItem, paused: true, storage: storage)
            check(SceneWallpaperRuntime.applyCount == 2,
                  "later author revision applies again on the same Scene")

            // A noncooperative close cannot publish an old completion into a
            // disposed preview.
            SceneWallpaperRuntime.resetCounters()
            AuthorPropertyServices.resetPayload()
            let loadGate = PreviewGate()
            SceneWallpaperRuntime.loadGate = loadGate
            let closing = SceneWallpaperPreviewModel()
            let closingUpdate = Task { @MainActor in
                await closing.update(item: WallpaperItem(), paused: false, storage: storage)
            }
            try await waitUntil { SceneWallpaperRuntime.loadCount == 1 }
            closing.dispose()
            check(closing.runtime == nil, "dispose releases the runtime before load completes")
            await loadGate.release()
            await closingUpdate.value
            check(closing.runtime == nil && closing.error == nil,
                  "old load completion cannot republish after close")

            SceneWallpaperRuntime.resetCounters()
            AuthorPropertyServices.resetPayload()
            let preparationGate = PreviewGate()
            SceneWallpaperRuntime.loadGate = preparationGate
            let preparation = SceneWallpaperPreviewPreparation(
                item: WallpaperItem(), storage: storage, wallpaperFPS: 30,
                screenResolution: nil)
            try await waitUntil { SceneWallpaperRuntime.loadCount == 1 }
            check(preparation.model.runtime != nil,
                  "route preparation starts a real model task without a mounted view")
            await preparationGate.release()
            try await waitUntil { preparation.model.runtime?.state == .ready }
            preparation.cancel()
            check(preparation.model.runtime == nil &&
                  SceneWallpaperRuntime.disposeCount == 1,
                  "route preparation cancel releases its borrowed engine")

            // Cancelling before the preparation task first runs must not let
            // that task reactivate the model for a later borrowed-view update.
            SceneWallpaperRuntime.resetCounters()
            AuthorPropertyServices.resetPayload()
            let cancelledItem = WallpaperItem()
            let cancelledPreparation = SceneWallpaperPreviewPreparation(
                item: cancelledItem, storage: storage, wallpaperFPS: 30,
                screenResolution: nil)
            cancelledPreparation.cancel()
            try await Task.sleep(for: .milliseconds(20))
            await cancelledPreparation.model.update(
                item: cancelledItem, paused: false, storage: storage)
            check(SceneWallpaperRuntime.initCount == 0 &&
                  SceneWallpaperRuntime.loadCount == 0,
                  "cancelled route cannot restart from a borrowed view update")

            // Standalone preview keeps its original local-model lifecycle.
            SceneWallpaperRuntime.resetCounters()
            AuthorPropertyServices.resetPayload()
            let standalone = SceneWallpaperPreviewModel()
            await standalone.update(item: WallpaperItem(), paused: true, storage: storage)
            check(SceneWallpaperRuntime.initCount == 1 &&
                  SceneWallpaperRuntime.loadCount == 1 &&
                  standalone.runtime?.state == .paused,
                  "standalone preview still loads once with its local model")
            standalone.dispose()
            check(standalone.runtime == nil && SceneWallpaperRuntime.disposeCount == 1,
                  "standalone preview still disposes its own model")

            print("ScenePreviewPreloadTests: route/model lifecycle passed; fake renderer only")
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
}
#endif
