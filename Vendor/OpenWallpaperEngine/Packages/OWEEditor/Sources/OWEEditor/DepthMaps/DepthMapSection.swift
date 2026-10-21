import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The state of one depth map section: the depth map made for the layer (or the scene) but not
/// applied yet, its preview, and what went wrong. Applied depth maps live in the overlay; this
/// only holds a generation until it is applied.
///
/// The two sections have different jobs:
/// - the scene's (`layerID` nil) applies WE's Depth Parallax on top of the scene
///   (`SceneDepthParallax`);
/// - a layer's, **Create Mask from Depth Map**, writes the depth map, inverted and with its
///   contrast set, as the mask of one of the layer's effects (`useAsMask`, `DepthMask`). It no
///   longer applies depth parallax; a layer's depth parallax added before can still be removed.
@MainActor
public final class DepthMapSectionModel: ObservableObject {
    public let session: SceneEditSession
    /// Nil: the whole scene.
    public let layerID: Int?
    public let services: DepthMapEditorServices

    /// The newest depth map made here (`depth/editor_…`), applied or not.
    @Published public private(set) var generatedTexture: String?
    @Published public private(set) var depthPreview: CGImage?
    @Published public private(set) var isOneFrame = false
    @Published public var showsDepthPreview = true
    @Published public var smoothing = 0.25
    /// The strength a new depth parallax starts with.
    @Published public var pendingStrength = SceneDepthParallax.defaultStrength
    @Published public var problem: String?
    /// The layer's mask: near and far swapped.
    @Published public var maskInverted = false { didSet { refreshMaskPreview() } }
    /// The layer's mask: its contrast (`DepthMask.contrastRange`).
    @Published public var maskContrast = DepthMask.defaultContrast { didSet { refreshMaskPreview() } }
    /// The depth preview as the mask will be (a layer's), smaller.
    @Published public internal(set) var maskPreview: CGImage?
    /// What the last Use as Mask did, to show under it.
    @Published public internal(set) var maskNotice: String?

    public init(session: SceneEditSession, layerID: Int?, services: DepthMapEditorServices) {
        self.session = session
        self.layerID = layerID
        self.services = services
        if let texture = appliedTexture {
            depthPreview = services.texture(texture)
        }
        refreshMaskPreview()
    }

    // MARK: What is applied

    /// The layer the effect is on: the layer itself, or the fullscreen layer above it (a particle
    /// system, the scene).
    public var effectLayer: Int? {
        guard let layerID else { return session.depthParallaxLayer(above: nil) }
        guard let layer = session.outline.layer(layerID) else { return nil }
        switch SceneDepthParallax.placement(for: layer) {
        case .onLayer: return session.depthParallaxEffect(of: layerID) != nil ? layerID : nil
        case .layerAbove: return session.depthParallaxLayer(above: layerID)
        case nil: return nil
        }
    }

    public var isApplied: Bool { effectLayer != nil }

    public var appliedTexture: String? { effectLayer.flatMap(session.depthParallaxTexture) }

    /// Whether the section works here: always for the scene; for a layer, one with a rectangle of
    /// its own that carries effects (an image or text layer), whose effects' masks it fills.
    public var isSupported: Bool {
        guard let layerID else { return true }
        return session.outline.layer(layerID).flatMap(SceneDepthParallax.placement) == .onLayer
    }

    /// Before generating: whether the picture will come from one rendered frame.
    public var comesFromOneFrame: Bool {
        guard let layerID, let layer = session.outline.layer(layerID) else { return true }
        return layer.kind == .particle || layer.fillsScene
    }

    public var strength: Double {
        get { effectLayer.flatMap(session.depthParallaxStrength) ?? pendingStrength }
        set {
            pendingStrength = newValue
            if let effectLayer {
                session.setDepthParallaxStrength(newValue, of: effectLayer, actionName: DL("Change Depth Parallax Strength"))
            }
        }
    }

    // MARK: Generating

