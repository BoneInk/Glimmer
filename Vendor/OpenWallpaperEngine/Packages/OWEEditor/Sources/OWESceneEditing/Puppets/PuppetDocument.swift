import Foundation
import simd

/// A Puppet Warp rig as the editor holds it (docs/models-plan.md §1, §2.13): the image's mesh,
/// its bones, the vertices' weights, the clips and the image's animation layers. It is written
/// as WE's `.mdl` (`PuppetMDLWriter`: `MDLV0023`, `MDLS0004`, `MDLA0006`, the versions WE's
/// editor writes today) and read back from any version WE's runtime reads (`PuppetMDLReader`).
///
/// Coordinates are WE's: the image's pixels, centred on the image, y up (every library rig puts
/// a vertex at `(uv − ½) · size`, v flipped). Bones are local to their parent, parents first.
/// The document is a value; the editor keeps it in the overlay (`SceneEditOverlay.puppets`) and
/// writes the files on Save as New Wallpaper (`PuppetSceneBake`).
public struct PuppetDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = PuppetDocument.currentVersion
    /// The image's size in pixels: the mesh's space.
    public var imageSize: SIMD2<Float>
    /// The material path the mesh names (WE's editor writes the image's material).
    public var material: String
    /// The `.mdl` the document was loaded from, nil for a puppet made in the editor.
    public var sourcePath: String?
    public var mesh: PuppetMesh
    public var bones: [PuppetBone]
    /// One entry per vertex: at most four bones, weights summing to 1 (`normalizedWeights`).
    public var weights: [[PuppetWeight]]
    public var clips: [PuppetClip]
    /// The image's `animationlayers` in evaluation order.
    public var layers: [PuppetAnimationLayer]
    /// What the editor doesn't edit but keeps while it stays valid (attachments, the reference
    /// pose, blend shapes, per-bone blocks).
    public var preserved: PuppetPreservedData
    /// The clipping masks (`PuppetClipping`); nil without.
    public var clipping: PuppetClipping?

    public init(imageSize: SIMD2<Float>, material: String, sourcePath: String? = nil, mesh: PuppetMesh = PuppetMesh(),
                bones: [PuppetBone] = [], weights: [[PuppetWeight]] = [], clips: [PuppetClip] = [],
                layers: [PuppetAnimationLayer] = [], preserved: PuppetPreservedData = PuppetPreservedData(),
                clipping: PuppetClipping? = nil) {
        self.imageSize = imageSize
        self.material = material
        self.sourcePath = sourcePath
        self.mesh = mesh
        self.bones = bones
        self.weights = weights
        self.clips = clips
        self.layers = layers
        self.preserved = preserved
        self.clipping = clipping
    }

    /// A new rig over an image: no mesh and one root bone at the image's centre.
    public static func new(imageSize: SIMD2<Float>, material: String) -> PuppetDocument {
        PuppetDocument(imageSize: imageSize, material: material,
                       bones: [PuppetBone(name: "root", parent: nil, local: .identity)])
    }

    // MARK: Texture layout

    /// The texture coordinate of a point of the mesh's space where the image lies as stored.
    public func textureCoordinate(of point: SIMD2<Float>) -> SIMD2<Float> {
        guard imageSize.x > 0, imageSize.y > 0 else { return SIMD2(0.5, 0.5) }
        return SIMD2(point.x / imageSize.x + 0.5, 0.5 - point.y / imageSize.y)
    }

    /// Whether every vertex sits where its texture coordinate puts it in the image, within a
    /// pixel: the bind pose is the texture's layout (`ScenePuppetPlan.isTextureLayout`). A moved
    /// vertex then takes its texture coordinate with it.
    public var isTextureLayout: Bool {
        mesh.vertices.allSatisfy { vertex in
            let expected = SIMD2((vertex.uv.x - 0.5) * imageSize.x, (0.5 - vertex.uv.y) * imageSize.y)
            return simd_reduce_max(simd_abs(vertex.position - expected)) <= 1
        }
    }

    // MARK: Bones

    public func children(of bone: Int) -> [Int] {
        bones.indices.filter { bones[$0].parent == bone }
    }

    /// `bone` and every bone below it.
    public func subtree(of bone: Int) -> Set<Int> {
        var result: Set<Int> = [bone]
        for index in bones.indices where index > bone {
            if let parent = bones[index].parent, result.contains(parent) { result.insert(index) }
        }
        return result
    }

    /// The bind pose's model-space matrices, parents first.
    public var bindWorlds: [simd_float4x4] {
        PuppetMath.worlds(locals: bones.map(\.local.matrix), parents: bones.map(\.parent))
    }

    /// The pose every frame starts from: the rest transforms where the rig has them.
    public var restLocals: [PuppetTransform] { bones.map { $0.rest ?? $0.local } }

    /// A name no bone has: `base`, else `base 2`, `base 3`…
    public func uniqueBoneName(_ base: String) -> String {
        let names = Set(bones.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Adds a bone whose head is at `head` (model space) under `parent`; returns its index.
    @discardableResult
    public mutating func addBone(named name: String, parent: Int?, head: SIMD2<Float>, angle: Float = 0,
                                 length: Float? = nil) -> Int {
        let parentWorld = parent.map { bindWorlds[$0] } ?? matrix_identity_float4x4
        let world = PuppetMath.matrix(translation: SIMD3(head.x, head.y, 0), euler: SIMD3(0, 0, angle), scale: SIMD3(repeating: 1))
        let local = PuppetTransform(matrix: parentWorld.inverse * world)
        bones.append(PuppetBone(name: uniqueBoneName(name), parent: parent, local: local, length: length))
        for clip in clips.indices {
            clips[clip].tracks.append(PuppetTrack())
            clips[clip].boneAlphaTracks?.append(PuppetChannelTrack(tag: 0, samples: [1]))
            clips[clip].boneDepthTracks?.append(PuppetChannelTrack(tag: 0, samples: [0]))
        }
        preserved.boneAdded(count: bones.count)
        return bones.count - 1
    }

    /// Moves a bone's head to `head` in model space; its children move with it, or with
    /// `keepingChildren` stay where they are.
    public mutating func moveBone(_ bone: Int, toHead head: SIMD2<Float>, keepingChildren: Bool = false) {
        var worlds = bindWorlds
        let old = worlds[bone]
        worlds[bone].columns.3 = SIMD4(head.x, head.y, old.columns.3.z, 1)
        if keepingChildren {
            setWorld(worlds[bone], of: bone, keepingChildren: worlds)
        } else {
            let parentWorld = bones[bone].parent.map { worlds[$0] } ?? matrix_identity_float4x4
            let before = bones[bone].local
            bones[bone].local = PuppetTransform(matrix: parentWorld.inverse * worlds[bone])
            let moved = bones[bone].local.translation - before.translation
            if bones[bone].rest != nil { bones[bone].rest?.translation += moved }
        }
    }

    /// Turns a bone to `angle` (radians about z, model space) about its head; its children turn
    /// with it.
    public mutating func rotateBone(_ bone: Int, toAngle angle: Float) {
        let parentWorld = bones[bone].parent.map { bindWorlds[$0] } ?? matrix_identity_float4x4
        let parentAngle = PuppetMath.angle(of: parentWorld)
        var local = bones[bone].local
        let delta = angle - parentAngle - local.euler.z
        local.euler.z += delta
        let restDelta = delta
        bones[bone].local = local
        if bones[bone].rest != nil { bones[bone].rest?.euler.z += restDelta }
    }

    /// Sets bone `bone`'s model-space matrix, its children's locals rewritten so their own model
    /// matrices (`worlds`, from before) don't move.
    private mutating func setWorld(_ world: simd_float4x4, of bone: Int, keepingChildren worlds: [simd_float4x4]) {
        let parentWorld = bones[bone].parent.map { worlds[$0] } ?? matrix_identity_float4x4
        let before = bones[bone].local
        bones[bone].local = PuppetTransform(matrix: parentWorld.inverse * world)
        if var rest = bones[bone].rest {
            rest.translation += bones[bone].local.translation - before.translation
            bones[bone].rest = rest
        }
        for child in children(of: bone) {
            let childBefore = bones[child].local
            bones[child].local = PuppetTransform(matrix: world.inverse * worlds[child])
            if var rest = bones[child].rest {
                rest.translation += bones[child].local.translation - childBefore.translation
                bones[child].rest = rest
            }
        }
    }

    /// Gives `bone` a new parent (nil: a root), keeping it where it is. A bone can't go under
    /// itself or one of its children: then nothing changes and the result is false.
    @discardableResult
    public mutating func reparent(_ bone: Int, to parent: Int?) -> Bool {
        if let parent, subtree(of: bone).contains(parent) { return false }
        let worlds = bindWorlds
        let parentWorld = parent.map { worlds[$0] } ?? matrix_identity_float4x4
        bones[bone].local = PuppetTransform(matrix: parentWorld.inverse * worlds[bone])
        bones[bone].parent = parent
        orderParentsFirst()
        return true
    }

    /// Deletes a bone; its children go to its parent and its vertices' weights to the others.
    /// The last bone can't go.
    public mutating func deleteBone(_ bone: Int) {
        guard bones.count > 1, bones.indices.contains(bone) else { return }
        let worlds = bindWorlds
        let parent = bones[bone].parent
        // Its vertices go to its parent, else its first child, else the first other bone.
        let heir = parent ?? children(of: bone).first ?? bones.indices.first { $0 != bone }!
        weights = weights.map { entries in
            PuppetWeight.normalized(entries.map { $0.bone == bone ? PuppetWeight(bone: heir, weight: $0.weight) : $0 })
        }
        for child in children(of: bone) {
            let parentWorld = parent.map { worlds[$0] } ?? matrix_identity_float4x4
            bones[child].local = PuppetTransform(matrix: parentWorld.inverse * worlds[child])
            bones[child].parent = parent
        }
        var map: [Int?] = Array(bones.indices)
        map[bone] = nil
        for index in (bone + 1)..<bones.count { map[index] = index - 1 }
        remapBones(map, count: bones.count - 1, order: bones.indices.filter { $0 != bone })
    }

    /// Reorders the bones so every parent comes before its children (WE's `MDLS` order).
    public mutating func orderParentsFirst() {
        var order: [Int] = []
        var placed = Set<Int>()
        func place(_ bone: Int, _ depth: Int) {
            guard !placed.contains(bone), depth <= bones.count else { return }
            if let parent = bones[bone].parent, !placed.contains(parent) { place(parent, depth + 1) }
            placed.insert(bone)
            order.append(bone)
        }
        for bone in bones.indices { place(bone, 0) }
        guard order != Array(bones.indices) else { return }
        var map = [Int?](repeating: nil, count: bones.count)
        for (new, old) in order.enumerated() { map[old] = new }
        remapBones(map, count: bones.count, order: order)
    }

    /// Applies a bone renumbering: `map[old]` is the new index (nil: deleted), `order` the old
    /// indices in their new order.
    mutating func remapBones(_ map: [Int?], count: Int, order: [Int]) {
        bones = order.map { old in
            var bone = bones[old]
            bone.parent = bone.parent.flatMap { map[$0] }
            return bone
        }
        weights = weights.map { entries in
            PuppetWeight.normalized(entries.compactMap { entry in
                map.indices.contains(entry.bone) ? map[entry.bone].map { PuppetWeight(bone: $0, weight: entry.weight) } : nil
            })
        }
        for clip in clips.indices {
            let tracks = clips[clip].tracks
            clips[clip].tracks = order.map { tracks.indices.contains($0) ? tracks[$0] : PuppetTrack() }
            if let alpha = clips[clip].boneAlphaTracks {
                clips[clip].boneAlphaTracks = order.map { alpha.indices.contains($0) ? alpha[$0] : PuppetChannelTrack(tag: 0, samples: [1]) }
            }
            if let depth = clips[clip].boneDepthTracks {
                clips[clip].boneDepthTracks = order.map { depth.indices.contains($0) ? depth[$0] : PuppetChannelTrack(tag: 0, samples: [0]) }
            }
            if let root = clips[clip].rootMotion?.rootBone {
                clips[clip].rootMotion?.rootBone = map.indices.contains(root) ? map[root] : nil
            }
        }
        preserved.remapBones(map, order: order)
        remapBlendRules(map)
    }

    // MARK: Mesh

    /// Replaces the mesh, every vertex unweighted. Blend shapes no longer match and go.
    public mutating func replaceMesh(_ mesh: PuppetMesh) {
        self.mesh = mesh
        weights = Array(repeating: [], count: mesh.vertices.count)
        preserved.meshChanged()
        clippingTopologyChanged()
    }

    /// Adds a vertex at `position`, inside the triangle it falls in (split in three) or joined to
    /// the nearest edge of the outline; its weights are its neighbours'. Returns its index.
    @discardableResult
    public mutating func addVertex(at position: SIMD2<Float>) -> Int {
        let uv = textureCoordinate(of: position)
        let index = mesh.vertices.count
        mesh.vertices.append(PuppetVertex(position: position, uv: uv))
        weights.append([])
        if let triangle = mesh.triangle(containing: position) {
            let t = mesh.triangles[triangle]
            mesh.triangles.remove(at: triangle)
            mesh.triangles += [SIMD3(t.x, t.y, UInt32(index)), SIMD3(t.y, t.z, UInt32(index)), SIMD3(t.z, t.x, UInt32(index))]
            weights[index] = PuppetWeight.average([weights[Int(t.x)], weights[Int(t.y)], weights[Int(t.z)]])
        } else if let edge = mesh.nearestBoundaryEdge(to: position) {
            mesh.triangles.append(SIMD3(edge.0, edge.1, UInt32(index)).orientedCounterClockwise(mesh.vertices))
            weights[index] = PuppetWeight.average([weights[Int(edge.0)], weights[Int(edge.1)]])
        }
        preserved.meshChanged()
        clippingTopologyChanged()
        return index
    }

    /// Moves vertex `index` to `position`; in a texture-laid rig its texture coordinate follows.
    public mutating func moveVertex(_ index: Int, to position: SIMD2<Float>, textureLayout: Bool) {
        guard mesh.vertices.indices.contains(index) else { return }
        let before = mesh.vertices[index].position
        mesh.vertices[index].position = position
        if textureLayout {
            mesh.vertices[index].uv = textureCoordinate(of: position)
        } else if imageSize.x > 0, imageSize.y > 0 {
            let delta = position - before
            mesh.vertices[index].uv += SIMD2(delta.x / imageSize.x, -delta.y / imageSize.y)
        }
    }

    /// Deletes vertices and the triangles that use them.
    public mutating func deleteVertices(_ indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        var map = [Int?](repeating: nil, count: mesh.vertices.count)
        var next = 0
        for index in mesh.vertices.indices where !indices.contains(index) {
            map[index] = next
            next += 1
        }
        mesh.vertices = mesh.vertices.indices.filter { !indices.contains($0) }.map { mesh.vertices[$0] }
        weights = weights.indices.filter { !indices.contains($0) }.map { weights[$0] }
        mesh.triangles = mesh.triangles.compactMap { t in
            guard let a = map[Int(t.x)], let b = map[Int(t.y)], let c = map[Int(t.z)] else { return nil }
            return SIMD3(UInt32(a), UInt32(b), UInt32(c))
        }
        preserved.meshChanged()
        clippingTopologyChanged()
    }

    // MARK: Clips

    /// An id no clip has (what an animation layer's `animation` names).
    public var nextClipID: UInt64 { (clips.map(\.id).max() ?? 0) + 1 }

    /// An id no layer has.
    public var nextLayerID: Int { (layers.map(\.id).max() ?? 0) + 1 }

    /// Adds a clip with an empty track per bone; returns its index.
    @discardableResult
    public mutating func addClip(named name: String, fps: Float = 30, frames: Int = 60, mode: PuppetClip.Mode = .loop) -> Int {
        clips.append(PuppetClip(id: nextClipID, name: name, mode: mode, fps: fps, frames: frames,
                                tracks: Array(repeating: PuppetTrack(), count: bones.count)))
        return clips.count - 1
    }

    /// Deletes a clip and the layers that play it.
    public mutating func deleteClip(_ index: Int) {
        guard clips.indices.contains(index) else { return }
        let id = clips[index].id
        clips.remove(at: index)
        layers.removeAll { $0.clipID == id }
        for bone in bones.indices where bones[bone].blendRules != nil {
            for rule in bones[bone].blendRules!.indices { bones[bone].blendRules![rule].weights[id] = nil }
        }
        for bone in bones.indices where bones[bone].ik != nil {
            bones[bone].ik!.targetKeys[id] = nil
            bones[bone].ik!.orientationKeys[id] = nil
        }
        for clip in clips.indices {
            guard let source = clips[clip].rootMotion?.sourceClip else { continue }
            if source == index { clips[clip].rootMotion?.sourceClip = nil } else if source > index { clips[clip].rootMotion?.sourceClip = source - 1 }
        }
    }

    // MARK: Checks

    /// What keeps the document from being written as WE reads it; empty when it can be.
    public var problems: [PuppetProblem] {
        var problems: [PuppetProblem] = []
        if bones.isEmpty { problems.append(.noBones) }
        if bones.count > PuppetMDLWriter.maximumBones { problems.append(.tooManyBones(bones.count)) }
        if mesh.vertices.isEmpty || mesh.triangles.isEmpty { problems.append(.noMesh) }
        if weights.contains(where: \.isEmpty) { problems.append(.unweightedVertices(weights.filter(\.isEmpty).count)) }
        return problems
    }
}

/// Why a document can't be written yet.
public enum PuppetProblem: Hashable, Sendable {
    case noBones
    case tooManyBones(Int)
    case noMesh
    case unweightedVertices(Int)
}

// MARK: - Mesh

public struct PuppetVertex: Codable, Hashable, Sendable {
    /// The bind pose: the image's pixels, centred, y up.
    public var position: SIMD2<Float>
    /// The texture coordinate, v down.
    public var uv: SIMD2<Float>
    /// The bind pose's z, as a rig read from a wallpaper has it (its parts' depth order); nil is 0,
    /// which the editor's own meshes use.
    public var depth: Float?

    public init(position: SIMD2<Float>, uv: SIMD2<Float>, depth: Float? = nil) {
        self.position = position
        self.uv = uv
        self.depth = depth
    }
}

public struct PuppetMesh: Codable, Hashable, Sendable {
    public var vertices: [PuppetVertex]
    /// Counter-clockwise triangles (y up) of vertex indices.
    public var triangles: [SIMD3<UInt32>]

    public init(vertices: [PuppetVertex] = [], triangles: [SIMD3<UInt32>] = []) {
        self.vertices = vertices
        self.triangles = triangles
    }

    /// The first triangle `point` lies in.
    public func triangle(containing point: SIMD2<Float>) -> Int? {
        triangles.firstIndex { t in
            PuppetMath.barycentric(point, vertices[Int(t.x)].position, vertices[Int(t.y)].position,
                                   vertices[Int(t.z)].position).map { $0.min() >= -1e-5 } ?? false
        }
    }

    /// The edges used by one triangle only: the outline.
    public var boundaryEdges: [(UInt32, UInt32)] {
        var counts: [SIMD2<UInt32>: Int] = [:]
        for t in triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { counts[SIMD2(min(a, b), max(a, b)), default: 0] += 1 }
        }
        return counts.filter { $0.value == 1 }.keys.map { ($0.x, $0.y) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// The boundary edge nearest `point`.
    func nearestBoundaryEdge(to point: SIMD2<Float>) -> (UInt32, UInt32)? {
        boundaryEdges.min { a, b in
            PuppetMath.distance(point, segment: vertices[Int(a.0)].position, vertices[Int(a.1)].position)
                < PuppetMath.distance(point, segment: vertices[Int(b.0)].position, vertices[Int(b.1)].position)
        }
    }

    /// The vertex nearest `point` within `radius`.
    public func vertex(near point: SIMD2<Float>, radius: Float) -> Int? {
        var best: (Int, Float)?
        for (index, vertex) in vertices.enumerated() {
            let distance = simd_distance(vertex.position, point)
            if distance <= radius, distance < (best?.1 ?? .infinity) { best = (index, distance) }
        }
        return best?.0
    }

    /// Each vertex's neighbours along the triangles' edges.
    public var adjacency: [[Int]] {
        var sets = [Set<Int>](repeating: [], count: vertices.count)
        for t in triangles {
            let v = [Int(t.x), Int(t.y), Int(t.z)]
            for i in 0..<3 {
                sets[v[i]].insert(v[(i + 1) % 3])
                sets[v[i]].insert(v[(i + 2) % 3])
            }
        }
        return sets.map { $0.sorted() }
    }
}

extension SIMD3 where Scalar == UInt32 {
    /// The same triangle wound counter-clockwise (y up).
    func orientedCounterClockwise(_ vertices: [PuppetVertex]) -> SIMD3<UInt32> {
        let a = vertices[Int(x)].position, b = vertices[Int(y)].position, c = vertices[Int(z)].position
        return PuppetMath.cross(b - a, c - a) < 0 ? SIMD3(x, z, y) : self
    }
}

// MARK: - Weights

public struct PuppetWeight: Codable, Hashable, Sendable {
    public var bone: Int
    public var weight: Float

    public init(bone: Int, weight: Float) {
        self.bone = bone
        self.weight = weight
    }

    /// WE's limit: four bones a vertex (`a_BlendIndices`/`a_BlendWeights` are four wide).
    public static let maximumInfluences = 4

    /// The four largest positive weights, summing to 1, largest first; empty when none is
    /// positive. A bone listed twice counts once with its weights added.
    public static func normalized(_ entries: [PuppetWeight]) -> [PuppetWeight] {
        var sums: [Int: Float] = [:]
        for entry in entries where entry.weight.isFinite && entry.weight > 0 { sums[entry.bone, default: 0] += entry.weight }
        let all: [PuppetWeight] = sums.map { PuppetWeight(bone: $0.key, weight: $0.value) }
        let sorted: [PuppetWeight] = all.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.bone < rhs.bone
        }
        let kept = sorted.prefix(maximumInfluences)
        let total: Float = kept.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        return kept.map { PuppetWeight(bone: $0.bone, weight: $0.weight / total) }
    }

    /// The mean of several vertices' weights, normalised.
    static func average(_ lists: [[PuppetWeight]]) -> [PuppetWeight] {
        normalized(lists.flatMap { $0 })
    }

    /// `entries`' weight for `bone`.
    public static func weight(of bone: Int, in entries: [PuppetWeight]) -> Float {
        entries.first { $0.bone == bone }?.weight ?? 0
    }
}

// MARK: - Bones

/// A bone's local transform as WE's tracks hold it: position, Euler angles in radians (X first:
/// R = Rz·Ry·Rx) and scale; the matrix scales, rotates, then translates.
public struct PuppetTransform: Codable, Hashable, Sendable {
    public var translation: SIMD3<Float>
    public var euler: SIMD3<Float>
    public var scale: SIMD3<Float>

    public static let identity = PuppetTransform(translation: .zero, euler: .zero, scale: SIMD3(repeating: 1))

    public init(translation: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) {
        self.translation = translation
        self.euler = euler
        self.scale = scale
    }

    /// A matrix taken apart (translation, axis lengths, the rotation's Euler angles); a mirrored
    /// basis keeps its mirror in a negative x scale.
    public init(matrix: simd_float4x4) {
        var columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2].map { SIMD3($0.x, $0.y, $0.z) }
        var scale = SIMD3(simd_length(columns[0]), simd_length(columns[1]), simd_length(columns[2]))
        if simd_dot(simd_cross(columns[0], columns[1]), columns[2]) < 0 {
            scale.x = -scale.x
        }
        for axis in 0..<3 where scale[axis] != 0 { columns[axis] /= scale[axis] }
        let rotation = simd_float3x3(columns[0], columns[1], columns[2])
        self.init(translation: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z),
                  euler: scale.x == 0 || scale.y == 0 || scale.z == 0 ? .zero : PuppetMath.angles(rotation), scale: scale)
    }

    public var matrix: simd_float4x4 { PuppetMath.matrix(translation: translation, euler: euler, scale: scale) }

    /// The 9 floats of a track sample.
    public var samples: [Float] {
        [translation.x, translation.y, translation.z, euler.x, euler.y, euler.z, scale.x, scale.y, scale.z]
    }

    public init(samples v: ArraySlice<Float>) {
        let v = Array(v)
        self.init(translation: SIMD3(v[0], v[1], v[2]), euler: SIMD3(v[3], v[4], v[5]), scale: SIMD3(v[6], v[7], v[8]))
    }

    /// Position, angles and scale interpolated linearly (keyframes; the player's own sampling
    /// between frames is `PuppetPose`).
    public static func lerp(_ a: PuppetTransform, _ b: PuppetTransform, _ t: Float) -> PuppetTransform {
        PuppetTransform(translation: a.translation + (b.translation - a.translation) * t,
                        euler: a.euler + (b.euler - a.euler) * t, scale: a.scale + (b.scale - a.scale) * t)
    }

    func isClose(to other: PuppetTransform, tolerance: Float = 1e-4) -> Bool {
        simd_reduce_max(simd_abs(translation - other.translation)) <= tolerance * max(1, simd_reduce_max(simd_abs(translation)))
            && simd_reduce_max(simd_abs(euler - other.euler)) <= tolerance
            && simd_reduce_max(simd_abs(scale - other.scale)) <= tolerance
    }
}

