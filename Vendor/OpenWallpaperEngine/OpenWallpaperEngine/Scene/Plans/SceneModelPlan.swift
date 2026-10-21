import Foundation
import Metal
import simd

/// A model object's `.mdl` ready to draw (docs/models-plan.md §2.6, §4.3 M5): each mesh with the
/// material its object's `skin` picks, planned through WE's shader (`ModelMaterialPlan`), its
/// interleaved vertices and indices as the file has them, the model's box, and the skeleton,
/// clips and attachment points its animation layers and children use. Shared by every object
/// drawing the same `.mdl` with the same skin. A final class so the renderer can key state on it.
final class SceneModelPlan {
    struct Mesh {
        /// The mesh's index in the `.mdl`.
        let index: Int
        let material: ModelMaterialPlan
        let format: MDLVertexFormat
        let usesUInt32Indices: Bool
        let indexCount: Int
        /// The mesh's own box (`MDLV` ≥ 17), for culling it apart from the model's; nil when
        /// unknown or when its vertices move in the shader (skinning, morphs), so the box can't hold them.
        var bounds: MDLBounds? = nil
        /// Whether its vertices move in the shader (skinning, morphs), past any box the file stores.
        var deforms = false
        /// The vertex and index bytes; after the upload (`SceneModelPlan.upload`) they read the
        /// GPU buffers' shared storage instead of a second CPU copy.
        fileprivate let bytes: MeshBytes

        var vertexData: Data { bytes.vertices }
        var indexData: Data { bytes.indices }

        init(index: Int, material: ModelMaterialPlan, format: MDLVertexFormat, vertexData: Data, indexData: Data,
             usesUInt32Indices: Bool, indexCount: Int, bounds: MDLBounds? = nil, deforms: Bool = false) {
            self.index = index
            self.material = material
            self.format = format
            self.usesUInt32Indices = usesUInt32Indices
            self.indexCount = indexCount
            self.bounds = bounds
            self.deforms = deforms
            bytes = MeshBytes(vertices: vertexData, indices: indexData)
        }
    }

    /// A mesh's bytes, swapped once for views of its GPU buffers. Guarded by the plan's `uploadLock`.
    fileprivate final class MeshBytes {
        private let lock = NSLock()
        private var storedVertices: Data
        private var storedIndices: Data
        init(vertices: Data, indices: Data) {
            storedVertices = vertices
            storedIndices = indices
        }
        var vertices: Data { lock.withLock { storedVertices } }
        var indices: Data { lock.withLock { storedIndices } }
        func replace(vertices: Data, indices: Data) {
            lock.withLock {
                storedVertices = vertices
                storedIndices = indices
            }
        }
    }

    /// The meshes' GPU buffers, made once (`upload`), in `meshes` order. Owned by `uploadLock`.
    private let uploadLock = NSLock()
    private var uploaded: [SceneModelRenderer.MeshBuffers?]?

    /// The meshes' GPU buffers, made on the first call (the content's background load, so the
    /// first frame has nothing to upload) and shared after. Once made, each mesh's bytes read
    /// the buffers' shared storage and the loaded copy is released (the buffers live as long as
    /// the plan, so a later reader still sees the same bytes). Any thread.
    func upload(device: MTLDevice) -> [SceneModelRenderer.MeshBuffers?] {
        uploadLock.lock()
        defer { uploadLock.unlock() }
        if let uploaded { return uploaded }
        let made = meshes.map { mesh -> SceneModelRenderer.MeshBuffers? in
            let vertices = mesh.vertexData, indices = mesh.indexData
            guard let buffers = SceneModelRenderer.makeMeshBuffers(device: device, format: mesh.format,
                                                                   vertices: vertices, indices: indices,
                                                                   uint32: mesh.usesUInt32Indices,
                                                                   indexCount: mesh.indexCount)
            else { return nil }
            // Split streams don't hold the interleaved bytes; that mesh keeps its loaded vertices.
            mesh.bytes.replace(vertices: buffers.attributes == nil ? Self.view(of: buffers.vertices, count: vertices.count)
                                                                   : vertices,
                               indices: Self.view(of: buffers.indices, count: indices.count))
            return buffers
        }
        uploaded = made
        return made
    }

    /// `count` bytes of `buffer`'s shared storage, keeping the buffer alive while the data is.
    private static func view(of buffer: MTLBuffer, count: Int) -> Data {
        guard buffer.storageMode == .shared, count <= buffer.length else {
            return Data(bytes: buffer.contents(), count: min(count, buffer.length))
        }
        return Data(bytesNoCopy: buffer.contents(), count: count, deallocator: .custom { _, _ in
            withExtendedLifetime(buffer) {}
        })
    }

