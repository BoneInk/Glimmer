import AppKit
import SwiftUI
import OWESceneEditing

/// A texture a particle material can draw (`materials/<name>.tex`), as the texture picker lists it.
public struct ParticleTextureChoice: Identifiable, Hashable, Sendable {
    /// The material's texture name: its path under `materials/` without the extension (`particle/halo`).
    public let name: String
    /// Frames of its sprite sheet; 0 for a still texture.
    public let frames: Int
    /// From WE's assets rather than the wallpaper.
    public let isShared: Bool

    public var id: String { name }

    public init(name: String, frames: Int = 0, isShared: Bool) {
        self.name = name
        self.frames = frames
        self.isShared = isShared
    }
}

/// What the particle editor needs from the app beside the session: WE's particle systems and
/// presets, textures, previews of both, and restarting a running system.
@MainActor
public final class ParticleEditorServices: ObservableObject {
    public let model: ParticleEditingModel
    /// WE's default systems and presets, read when the browser opens (the assets may have been
    /// installed meanwhile).
    public let catalog: () -> ParticleCatalog
    public let textures: [ParticleTextureChoice]
    /// The browser's rendered previews; nil shows a symbol.
    public var previews: EditorPreviewProvider?
    /// Whether WE's assets are installed.
    public var hasWEAssets: () -> Bool = { true }
    /// Opens the app's setup of WE's assets.
    public var openAssetsSetup: () -> Void = {}
    /// A preview of a texture, by its name; nil when it can't be read.
    private let loadThumbnail: (String) -> NSImage?
    /// Starts the layer's running system (and its children) again from nothing.
    public let restart: (Int) -> Void
    private var thumbnails: [String: NSImage?] = [:]

    public init(model: ParticleEditingModel, catalog: @escaping () -> ParticleCatalog, textures: [ParticleTextureChoice],
                thumbnail: @escaping (String) -> NSImage?, restart: @escaping (Int) -> Void) {
        self.model = model
        self.catalog = catalog
        self.textures = textures
        loadThumbnail = thumbnail
        self.restart = restart
    }

    /// The services over `session` with the editor's own copy of WE's schema; throws when it
    /// can't be read (the caller leaves the particle editor out and says why).
    public static func make(session: SceneEditSession, readAsset: @escaping (String) -> Data?,
                            catalog: @escaping () -> ParticleCatalog, textures: [ParticleTextureChoice],
                            thumbnail: @escaping (String) -> NSImage?,
                            restart: @escaping (Int) -> Void) throws -> ParticleEditorServices {
        let schema = try bundledSchema()
        let model = ParticleEditingModel(session: session, schema: schema, readAsset: readAsset)
        return ParticleEditorServices(model: model, catalog: catalog, textures: textures, thumbnail: thumbnail,
                                      restart: restart)
    }

    /// WE's particle editor schema as the module bundles it (a copy of
    /// docs/we-particle-editor-schema.json).
    nonisolated public static func bundledSchema() throws -> ParticleEditorSchema {
        guard let url = Bundle.module.url(forResource: "ParticleEditorSchema", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ParticleEditorSchema(data: Data(contentsOf: url))
    }

    func thumbnail(_ name: String) -> NSImage? {
        if let cached = thumbnails[name] { return cached }
        let image = loadThumbnail(name)
        thumbnails[name] = image
        return image
    }
}
