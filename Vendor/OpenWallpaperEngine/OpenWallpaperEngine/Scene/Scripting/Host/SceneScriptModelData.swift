import Foundation
import simd

/// Geometry a script made with `thisScene.createModelData` (WE's `IModelData`, lib.sceneScript.d.ts;
/// scenescript64.dll 0x18162fd40 parses the configuration, 0x1816362d9 hands it to the engine and
/// sets `__modelDataToken`). A model layer shows it through `createLayer({model: modelData})`:
/// `_Internal.stringifyConfig` writes the token as the object's numeric `model`
/// (`WESceneModel.Source.loadedID`), which WE's object factory resolves to the loaded data.
///
/// Each shape is one mesh: interleaved floats in the order `position` (3), `normal` (3),
/// `tangentSigned` (4), `uv` (2), `color` (4), the subset the shape's `vertexFormat` enables, which
/// is `.mdl`'s own table order (`MDLVertexAttribute.all`); an optional `Uint16Array`/`Uint32Array`
/// triangle list (without one the vertices are a triangle list); a material (an `IAssetHandle`),
/// drawn like a `.mdl` mesh's.
struct SceneScriptModelData: Equatable {
    struct Shape: Equatable {
        var format: MDLVertexFormat
        /// The material's paths to try, in order (under the script's Workshop item first,
        /// `SceneScriptLayerSource.assetPaths`).
        var materialPaths: [String]
        var vertices: Data
        /// Indices as the script gave them; nil draws the vertices as a triangle list.
        var indices: Data?
        var usesUInt32Indices: Bool
        /// `isVertexBufferDynamic` / `isIndexBufferDynamic`: `applyData` may change them.
        var dynamicVertices: Bool
        var dynamicIndices: Bool

        var vertexCount: Int { format.stride == 0 ? 0 : vertices.count / format.stride }
        var indexCount: Int { indices.map { $0.count / (usesUInt32Indices ? 4 : 2) } ?? vertexCount }

        /// The triangle list the GPU draws: the script's indices, or 0…n−1 (u32 then).
        var drawnIndices: Data {
            if let indices { return indices }
            var list = Data(count: vertexCount * 4)
            list.withUnsafeMutableBytes { raw in
                for vertex in 0..<vertexCount {
                    raw.storeBytes(of: UInt32(vertex).littleEndian, toByteOffset: vertex * 4, as: UInt32.self)
                }
            }
            return list
        }

        var drawsUInt32Indices: Bool { indices == nil || usesUInt32Indices }
    }

    var shapes: [Shape]
    /// `boundingBoxMins`/`boundingBoxMaxs` ("only necessary if you are animating the model
    /// geometry"), else the box of the shapes' positions when made.
    var bounds: MDLBounds

    /// The vertex format names in their required order, with the attribute each enables.
    static let formatOrder: [(name: String, attribute: MDLVertexAttribute)] = [
        ("position", .position), ("normal", .normal), ("tangentSigned", .tangent4), ("uv", .texCoord), ("color", .color),
    ]

    /// The format of a `vertexFormat` array; nil when a name is unknown, repeated or out of order
    /// ("Vertex format in incorrect order.").
    static func format(_ names: [String]) -> MDLVertexFormat? {
        var bits: UInt32 = 0
        var last = -1
        for name in names {
            guard let index = formatOrder.firstIndex(where: { $0.name == name }), index > last else { return nil }
            last = index
            bits |= formatOrder[index].attribute.mask
        }
        return MDLVertexFormat(rawValue: bits)
    }