    /// The `.mdl` path, for logging.
    let path: String
    /// The meshes that draw, in WE's draw-list order (`drawOrder`): the ones whose material
    /// doesn't translate are left out (logged).
    let meshes: [Mesh]
    /// The model's box (the union of its meshes', or unbounded; `MDLModel.bounds`).
    let bounds: MDLBounds
    /// The box the whole model (and its shadow caster) is culled by: `bounds`, or unbounded when a
    /// mesh deforms. A pose draws a skinned or morphed mesh past the rest-pose box the file stores,
    /// so, as its own mesh test already skips it, that box can't cull the model either: a limb
    /// swung into view would vanish while the rest box stays outside it.
    var cullBounds: MDLBounds { meshes.contains(where: \.deforms) ? .unbounded : bounds }
    let skeleton: MDLSkeleton?
    let clips: [MDLAnimation]
    let attachments: [MDLAttachment]
    /// Where a script-made model's changing geometry comes from (`IModelData.applyData`); nil for
    /// a `.mdl`, whose meshes' data never change. `Mesh.index` is the shape's index there.
    let geometry: SceneModelGeometrySource?
    /// The meshes' blend shapes (`MDMP`); nil without any.
    let morphs: SceneModelMorphs?

    init(path: String, meshes: [Mesh], bounds: MDLBounds, skeleton: MDLSkeleton?, clips: [MDLAnimation] = [],
         attachments: [MDLAttachment] = [], geometry: SceneModelGeometrySource? = nil, morphs: SceneModelMorphs? = nil) {
        self.path = path
        self.meshes = Self.drawOrder(meshes)
        self.bounds = bounds
        self.skeleton = skeleton
        self.clips = clips
        self.attachments = attachments
        self.geometry = geometry
        self.morphs = morphs
    }

    /// WE's translucent flag (0x140225241): every mesh blending normal or alpha-to-coverage clears
    /// it, so a model is translucent only when none of its meshes is opaque.
    var isTranslucent: Bool { !meshes.contains { $0.material.isOpaque } }

    /// The layers whose image a mesh samples (`_rt_imageLayerComposite_<id>_a`), by object id.
    var compositeLayerIDs: Set<String> {
        Set(meshes.flatMap { mesh in
            mesh.material.passes.flatMap { material in
                material.pass.textures.values.compactMap { input -> String? in
                    if case .fbo(let name) = input { return ModelMaterialPlanBuilder.compositeLayerID(name) }
                    return nil
                }
            }
        })
    }

    /// The skeleton's bone count (0 without one).
    var boneCount: Int { skeleton?.bones.count ?? 0 }

    /// WE's mesh draw list (sorted with 0x14021a620, which orders a mesh with an opaque material
    /// before one with a translucent material and leaves the rest as they are): the opaque meshes
    /// first, then the translucent ones, each in file order [I: stable].
    static func drawOrder(_ meshes: [Mesh]) -> [Mesh] {
        meshes.filter { $0.material.isOpaque } + meshes.filter { !$0.material.isOpaque }
    }

    /// The animator that poses this model from its object's animation layers; nil for a model
    /// without bones. A layer naming no clip of the `.mdl` makes no layer (logged). `rootMotion`
    /// is the object's `rootmotion`.
    /// `objectID`: the scene object's id, whose layers' timelines run in the wallpaper's
    /// `SceneAnimationSet`.
    func makeAnimator(layers: [WEAnimationLayer], objectName: String, rootMotion: Bool = true,
                      objectID: Int? = nil) -> ScenePuppetAnimator? {
        guard let skeleton, !skeleton.bones.isEmpty else { return nil }
        return ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: layers,
                                   morphRig: morphs.map(SceneMorphRig.model), model: true, rootMotion: rootMotion,
                                   objectID: objectID) { [path] layer in
            OWELog.error(.scene, "Model \(objectName) (\(path)) has no clip \(layer.animation.map(String.init) ?? "(none)") for "
                         + "animation layer \(layer.name ?? "?"); WE makes no layer for it")
        }
    }
}

/// A model's meshes' vertices and triangle lists at one revision (`SceneModelGeometrySource`).
struct SceneModelGeometry {
    struct Mesh {
        let vertices: Data
        let indices: Data
        let indexCount: Int
    }

    let revision: UInt64
    let meshes: [Mesh]
}

/// Geometry that changes after load (a script's `IModelData`, `SceneScriptModelGeometry`); the
/// renderer asks for it every frame and re-uploads a newer revision.
protocol SceneModelGeometrySource: AnyObject {
    /// The geometry now, or nil when it is still at `revision`.
    func geometry(newerThan revision: UInt64) -> SceneModelGeometry?
    /// A new plan for the model when its data was replaced since `plan` was made (a script's
    /// `replaceData`, after which WE re-creates the model); nil keeps `plan`.
    func replacement(for plan: SceneModelPlan) -> SceneModelPlan?
}