public struct PuppetBone: Codable, Hashable, Sendable {
    public var name: String
    public var parent: Int?
    /// The bind transform relative to the parent (the `.mdl` bone matrix): what skins.
    public var local: PuppetTransform
    /// The rest pose relative to the parent when it differs from the bind one (the `.mdl`'s
    /// optional bind-matrix block, `SceneSkeleton.restLocal`).
    public var rest: PuppetTransform?
    /// The `MDLS` bone flags (WE's editor writes 1).
    public var flags: UInt32
    public var physics: PuppetBonePhysics?
    /// Properties keys the editor doesn't edit (IK), kept as they were.
    public var otherProperties: [String: SceneJSONValue]
    /// How long the editor draws a bone without children (WE's bones are joints; the length
    /// only shows the bone and shapes its automatic weights). nil: half its parent's.
    public var length: Float?
    /// The bone's blend rules (`PuppetBlendRule`), nil without one.
    public var blendRules: [PuppetBlendRule]?
    /// The kinematic chain that ends at the bone (`PuppetBoneIK`), nil without one; a bone has
    /// physics or a chain, not both.
    public var ik: PuppetBoneIK?

    public init(name: String, parent: Int?, local: PuppetTransform, rest: PuppetTransform? = nil, flags: UInt32 = 1,
                physics: PuppetBonePhysics? = nil, otherProperties: [String: SceneJSONValue] = [:], length: Float? = nil,
                blendRules: [PuppetBlendRule]? = nil, ik: PuppetBoneIK? = nil) {
        self.ik = ik
        self.length = length
        self.blendRules = blendRules
        self.name = name
        self.parent = parent
        self.local = local
        self.rest = rest
        self.flags = flags
        self.physics = physics
        self.otherProperties = otherProperties
    }
}

