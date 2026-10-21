import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// A small scene wallpaper on disk for the scene requests' tests: an image layer with a blur
/// effect, a text layer and a particle system, a user property, and resources that read them
/// without Wallpaper Engine's assets.
@MainActor
final class MCPSceneFixture {
    static let scene = Data("""
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0 0 0"},
     "objects": [
       {"id": 4, "name": "Picture", "image": "models/a.json", "origin": "100 100 0", "size": "200 100", "alpha": 1,
        "effects": [{"file": "effects/blur/effect.json", "name": "", "visible": true,
                     "passes": [{"constantshadervalues": {"strength": 2}}]}]},
       {"id": 5, "name": "Title", "text": {"value": "Hello"}, "font": "systemfont_arial", "pointsize": 32, "origin": "960 540 0"},
       {"id": 6, "name": "Rain", "particle": "particles/test.json", "origin": "0 0 0"}
     ]}
    """.utf8)

    static let project = Data("""
    {"file": "scene.json", "title": "Fixture Scene", "type": "scene",
     "general": {"properties": {"speed": {"type": "slider", "text": "Speed", "value": 1, "min": 0, "max": 2, "order": 1}}}}
    """.utf8)

    let root: URL
    let folder: URL
    let store: SceneEditOverlayStore
    let defaults: UserDefaults
    let suiteName: String
    /// The depth map sections' services the resources give (none: no depth maps).
    var depthMapServices: DepthMapEditorServices?

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MCPScene-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = root.appending(path: "wallpaper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.scene.write(to: folder.appending(path: "scene.json"))
        try Self.project.write(to: folder.appending(path: "project.json"))
        store = SceneEditOverlayStore(directory: root.appending(path: "editor", directoryHint: .isDirectory))
        suiteName = "MCPSceneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .app
    }

    /// The Wallpaper Editor's drafts beside the fixture's saved overlays.
    var draftStore: SceneEditDraftStore { SceneEditDraftStore(saved: store) }

    func remove() {
        try? FileManager.default.removeItem(at: root) // Optional: a temporary folder.
        defaults.removePersistentDomain(forName: suiteName)
    }

    var wallpaper: ControlWallpaper {
        ControlWallpaper(id: "fixture", title: "Fixture Scene", type: "scene", tags: [], folder: folder, workshopID: nil,
                         description: nil, contentRating: nil)
    }

    var identity: WallpaperSettingsIdentity { WallpaperSettingsIdentity.resolve(directory: folder, defaults: defaults) }

    func resources() -> FakeSceneEditResources {
        let resources = FakeSceneEditResources(folder: folder, identity: identity,
                                               assets: EditorAssetStore(directory: root.appending(path: "assets")))
        resources.depthServices = depthMapServices
        return resources
    }

    /// The headless service over the fixture, editing the draft in its own store and posting saves on `center`.
    func service(center: NotificationCenter = NotificationCenter(),
                 announce: @escaping @MainActor (URL, String, AppProcessChannel.OverlayStep) -> Void = { _, _, _ in },
                 announceSave: @escaping @MainActor (URL, SceneEditOverlay) -> Void = { _, _ in }) -> HeadlessSceneEditService {
        let resources = resources()
        return HeadlessSceneEditService(dependencies: .init(store: draftStore, center: center, resources: { _ in resources },
                                                            announce: announce, announceSave: announceSave))
    }
}

/// The fixture's resources: one effect with a constant, a combo and a texture slot; one particle
/// system; a model for the image layer's puppet; depth maps only when a test gives their services.
@MainActor
final class FakeSceneEditResources: SceneEditResources {
    let folder: URL
    let identity: WallpaperSettingsIdentity
    let assetStore: EditorAssetStore
    var sceneData: Data { MCPSceneFixture.scene }
    var projectJSON: Data? { MCPSceneFixture.project }
    var preparedEffects: [String] = []
    var depthServices: DepthMapEditorServices?

    init(folder: URL, identity: WallpaperSettingsIdentity, assets: EditorAssetStore) {
        self.folder = folder
        self.identity = identity
        assetStore = assets
    }

    static let particle: [String: Any] = [
        "material": "materials/particle/rain.json", "maxcount": 100,
        "emitter": [["name": "boxrandom", "rate": 10, "id": 1]],
        "initializer": [["name": "lifetimerandom", "min": 1, "max": 2, "id": 2]],
        "operator": [["name": "movement", "id": 3]],
        "renderer": [["name": "sprite", "id": 4]],
    ]

