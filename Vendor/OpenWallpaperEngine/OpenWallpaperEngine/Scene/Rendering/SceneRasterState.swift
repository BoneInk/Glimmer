import Metal

/// A material pass's depth and cull state (docs/models-plan.md §2.4): WE's pass bytes `depthtest`
/// (+0x1f2), `depthwrite` (+0x1f3) and `cullmode` (+0x1f4), parsed at 0x1401577e0. The pass
/// constructor zeroes them (0x140151680), so a key the material leaves out keeps the **engine
/// default: depth test on, depth write on, back faces culled**. 2D materials author all three off.
struct SceneRasterState: Hashable {
    var depthTest = true
    var depthWrite = true
    var cullsBackFaces = true

    /// WE's defaults, for a pass that authors none of the keys.
    static let engineDefault = SceneRasterState()
    /// Neither test nor write nor cull: what every 2D material authors.
    static let disabled = SceneRasterState(depthTest: false, depthWrite: false, cullsBackFaces: false)

    init(depthTest: Bool = true, depthWrite: Bool = true, cullsBackFaces: Bool = true) {
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cullsBackFaces = cullsBackFaces
    }

    /// The pass keys as authored: `depthtest`/`depthwrite` "enabled" (0) or "disabled" (1),
    /// `cullmode` "normal" (0, back faces) or "nocull" (1). A missing or unknown value keeps the
    /// default (the enum parser leaves the zeroed byte). `blending` is the pass's: a translucent or
    /// additive draw never writes depth (`writesDepth(blending:)`).
    init(depthtest: String?, depthwrite: String?, cullmode: String?, blending: String? = nil) {
        depthTest = depthtest?.lowercased() != "disabled"
        depthWrite = depthwrite?.lowercased() != "disabled" && Self.writesDepth(blending: blending)
        cullsBackFaces = cullmode?.lowercased() != "nocull"
    }

    /// Whether a draw with this blending can write depth. WE's pass only pushes the states that
    /// differ from the context's (0x140157160…0x1401571dc: blending, then depth test, write and
    /// cull when "disabled"), and the context picks its depth-stencil state when it draws
    /// (0x140099f84): the index is the pass's depth bits ORed with 1, "no write", whenever the
    /// blend byte is translucent (1) or additive (2); normal (0) and alpha-to-coverage (3) keep
    /// the authored write. So nothing blended writes depth, whatever its material authors
    /// (3455121165's orbit rings are translucent images authoring `depthwrite` "enabled").
    static func writesDepth(blending: String?) -> Bool {
        !["translucent", "additive"].contains(blending?.lowercased() ?? "")
    }

    /// A text object's state: WE draws it through `materials/fonts/basefont_depth.json` (test on)
    /// when the object's `depthtest` is set, else `basefont.json` (test off); both are `nocull`
    /// (0x1401b385e…0x1401b38b5) and translucent, so neither writes depth (`writesDepth`).
    static func text(depthTest: Bool) -> SceneRasterState {
        SceneRasterState(depthTest: depthTest, depthWrite: false, cullsBackFaces: false)
    }

    /// WE's three depth-stencil states (0x140099050): test and write, test only, off. D3D writes
    /// nothing with the test disabled, so "write without test" is off too.
    enum DepthMode: Hashable {
        case testAndWrite, testOnly, off
    }

    var depthMode: DepthMode {
        guard depthTest else { return .off }
        return depthWrite ? .testAndWrite : .testOnly
    }

    var cullMode: MTLCullMode { cullsBackFaces ? .back : .none }
}

/// The scene pass's depth buffer (docs/models-plan.md §2.4): `depth32Float`, **reversed**, WE's
/// states compare GREATER, and the depth-stencil states and cull mode each draw sets from its
/// `SceneRasterState`. One per renderer; made on the render thread.
///
/// **Depth values.** WE clears depth to 0, its far plane (0x14009b130). The translated vertex
/// stages map WE's clip z to Metal's depth as (z + w) / 2 (`--fixup-clipspace`, see
/// `SceneVolumetrics`), so WE's depth d is stored as (d + 1) / 2: the clear value is 0.5, and the
/// native draws that share the buffer (`sceneVertex3D`) write the same mapping.
final class SceneDepthStates {
    /// The format of every depth attachment the scene pass has (WE's is D16 or D32F, §2.4; open
    /// point 6).
    static let format = MTLPixelFormat.depth32Float
    /// WE's clear value 0 through the translator's (z + w) / 2.
    static let clearDepth: Double = 0.5

    private let states: [SceneRasterState.DepthMode: MTLDepthStencilState]
    /// The states of a pass drawn through a mirrored view (the planar reflection, docs/models-plan.md
    /// §2.11): its mirror flips every triangle's winding, and WE flips its cull mode there
    /// (0x14018070e), so the front faces are the other winding.
    let mirrored: Bool

    init?(device: MTLDevice, mirrored: Bool = false) {
        self.mirrored = mirrored
        var states: [SceneRasterState.DepthMode: MTLDepthStencilState] = [:]
        for mode in [SceneRasterState.DepthMode.testAndWrite, .testOnly, .off] {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = mode == .off ? .always : .greater
            descriptor.isDepthWriteEnabled = mode == .testAndWrite
            descriptor.label = "scene depth \(mode)"
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else { return nil }
            states[mode] = state
        }
        self.states = states
    }

    func state(_ raster: SceneRasterState) -> MTLDepthStencilState {
        states[raster.depthMode]!
    }

    /// Sets `raster`'s depth-stencil state and cull mode for the draws that follow. `front` is the
    /// winding of the draw's front faces in an unmirrored pass (the other one when `mirrored`).
    /// WE's is D3D's `FrontCounterClockwise = FALSE` (0x1400990f9) for every draw; the translated
    /// stages write WE's clip position, so a draw whose vertices are WE's (models, particles:
    /// `SceneModelRenderer.frontFacing`) takes that rule, and the layers' quads, which wind their
    /// own way, pair it with clockwise (the default).
    func apply(_ raster: SceneRasterState, to encoder: MTLRenderCommandEncoder, front: MTLWinding = .clockwise) {
        encoder.setDepthStencilState(state(raster))
        let flipped: MTLWinding = front == .clockwise ? .counterClockwise : .clockwise
        encoder.setFrontFacing(mirrored ? flipped : front)
        encoder.setCullMode(raster.cullMode)
    }
}