// MARK: - Clips

/// One bone's keyframes in a clip; a track without keys is written disabled (the bone keeps
/// the pose below it, WE's track flag 1).
public struct PuppetTrack: Codable, Hashable, Sendable {
    /// Keys by frame.
    public var keys: [Int: PuppetTransform]

    public init(keys: [Int: PuppetTransform] = [:]) { self.keys = keys }

    public var isEmpty: Bool { keys.isEmpty }

    /// The transform at `frame`: a key, else the two keys around it interpolated, else the
    /// nearest key; nil without keys.
    public func transform(at frame: Float) -> PuppetTransform? {
        guard !keys.isEmpty else { return nil }
        let frames = keys.keys.sorted()
        if let key = keys[Int(frame)], frame == frame.rounded(.down) { return key }
        let before = frames.last { Float($0) <= frame }
        let after = frames.first { Float($0) >= frame }
        switch (before, after) {
        case let (a?, b?) where a != b:
            return PuppetTransform.lerp(keys[a]!, keys[b]!, (frame - Float(a)) / Float(b - a))
        case let (a?, _): return keys[a]
        case let (_, b?): return keys[b]
        default: return nil
        }
    }
}

public struct PuppetClip: Codable, Hashable, Sendable {
    /// WE's play modes (0x1401a8c71): any other name loops.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case loop, mirror, single
    }

    /// The clip options of WE's model editor, kept in the clip's flags and its clip record
    /// (docs/models-plan.md §1.4, §2.8; `MDLAnimation.Flag`). WE's puppet update applies no root
    /// motion; models do.
    public struct RootMotion: Codable, Hashable, Sendable {
        /// The clip this one was cut from (an earlier clip); with it the clip record is written.
        public var sourceClip: Int?
        public var startFrame: Int
        public var endFrame: Int
        public var frameOffset: Int
        /// The Motion root bone; nil for None (−1).
        public var rootBone: Int?
        /// Flag 0x400, on by default in WE's editor.
        public var matchLoop: Bool
        /// Flags 0x800/0x1000/0x2000.
        public var positionX: Bool
        public var positionY: Bool
        public var positionZ: Bool
        /// Flag 0x8000 (the editor offers no x or z rotation).
        public var rotationY: Bool

        public init(sourceClip: Int? = nil, startFrame: Int = 0, endFrame: Int = 0, frameOffset: Int = 0, rootBone: Int? = nil,
                    matchLoop: Bool = true, positionX: Bool = false, positionY: Bool = false, positionZ: Bool = false,
                    rotationY: Bool = false) {
            self.sourceClip = sourceClip
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.frameOffset = frameOffset
            self.rootBone = rootBone
            self.matchLoop = matchLoop
            self.positionX = positionX
            self.positionY = positionY
            self.positionZ = positionZ
            self.rotationY = rotationY
        }

        public static let referenceFlag: UInt32 = 0x1
        public static let matchLoopFlag: UInt32 = 0x400
        public static let positionXFlag: UInt32 = 0x800
        public static let positionYFlag: UInt32 = 0x1000
        public static let positionZFlag: UInt32 = 0x2000
        public static let rotationYFlag: UInt32 = 0x8000
        /// Every bit these options own.
        public static let ownedFlags: UInt32 = referenceFlag | matchLoopFlag | positionXFlag | positionYFlag | positionZFlag
            | rotationYFlag

        /// The flag bits (the record's bit 0 only with a source clip).
        public var flags: UInt32 {
            var flags: UInt32 = 0
            if sourceClip != nil { flags |= Self.referenceFlag }
            if matchLoop { flags |= Self.matchLoopFlag }
            if positionX { flags |= Self.positionXFlag }
            if positionY { flags |= Self.positionYFlag }
            if positionZ { flags |= Self.positionZFlag }
            if rotationY { flags |= Self.rotationYFlag }
            return flags
        }
    }

    public var id: UInt64
    public var name: String
    public var mode: Mode
    /// The mode as the file had it, when it isn't one of WE's three names (it loops).
    public var modeName: String?
    public var fps: Float
    /// The last frame index: the clip has `frames + 1` samples and lasts `frames / fps` seconds.
    public var frames: Int
    /// One per bone.
    public var tracks: [PuppetTrack]
    public var rootMotion: RootMotion?
    /// Flag bits the editor doesn't own, kept.
    public var otherFlags: UInt32
    public var events: [PuppetClipEvent]
    /// The texture channels' weight tracks (`MDLA` 3's first scalar list, one per channel), as
    /// the file had them: Wallpaper Engine's editor keys them, this one keeps them.
    public var channelTracks: [PuppetChannelTrack]?
    /// Each bone's keyed Opacity (`MDLA` 3's second scalar list, one per bone), as the file had
    /// them: Wallpaper Engine's editor keys them and its wallpaper fades the part by them; this
    /// one keeps them, following the bones.
    public var boneAlphaTracks: [PuppetChannelTrack]?
    /// Each bone's keyed Depth offset (`MDLA` 6's scalar list, one per bone), kept likewise: it
    /// reorders the parts while the clip plays.
    public var boneDepthTracks: [PuppetChannelTrack]?

    public init(id: UInt64, name: String, mode: Mode = .loop, fps: Float = 30, frames: Int = 60, tracks: [PuppetTrack] = [],
                rootMotion: RootMotion? = nil, otherFlags: UInt32 = 0, events: [PuppetClipEvent] = []) {
        self.id = id
        self.name = name
        self.mode = mode
        self.fps = fps
        self.frames = frames
        self.tracks = tracks
        self.rootMotion = rootMotion
        self.otherFlags = otherFlags
        self.events = events
    }

    public var flags: UInt32 { otherFlags & ~RootMotion.ownedFlags | (rootMotion?.flags ?? 0) }

    /// `frames / fps` seconds.
    public var duration: Float { fps > 0 ? Float(frames) / fps : 0 }

    /// Bone `bone`'s transform at `frame`, its rest transform where its track has no key.
    public func transform(of bone: Int, at frame: Float, rest: PuppetTransform) -> PuppetTransform {
        guard tracks.indices.contains(bone) else { return rest }
        return tracks[bone].transform(at: frame) ?? rest
    }

    /// Changes the frame count, keys past the end dropped.
    public mutating func setFrames(_ count: Int) {
        frames = max(1, count)
        for track in tracks.indices { tracks[track].keys = tracks[track].keys.filter { $0.key <= frames } }
    }
}

