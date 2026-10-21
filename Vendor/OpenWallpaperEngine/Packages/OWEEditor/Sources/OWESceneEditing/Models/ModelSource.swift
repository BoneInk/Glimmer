import Foundation
import simd

/// A model file as the importer read it (FBX or OBJ, `OWEModelImport`), before it is compiled
/// into WE's `.mdl` (`ModelCompiler`). It holds what WE's resource compiler takes from Assimp's
/// scene: the node tree, each mesh split per material as a triangle list of corners in model
/// space, the materials' names and textures, and the animation stacks sampled per frame.
public struct ModelSource: Sendable, Equatable {
    /// A node of the file's tree, parents before children.
    public struct Node: Sendable, Equatable {
        public var name: String
        public var parent: Int?
        /// The transform relative to the parent in the file's default pose (column-vector).
        public var local: simd_float4x4
        /// An armature bone (FBX LimbNode) or a node a skin deforms with: WE's bone flag 1.
        public var isBone: Bool

        public init(name: String, parent: Int?, local: simd_float4x4, isBone: Bool) {
            self.name = name
            self.parent = parent
            self.local = local
            self.isBone = isBone
        }
    }

    /// One texture a material names: its file as the model wrote it, its bytes when the file
    /// embeds them.
    public struct Texture: Sendable, Equatable {
        /// The path the model file names (absolute or relative to the model).
        public var path: String
        /// The image's bytes when the model embeds them (FBX `Content`).
        public var embedded: Data?

        public init(path: String, embedded: Data? = nil) {
            self.path = path
            self.embedded = embedded
        }
    }

    public struct Material: Sendable, Equatable {
        public var name: String
        /// The albedo (FBX diffuse colour map, OBJ `map_Kd`, glTF-style base colour).
        public var albedo: Texture?
        public var normalMap: Texture?
        /// The diffuse colour and opacity, when the file sets them.
        public var color: SIMD3<Float>?
        public var opacity: Float?

        public init(name: String, albedo: Texture? = nil, normalMap: Texture? = nil, color: SIMD3<Float>? = nil,
                    opacity: Float? = nil) {
            self.name = name
            self.albedo = albedo
            self.normalMap = normalMap
            self.color = color
            self.opacity = opacity
        }
    }

    /// Up to four influences per corner, by node index, largest first.
    public struct Influences: Sendable, Equatable {
        public var nodes: SIMD4<UInt32>
        public var weights: SIMD4<Float>

        public init(nodes: SIMD4<UInt32>, weights: SIMD4<Float>) {
            self.nodes = nodes
            self.weights = weights
        }
    }

    /// One part of a mesh drawn with one material: three corners per triangle, in the order the
    /// file's faces list them, every attribute per corner. Positions and normals are in model
    /// space (the root node's), in the rest pose.
    public struct Mesh: Sendable, Equatable {
        public var name: String
        public var material: Int?
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]?
        /// As the file stores them (v up); the compiler flips v as WE's importer does.
        public var uvs: [SIMD2<Float>]?
        public var secondUVs: [SIMD2<Float>]?
        /// Set on every corner when the model is skinned (a mesh without a skin is bound to its node).
        public var influences: [Influences]?
        /// The file's own tangent space (FBX tangent and binormal layers), in model space: WE's
        /// importer keeps it rather than computing one, and joins corners on it.
        public var tangents: [SIMD3<Float>]?
        public var bitangents: [SIMD3<Float>]?
        /// The node the mesh hangs from (its positions are already in model space). In a skinned
        /// model a mesh without a skin moves with it: WE's importer keeps that node as a bone
        /// and binds the mesh to it (capture 546's static "Plinth").
        public var node: Int?
        /// Per corner, the polygon corner it is (any number, the same for the corners a polygon's
        /// triangles share; ascending in the file's polygon order): Assimp's vertices. Nil makes
        /// every triangle corner a vertex of its own.
        public var vertices: [Int]?

        public init(name: String, material: Int?, positions: [SIMD3<Float>], normals: [SIMD3<Float>]? = nil,
                    uvs: [SIMD2<Float>]? = nil, secondUVs: [SIMD2<Float>]? = nil, influences: [Influences]? = nil) {
            self.name = name
            self.material = material
            self.positions = positions
            self.normals = normals
            self.uvs = uvs
            self.secondUVs = secondUVs
            self.influences = influences
        }
    }

    /// An animation stack sampled at its frame rate: `frames + 1` local transforms per node
    /// (the node's default pose for nodes it doesn't animate).
    public struct Animation: Sendable, Equatable {
        public var name: String
        public var fps: Float
        public var frames: Int
        /// `[node][frame]`, the node's local transform.
        public var samples: [[PuppetTransform]]

        public init(name: String, fps: Float, frames: Int, samples: [[PuppetTransform]]) {
            self.name = name
            self.fps = fps
            self.frames = frames
            self.samples = samples
        }
    }

    public var nodes: [Node]
    public var meshes: [Mesh]
    public var materials: [Material]
    public var animations: [Animation]

    public init(nodes: [Node] = [], meshes: [Mesh] = [], materials: [Material] = [], animations: [Animation] = []) {
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.animations = animations
    }

    /// Whether any mesh is skinned: the model then gets WE's skeleton and animations.
    public var isSkinned: Bool { meshes.contains { $0.influences != nil } }
}