    /// Generates the depth map; when depth parallax is applied already, binds it to the new one.
    public func generate() async {
        problem = nil
        let generator = services.generator
        do {
            let source = try await services.source(session.depthMapRequest(for: layerID))
            try Task.checkCancellation()
            let result = try await generator.generate(from: source.image, smoothing: smoothing)
            let title = layerID.flatMap { session.outline.layer($0)?.name } ?? "scene"
            let texture = try services.assetStore.saveDepthMap(result.png, title: title.isEmpty ? "layer" : title)
            generatedTexture = texture
            depthPreview = result.depth.grayImage()
            refreshMaskPreview()
            maskNotice = nil
            isOneFrame = source.isOneFrame
            showsDepthPreview = true
            if let effectLayer, session.depthParallaxTexture(of: effectLayer) != texture {
                session.setDepthParallaxTexture(texture, of: effectLayer, actionName: DL("Update Depth Map"))
            }
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    public func cancel() {
        services.generator.cancel()
    }

    // MARK: Applying

    /// The scene's: adds WE's depth parallax effect bound to the generated depth map on a
    /// fullscreen layer on top of the scene. One undo step. A layer's section makes masks instead.
    public func apply() {
        guard layerID == nil, let texture = generatedTexture ?? appliedTexture else { return }
        problem = nil
        do {
            try services.prepareEffect()
        } catch {
            problem = error.localizedDescription
            return
        }
        session.addDepthParallaxLayer(texture: texture, strength: pendingStrength, above: nil,
                                      name: DL("Scene Depth Parallax"), actionName: DL("Apply Depth Parallax"))
    }

    /// Removes the effect (and the fullscreen layer that carried it). One undo step. On a layer,
    /// this takes off depth parallax an earlier version applied there.
    public func remove() {
        guard let effectLayer else { return }
        let action = DL("Remove Depth Parallax")
        if effectLayer != layerID, session.outline.layer(effectLayer)?.fillsScene == true {
            session.delete([effectLayer], actionName: action)
        } else {
            session.removeDepthParallax(of: effectLayer, actionName: action)
        }
    }
}

/// The depth map controls, the same in both editors: Generate, a preview of the depth map and
/// smoothing; then, for the scene, strength, Apply Depth Parallax and Remove, and for a layer,
/// Invert, Contrast and Use as Mask for…; or, without the plugin, the way to install it.
public struct DepthMapControls: View {
    @ObservedObject var model: DepthMapSectionModel
    @ObservedObject var session: SceneEditSession
    @ObservedObject var generator: DepthMapGenerator
    @State private var work: Task<Void, Never>?

    public init(model: DepthMapSectionModel) {
        self.model = model
        session = model.session
        generator = model.services.generator
    }

    public var body: some View {
        if !generator.isInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.layerID == nil
                     ? DL("Generate a depth map with on-device machine learning to give this depth parallax that follows the pointer.")
                     : DL("Generate a depth map with on-device machine learning to make a mask for this layer’s effects."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(DL("Install Depth Map Generation")) { model.services.openPlugins() }
                    .help(DL("Opens Settings › Plugins, where Depth Map Generation can be installed."))
            }
        } else if !model.isSupported {
            Text(DL("Only image and text layers can have a mask from a depth map."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            generation
            if model.layerID == nil {
                parallaxControls
            } else {
                DepthMaskControls(model: model, session: session, isBusy: generator.isBusy)
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder private var generation: some View {
        if model.comesFromOneFrame || model.isOneFrame {
            Label(DL("The depth comes from one frame of the scene."), systemImage: "film")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let preview = (model.layerID == nil ? nil : model.maskPreview) ?? model.depthPreview, model.showsDepthPreview {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(DL("Depth map preview"))
        }
        Toggle(DL("Preview Depth Map"), isOn: $model.showsDepthPreview)
            .disabled(model.depthPreview == nil)
            .help(model.layerID == nil ? DL("Shows the depth map: white is near, black is far.")
                  : DL("Shows the mask: white is where the effect shows, black where it doesn’t."))
        LabeledContent(DL("Smoothing")) {
            NumericSliderInput<Double>(value: $model.smoothing, range: 0...1, defaultValue: 0.25, step: 0.05,
                                       displayScale: 100, suffix: "%", fractionDigits: 0, fieldWidth: 44)
        }
        .help(DL("Evens out the depth map’s flat areas while keeping the picture’s edges. Applies to the next generation."))
        HStack {
            if generator.isBusy {
                ProgressView(value: generator.progress) {
                    Text(phaseTitle)
                }
                Button(DL("Cancel")) { model.cancel() }
            } else {
                Button(model.generatedTexture == nil && !model.isApplied ? DL("Generate") : DL("Generate Again")) {
                    work = Task { await model.generate() }
                }
                .help(DL("Estimates the depth of the picture on this Mac. Nothing is uploaded."))
            }
            Spacer()
        }
    }

    /// The scene's: WE's Depth Parallax on top of the scene.
    @ViewBuilder private var parallaxControls: some View {
        LabeledContent(DL("Strength")) {
            NumericSliderInput<Double>(value: Binding(get: { model.strength }, set: { model.strength = $0 }),
                                       range: SceneDepthParallax.strengthRange, defaultValue: SceneDepthParallax.defaultStrength,
                                       step: 0.01, fractionDigits: 2, fieldWidth: 52)
        }
        .help(DL("How far the picture shifts with the pointer."))
        HStack {
            if model.isApplied {
                Button(DL("Remove Depth Parallax"), role: .destructive) { model.remove() }
            } else {
                Button(DL("Apply Depth Parallax")) { model.apply() }
                    .disabled(model.generatedTexture == nil || generator.isBusy)
                    .help(DL("Adds Wallpaper Engine’s Depth Parallax effect, bound to this depth map."))
            }
            Spacer()
        }
    }

    private var phaseTitle: String {
        switch generator.phase {
        case .loadingModel: return DL("Loading the model…")
        case .estimating: return DL("Estimating depth…")
        case .refining: return DL("Refining edges…")
        default: return DL("Preparing…")
        }
    }
}

/// A layer's mask controls: Invert, Contrast and the menu of Layer Opacity and the layer's effects
/// with a grey mask slot. An effect whose mask is set already is listed under "Replaces the
/// current mask".
private struct DepthMaskControls: View {
    @ObservedObject var model: DepthMapSectionModel
    @ObservedObject var session: SceneEditSession
    let isBusy: Bool

    var body: some View {
        Toggle(DL("Invert"), isOn: $model.maskInverted)
            .help(DL("Swaps near and far, so the effect shows on the background instead of what is near."))
        LabeledContent(DL("Contrast")) {
            NumericSliderInput<Double>(value: $model.maskContrast, range: DepthMask.contrastRange,
                                       defaultValue: DepthMask.defaultContrast, step: 0.05,
                                       displayScale: 100, suffix: "%", fractionDigits: 0, fieldWidth: 44)
        }
        .help(DL("Pushes the mask toward black and white; below 100% it is softer."))
        let targets = model.maskTargets
        HStack {
            Menu(DL("Use as Mask for…")) {
                let fresh = targets.filter { !$0.replacesMask }
                let replacing = targets.filter(\.replacesMask)
                ForEach(fresh) { target in button(target) }
                if !replacing.isEmpty {
                    Section(DL("Replaces the current mask")) {
                        ForEach(replacing) { target in button(target) }
                    }
                }
            }
            // No fixed size: inside Scene Edit / Export's split view a fixed-size menu fed its
            // ideal size into the pane's limits, which never settled (an update-constraints loop
            // that crashed the window whenever the depth map plugin was installed).
            .disabled(model.generatedTexture == nil || isBusy || targets.isEmpty)
            .help(DL("Writes the depth map as the layer’s opacity or as the mask of one of its effects: white shows, black hides."))
            Spacer()
        }
        if targets.isEmpty {
            Text(DL("Add an effect with a mask, such as Shake, Water Ripple or Tint, to this layer first."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let notice = model.maskNotice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.isApplied {
            // Depth parallax an earlier version put on the layer; the scene's section adds it now.
            Button(DL("Remove Depth Parallax"), role: .destructive) { model.remove() }
        }
    }

    private func button(_ target: DepthMapSectionModel.MaskTarget) -> some View {
        Button(target.title) { model.useAsMask(target) }
    }
}

/// The Depth Map section of the Wallpaper Editor's inspector (a layer's Create Mask from Depth
/// Map) or of its scene form (Scene Depth Parallax).
struct DepthMapSection: View {
    @StateObject private var model: DepthMapSectionModel

    init(session: SceneEditSession, layerID: Int?, services: DepthMapEditorServices) {
        _model = StateObject(wrappedValue: DepthMapSectionModel(session: session, layerID: layerID, services: services))
    }

    var body: some View {
        Section(model.title) {
            DepthMapControls(model: model)
        }
    }
}

/// The same controls in a box, for a scrolling column (the Wallpaper Editor's scene form, the
/// Scene Edit / Export's object detail).
public struct DepthMapBox: View {
    @StateObject private var model: DepthMapSectionModel

    public init(session: SceneEditSession, layerID: Int?, services: DepthMapEditorServices) {
        _model = StateObject(wrappedValue: DepthMapSectionModel(session: session, layerID: layerID, services: services))
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                DepthMapControls(model: model)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(model.title).font(.headline)
        }
    }
}