    var puppetAssets: PuppetEditorAssets {
        PuppetEditorAssets(readFile: { path in
            path == "models/a.json" ? Data(#"{"material": "materials/a.json"}"#.utf8) : nil
        }, image: { _ in nil })
    }

    func effectCatalog(outline: SceneOutline) -> [EffectCatalogEntry] {
        [EffectCatalogEntry(file: "effects/blur/effect.json", title: "Blur"),
         EffectCatalogEntry(file: "effects/shake/effect.json", title: "Shake")]
    }

    func effectSchema(_ file: String) -> EffectSchema? {
        EffectSchema(parameters: [EffectSchema.Parameter(key: "strength", title: "Strength", defaultValue: [1], minimum: 0, maximum: 10)],
                     combos: [EffectSchema.Combo(name: "MODE", title: "Mode", defaultValue: 0,
                                                 options: [.init(title: "Soft", value: 0), .init(title: "Hard", value: 1)])],
                     textures: [EffectSchema.TextureSlot(slot: 1, title: "Mask", isMask: true, combo: "MASK")])
    }

    func prepareEffect(_ entry: EffectCatalogEntry) throws { preparedEffects.append(entry.file) }

    func readAsset(_ path: String) -> Data? {
        switch path {
        case "particles/test.json": return try? JSONSerialization.data(withJSONObject: Self.particle) // A literal: always encodes.
        case "materials/particle/rain.json":
            return Data(#"{"passes": [{"blending": "additive", "shader": "genericparticle", "textures": ["particle/rain"]}]}"#.utf8)
        default: return nil
        }
    }

    func particleCatalog() -> ParticleCatalog {
        ParticleCatalog(items: [], hasPresets: false)
    }

    func depthMapServices() -> DepthMapEditorServices? { depthServices }
}

/// The editors' windows and the library, recorded.
@MainActor
final class FakeSceneEditorControl: SceneEditorControl {
    var shown: [(String, SceneInspectorMode)] = []
    var sceneEditorOpen = true
    var editorRunning = true
    var closedWallpaperEditors: [String] = []
    var timelineCommands: [(String, String, Double?)] = []
    var restarted: [Int] = []
    /// Whether the Wallpaper Editor has a window of the wallpaper (a restart goes there).
    var editorWindowOpen = false
    var savedCopies: [String] = []
    var isDepthMapPluginInstalled = false

    func showSceneEditor(_ wallpaper: ControlWallpaper, mode: SceneInspectorMode) throws { shown.append((wallpaper.id, mode)) }

    func closeSceneEditor() -> Bool {
        defer { sceneEditorOpen = false }
        return sceneEditorOpen
    }

    func closeWallpaperEditor(_ wallpaper: ControlWallpaper) -> Bool {
        guard editorRunning else { return false }
        closedWallpaperEditors.append(wallpaper.id)
        return true
    }

    func controlTimeline(_ wallpaper: ControlWallpaper, command: String, seconds: Double?) -> Bool {
        guard editorRunning else { return false }
        timelineCommands.append((wallpaper.id, command, seconds))
        return true
    }

    func restartParticles(_ document: HeadlessSceneDocument, layer: Int) async -> Bool {
        restarted.append(layer)
        return editorWindowOpen
    }

    func saveAsNewWallpaper(_ document: HeadlessSceneDocument, title: String) throws -> URL {
        savedCopies.append(title)
        return URL(fileURLWithPath: "/library/copy-\(savedCopies.count)")
    }
}

/// The app model the router needs for the scene requests: the fixture's wallpaper in the library.
@MainActor
final class MCPSceneAppModel: ControlAppModel {
    var library: [ControlWallpaper]

    init(_ wallpapers: [ControlWallpaper]) { library = wallpapers }

    func displays() -> [ControlDisplay] { [] }
    func wallpapers() -> [ControlWallpaper] { library }
    func wallpaper(onDisplay id: String) -> ControlWallpaper? { nil }
    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty] { [] }
    var playback: ControlPlayback { ControlPlayback(paused: false, volume: 1) }
    func playlists() -> [ControlPlaylist] { [] }
    func setWallpaper(_ wallpaper: ControlWallpaper, displays: [String]) throws {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func setUserProperty(_ key: String, to value: String, of wallpaper: ControlWallpaper) -> [String] { [] }
    func playPlaylist(_ playlist: ControlPlaylist, displays: [String]) {}
    func step(forward: Bool, displays: [String]) -> [String: ControlWallpaper?] { [:] }
    func importWallpapers(at url: URL) async throws -> ControlImportResult { ControlImportResult(imported: [], skipped: []) }
    func openEditor(_ editor: ControlEditor, for wallpaper: ControlWallpaper) throws {}
    func snapshot(display: String) async throws -> ControlSnapshot { throw ControlError(.unavailable, "none") }
}

/// The distributed notification centre, in memory.
@MainActor
final class MCPFakeProcessMessaging: AppProcessMessaging {
    private final class Observer {
        let name: Notification.Name
        let handler: @MainActor (String?, [String: String]) -> Void
        init(name: Notification.Name, handler: @escaping @MainActor (String?, [String: String]) -> Void) {
            self.name = name
            self.handler = handler
        }
    }

    private var observers: [Observer] = []
    private(set) var posted: [(name: Notification.Name, sender: String, userInfo: [String: String])] = []

    func post(_ name: Notification.Name, sender: String, userInfo: [String: String]) {
        posted.append((name, sender, userInfo))
        for observer in observers where observer.name == name { observer.handler(sender, userInfo) }
    }

    func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (String?, [String: String]) -> Void) -> AnyObject {
        let observer = Observer(name: name, handler: handler)
        observers.append(observer)
        return observer
    }

    func remove(_ token: AnyObject) {
        observers.removeAll { $0 === token }
    }
}