    /// The box of every shape's positions; `MDLBounds.unbounded` without any.
    static func positionBounds(_ shapes: [Shape]) -> MDLBounds {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for shape in shapes {
            guard let offset = shape.format.offset(of: .position) else { continue }
            let stride = shape.format.stride
            shape.vertices.withUnsafeBytes { raw in
                for vertex in 0..<shape.vertexCount {
                    let base = vertex * stride + offset
                    let point = SIMD3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
            }
        }
        return low.x <= high.x ? MDLBounds(min: low, max: high) : .unbounded
    }
}

/// One shape's part of an `applyData`: only what the script passed (nil keeps the buffer).
struct SceneScriptModelDataUpdate: Equatable {
    var vertices: Data?
    var indices: Data?
    var indicesAreUInt32 = false
}

/// The model data one wallpaper instance's scripts made, by token. Scripts write it on their thread
/// (`SceneScriptObjectModel`); the loader reads it to plan a model layer and the renderer every
/// frame for the geometry `applyData` changed (`SceneModelGeometrySource`). One lock owns
/// `entries`, `generations`, `nextToken` and `viewers`.
final class SceneScriptModelDataStore {
    /// WE's messages (scenescript64.dll 0x18162fc80's table).
    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidToken, vertexBufferGrew, indexBufferGrew, notDynamic, indexType, addsShapes, inconsistentVertices

        var description: String {
            switch self {
            case .invalidToken: return "Invalid model data token"
            case .vertexBufferGrew: return "Vertex buffer size cannot increase"
            case .indexBufferGrew: return "Index buffer size cannot increase"
            case .notDynamic: return "Model data not created as dynamic"
            case .indexType: return "Incorrect index buffer type"
            case .addsShapes: return "Cannot add shapes in IModelData.update"
            case .inconsistentVertices: return "Inconsistent vertex buffer size"
            }
        }
    }

    private let lock = NSLock()
    private var entries: [Int: (data: SceneScriptModelData, revision: UInt64)] = [:]
    /// How many times each token's data was replaced (`replaceData`).
    private var generations: [Int: UInt64] = [:]
    private var nextToken = 1
    /// The model layers showing each token, told when `replaceData` replaces it.
    private var viewers: [Int: [WeakGeometry]] = [:]

    private struct WeakGeometry {
        weak var geometry: SceneScriptModelGeometry?
    }

    /// Stores new data; returns its token.
    func create(_ data: SceneScriptModelData) -> Int {
        lock.withLock {
            let token = nextToken
            nextToken += 1
            entries[token] = (data, 1)
            return token
        }
    }

    /// `replaceData`: new, possibly incompatible data under the same token. Every model layer
    /// showing it plans its model again from it, on the caller's thread (the script's), before
    /// this returns (`SceneScriptModelGeometry.dataReplaced`).
    func replace(_ token: Int, with data: SceneScriptModelData) throws {
        let (generation, geometries): (UInt64, [SceneScriptModelGeometry]) = try lock.withLock {
            guard let entry = entries[token] else { throw Failure.invalidToken }
            entries[token] = (data, entry.revision &+ 1)
            generations[token, default: 0] &+= 1
            viewers[token]?.removeAll { $0.geometry == nil }
            return (generations[token] ?? 0, viewers[token]?.compactMap(\.geometry) ?? [])
        }
        // Outside the lock: planning reads the store again (`geometry(newerThan:)`).
        for geometry in geometries { geometry.dataReplaced(data, generation: generation) }
    }

    /// Tells `geometry` when its token's data is replaced.
    func observe(_ token: Int, by geometry: SceneScriptModelGeometry) {
        lock.withLock { viewers[token, default: []].append(WeakGeometry(geometry: geometry)) }
    }

