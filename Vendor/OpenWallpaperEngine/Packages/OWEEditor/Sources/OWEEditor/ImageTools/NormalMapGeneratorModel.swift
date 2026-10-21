import AppKit
import OWESceneEditing
import SwiftUI

/// WE's Normal Map Generation window for one image layer: the layer's picture, the generator's
/// options (`NormalMapGenerator.Settings`), the normal map made from them, and OK, which writes it
/// as the layer's normal map (`SceneEditSession.applyNormalMap`, one undo step).
@MainActor
final class NormalMapGeneratorModel: ObservableObject {
    enum Preview: String, CaseIterable, Identifiable {
        case normalMap, original
        var id: String { rawValue }
    }

    let session: SceneEditSession
    let layerID: Int
    let services: WallpaperEditorServices
    let tools: EditorTools

    @Published var settings: NormalMapGenerator.Settings {
        didSet { if settings != oldValue { scheduleGeneration() } }
    }
    @Published private(set) var original: CGImage?
    @Published private(set) var normalMap: CGImage?
    @Published private(set) var isGenerating = false
    @Published var preview: Preview = .normalMap
    @Published var problem: String?

    private var picture: RGBAImage?
    /// The material the settings are remembered for (WE keeps them per material and texture slot
    /// while the editor is open).
    private let cacheKey: String?
    private var pending: Task<Void, Never>?
    private var generation = 0

    init(session: SceneEditSession, layerID: Int, services: WallpaperEditorServices, tools: EditorTools) {
        self.session = session
        self.layerID = layerID
        self.services = services
        self.tools = tools
        let material = session.outline.layer(layerID).flatMap { ImageLayerMaterial(layer: $0, readFile: services.readFile) }
        cacheKey = material.map { "\($0.materialPath)%1" }
        settings = cacheKey.flatMap { tools.normalMapSettings[$0] } ?? NormalMapGenerator.Settings()
        if let texture = material?.texture, let image = services.texture(texture) {
            original = image
            picture = RGBAImage(image)
        }
        if picture == nil { problem = IL("The layer’s picture can’t be read.") }
        generate()
    }

    var imageSize: SIMD2<Double> {
        guard let picture else { return SIMD2(1, 1) }
        return SIMD2(Double(picture.width), Double(picture.height))
    }

    var shownImage: CGImage? { preview == .original ? original : (normalMap ?? original) }

    /// WE's Reset: the defaults.
    func resetSettings() { settings = NormalMapGenerator.Settings() }

    /// Generates after the sliders settle; a change while one runs starts another after it.
    private func scheduleGeneration() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200)) // Optional: a cancelled wait just skips this run.
            guard !Task.isCancelled else { return }
            self?.generate()
        }
    }

    func generate() {
        guard let picture else { return }
        generation += 1
        let current = generation, settings = settings
        isGenerating = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = NormalMapGenerator.generate(picture, settings: settings).cgImage
            await self?.finish(result, generation: current)
        }
    }

    private func finish(_ image: CGImage?, generation finished: Int) {
        guard finished == generation else { return }
        isGenerating = false
        normalMap = image
        preview = .normalMap
    }

    /// OK: the normal map becomes the layer's; returns whether it did.
    func apply() -> Bool {
        guard let normalMap, let store = services.assetStore else { return false }
        if let cacheKey { tools.normalMapSettings[cacheKey] = settings }
        do {
            try session.applyNormalMap(normalMap, to: layerID, store: store, readFile: services.readFile,
                                       actionName: IL("Generate Normal Map"))
            return true
        } catch {
            problem = IL("The normal map couldn’t be saved: \(error.localizedDescription)")
            return false
        }
    }

    func cancel() { pending?.cancel() }
}