/// One texture channel's weight per frame (`g_BlendMap`), with the u32 the file has before it.
public struct PuppetChannelTrack: Codable, Hashable, Sendable {
    public var tag: UInt32
    public var samples: [Float]

    public init(tag: UInt32, samples: [Float]) {
        self.tag = tag
        self.samples = samples
    }

    /// The weight at `frame`, the last sample past the end.
    public func sample(_ frame: Int) -> Float {
        samples.isEmpty ? 0 : samples[max(0, min(frame, samples.count - 1))]
    }
}

public struct PuppetClipEvent: Codable, Hashable, Sendable {
    public var frame: Float
    public var name: String

    public init(frame: Float, name: String) {
        self.frame = frame
        self.name = name
    }
}

// MARK: - Animation layers

/// One entry of the image's `animationlayers` (WE's keys and defaults, `WEAnimationLayer`).
public struct PuppetAnimationLayer: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    /// The clip's id (`animation`).
    public var clipID: UInt64
    public var visible: Bool
    public var additive: Bool
    public var blendIn: Bool
    /// Kept by WE for "single" clips only.
    public var blendOut: Bool
    public var blendTime: Float
    public var rate: Float
    public var blend: Float
    /// The layer as scene.json had it (bindings kept: an edit sets a bound field's `value`).
    public var authored: SceneJSONValue?

    public init(id: Int, name: String, clipID: UInt64, visible: Bool = true, additive: Bool = false, blendIn: Bool = false,
                blendOut: Bool = false, blendTime: Float = 0.5, rate: Float = 1, blend: Float = 1, authored: SceneJSONValue? = nil) {
        self.id = id
        self.name = name
        self.clipID = clipID
        self.visible = visible
        self.additive = additive
        self.blendIn = blendIn
        self.blendOut = blendOut
        self.blendTime = blendTime
        self.rate = rate
        self.blend = blend
        self.authored = authored
    }

    /// A scene.json layer, its literal values (a bound field's starting `value`) with WE's
    /// defaults; nil without a numeric `animation`.
    public init?(json: SceneJSONValue, fallbackID: Int) {
        guard case .number(let animation)? = json["animation"], animation >= 0 else { return nil }
        func literal(_ key: String) -> SceneJSONValue? { SceneFieldBinding.literal(of: json[key]) }
        self.init(id: literal("id")?.doubleValue.map { Int($0) } ?? fallbackID,
                  name: literal("name")?.stringValue ?? "",
                  clipID: UInt64(animation),
                  visible: literal("visible")?.boolValue ?? true,
                  additive: literal("additive")?.boolValue ?? false,
                  blendIn: literal("blendin")?.boolValue ?? false,
                  blendOut: literal("blendout")?.boolValue ?? false,
                  blendTime: Float(literal("blendtime")?.doubleValue ?? 0.5),
                  rate: Float(literal("rate")?.doubleValue ?? 1),
                  blend: Float(literal("blend")?.doubleValue ?? 1),
                  authored: json)
    }

    /// The layer for scene.json: the authored entry with these values (a bound field keeps its
    /// binding and gets the value as its start).
    public var json: [String: Any] {
        var object = (authored?.any as? [String: Any]) ?? [:]
        func set(_ key: String, _ value: Any) { object[key] = SceneEditOverlay.merged(object[key], with: value) }
        object["animation"] = NSNumber(value: clipID)
        object["id"] = id
        set("name", name)
        set("visible", visible)
        set("additive", additive)
        set("blendin", blendIn)
        set("blendout", blendOut)
        set("blendtime", Self.decimal(blendTime))
        set("rate", Self.decimal(rate))
        set("blend", Self.decimal(blend))
        return object
    }

    /// The float as the decimal it reads as (0.8, not 0.800000011920929).
    static func decimal(_ value: Float) -> Double { Double(value.description) ?? Double(value) }
}