    /// `applyData`: new contents for dynamic buffers of the same or a smaller size.
    func apply(_ token: Int, _ updates: [SceneScriptModelDataUpdate]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw Failure.invalidToken }
        guard updates.count <= entry.data.shapes.count else { throw Failure.addsShapes }
        for (index, update) in updates.enumerated() {
            var shape = entry.data.shapes[index]
            if let vertices = update.vertices {
                guard shape.dynamicVertices else { throw Failure.notDynamic }
                guard vertices.count <= shape.vertices.count else { throw Failure.vertexBufferGrew }
                guard shape.format.stride > 0, vertices.count % shape.format.stride == 0 else {
                    throw Failure.inconsistentVertices
                }
                shape.vertices = vertices
            }
            if let indices = update.indices {
                guard shape.dynamicIndices else { throw Failure.notDynamic }
                guard update.indicesAreUInt32 == shape.usesUInt32Indices else { throw Failure.indexType }
                guard indices.count <= (shape.indices?.count ?? 0) else { throw Failure.indexBufferGrew }
                shape.indices = indices
            }
            entry.data.shapes[index] = shape
        }
        entry.revision &+= 1
        entries[token] = entry
    }

    /// `destroyModelData`: a layer still showing it keeps what it has.
    func destroy(_ token: Int) {
        lock.withLock { _ = entries.removeValue(forKey: token) }
    }

    /// The data under `token` now, with its revision (bumped by every change).
    func snapshot(_ token: Int) -> (data: SceneScriptModelData, revision: UInt64)? {
        lock.withLock { entries[token] }
    }

    /// The data under `token` with how many times it was replaced; nil when there is none.
    func replaced(_ token: Int) -> (data: SceneScriptModelData, generation: UInt64)? {
        lock.withLock { entries[token].map { ($0.data, generations[token] ?? 0) } }
    }
}

/// A model layer's view of its model data (`SceneModelPlan.geometry`): the meshes' vertices and
/// triangle lists as the scripts last left them, and a new plan once `replaceData` replaced them.
///
/// WE re-creates a model whose data a script replaced, whatever its shapes now are (other counts,
/// formats, materials or index types; scenescript64.dll hands the new data to the engine as
/// `createModelData` does, 0x1816362d9), within the script's call. The new plan is made there too,
/// on the script's thread (`dataReplaced`), where the loader's asset reads are owned by its scene
/// lock; the render thread only takes the finished plan (`replacement(for:)`). `lock` owns
/// `replan`, `handedGeneration` and `ready`.
final class SceneScriptModelGeometry: SceneModelGeometrySource {
    private let store: SceneScriptModelDataStore
    let token: Int
    private let lock = NSLock()
    private var planner: ((SceneScriptModelData) -> SceneModelPlan?)?
    /// The replacement whose plan the renderer took last (0: the plan the layer was made with).
    private var handedGeneration: UInt64
    /// The newest replacement's plan, made and not yet taken; nil plans nothing that draws.
    private var ready: (plan: SceneModelPlan?, generation: UInt64)?

    init(store: SceneScriptModelDataStore, token: Int) {
        self.store = store
        self.token = token
        handedGeneration = store.replaced(token)?.generation ?? 0
        store.observe(token, by: self)
    }

    /// Plans the model again from replaced data (the loader's `SceneScriptModelPlanBuilder`,
    /// under the loader's lock). Called on the thread that replaced the data.
    var replan: ((SceneScriptModelData) -> SceneModelPlan?)? {
        get { lock.withLock { planner } }
        set { lock.withLock { planner = newValue } }
    }

    /// `replaceData` replaced the data (`SceneScriptModelDataStore.replace`, on its caller's
    /// thread): plans the model from it for the renderer to take.
    func dataReplaced(_ data: SceneScriptModelData, generation: UInt64) {
        guard let replan else { return }
        let plan = replan(data)
        lock.withLock {
            // Two replacements racing to plan: the newer one wins.
            guard generation > max(ready?.generation ?? 0, handedGeneration) else { return }
            ready = (plan, generation)
        }
    }

    /// The plan of the data `replaceData` last left, once, on the render thread: made already, it
    /// reads nothing of the loader's. Nil when nothing was replaced since, or when the new data
    /// plans nothing that draws (logged by the builder): the model keeps what it drew.
    func replacement(for plan: SceneModelPlan) -> SceneModelPlan? {
        lock.withLock {
            guard let ready else { return nil }
            self.ready = nil
            handedGeneration = ready.generation
            return ready.plan
        }
    }

    func geometry(newerThan revision: UInt64) -> SceneModelGeometry? {
        guard let (data, current) = store.snapshot(token), current != revision else { return nil }
        return SceneModelGeometry(revision: current, meshes: data.shapes.map {
            .init(vertices: $0.vertices, indices: $0.drawnIndices, indexCount: $0.indexCount)
        })
    }
}