// MARK: - Preserved data

/// The parts of a loaded rig the editor keeps without editing, each dropped once an edit makes
/// it wrong (a blend shape when the vertices change), remapped when bones are renumbered.
public struct PuppetPreservedData: Codable, Hashable, Sendable {
    /// `MDAT0001`: attachment points by bone.
    public struct Attachment: Codable, Hashable, Sendable {
        public var bone: Int
        public var name: String
        /// 16 floats, as the file has them.
        public var matrix: [Float]
    }

    /// The per-bone `{vec3, mat4}` block (collision boxes, `MDLSkeleton.BoneVector`).
    public struct BoneBox: Codable, Hashable, Sendable {
        public var vector: SIMD3<Float>
        public var matrix: [Float]
    }

    public var attachments: [Attachment] = []
    /// `MDLE0002`: one local matrix (16 floats) per bone.
    public var referencePose: [[Float]]?
    /// One per bone, when the rig had the block.
    public var boneBoxes: [BoneBox]?
    public var boneIndices: [UInt32]?
    public var bonePriorities: [UInt32]?
    /// The `MDMP0001` section body, valid only for the vertices it was read with.
    public var morphSection: Data?
    /// Per vertex the morph index (`a_PositionVec4.w`), with `morphSection`.
    public var morphIndices: [Float]?
    /// The first mesh's flags and the u32 after them (flag 0x2), kept for the same vertices.
    public var meshFlags: UInt32 = 0
    public var meshFlagsExtra: UInt32?
    /// The texture channels' meshes (flag 0x2 after the puppet's), which Wallpaper Engine's
    /// editor makes; written back as they were.
    public var textureChannels: [TextureChannelMesh]?
    /// The first mesh's per-bone index ranges (`MDLV` 21's 16-byte records: bone, 0, first index,
    /// index count), in the parts' depth order; valid only for the triangles they were read with.
    /// The app reorders them by a clip's keyed depth.
    public var boneRanges: [SIMD4<UInt32>]?

    /// A texture-channel mesh: its quads in the image's pixels, drawn through `material` over the
    /// image the puppet samples.
    public struct TextureChannelMesh: Codable, Hashable, Sendable {
        public var material: String
        /// `BLENDROWCOUNT`, the u32 after the flags.
        public var blendRows: UInt32
        /// The channels its quads name (the largest blend index + 1).
        public var channelCount: Int
        /// The mesh record as the file has it, from its material to its groups.
        public var bytes: Data
    }

    public init() {}

    /// The vertices changed: blend shapes and the flags that describe them go.
    mutating func meshChanged() {
        boneRanges = nil
        morphSection = nil
        morphIndices = nil
        meshFlags &= 0xC // SKINNING_ALPHA (0x4) and the keyed draw order (0x8) stay: they are per bone, not per vertex.
        meshFlagsExtra = nil
    }

    mutating func remapBones(_ map: [Int?], order: [Int]) {
        attachments = attachments.compactMap { attachment in
            guard map.indices.contains(attachment.bone), let bone = map[attachment.bone] else { return nil }
            var moved = attachment
            moved.bone = bone
            return moved
        }
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        if let pose = referencePose { referencePose = order.map { pose.indices.contains($0) ? pose[$0] : identity } }
        if let boxes = boneBoxes {
            boneBoxes = order.map { boxes.indices.contains($0) ? boxes[$0] : BoneBox(vector: .zero, matrix: identity) }
        }
        if let indices = boneIndices {
            boneIndices = order.enumerated().map { new, old in
                indices.indices.contains(old) ? UInt32(map[Int(indices[old])].flatMap { $0 } ?? new) : UInt32(new)
            }
        }
        if let priorities = bonePriorities { bonePriorities = order.map { priorities.indices.contains($0) ? priorities[$0] : 0 } }
        // A range follows its bone; a deleted bone's triangles went to another, so the split goes.
        if let ranges = boneRanges {
            let moved = ranges.map { range -> SIMD4<UInt32>? in
                guard map.indices.contains(Int(range.x)), let bone = map[Int(range.x)] else { return nil }
                return SIMD4(UInt32(bone), range.y, range.z, range.w)
            }
            boneRanges = moved.contains(nil) ? nil : moved.compactMap { $0 }
        }
        // Morph modifiers name bones; renumbered bones would point them elsewhere.
        if order != Array(order.indices) { morphSection = nil; morphIndices = nil; meshFlags &= 0xC }
    }

    /// A bone was added (at the end).
    mutating func boneAdded(count: Int) {
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        referencePose = nil
        boneRanges = nil
        if boneBoxes != nil { boneBoxes?.append(BoneBox(vector: .zero, matrix: identity)) }
        if boneIndices != nil { boneIndices?.append(UInt32(count - 1)) }
        if bonePriorities != nil { bonePriorities?.append(0) }
    }
}
