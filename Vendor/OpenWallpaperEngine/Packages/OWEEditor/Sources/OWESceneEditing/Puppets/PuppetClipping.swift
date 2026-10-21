import CoreGraphics
import Foundation
import simd

/// A Puppet Warp rig's clipping masks as the editor holds them (Puppet Warp › Clipping Masks;
/// docs/models-plan.md §2.13a). A limb is one island of the mesh (`PuppetMesh.islands`); a limb
/// assigned to a mask is drawn only where the mask, painted in texture space over other limbs,
/// covers it. WE's editor keeps the masks in the puppet JSON (`clippingmasks`,
/// `vertexislands[i].clippingmaskid`); the wallpaper runs them from the `.mdl`, where
/// `PuppetMDLWriter` writes each mask as a group over the limbs' index ranges.
public struct PuppetClipping: Codable, Hashable, Sendable {
    public struct Mask: Codable, Hashable, Sendable, Identifiable {
        public var id: UInt64
        /// As WE's editor names it in the rig's JSON; empty for one read from a `.mdl` alone.
        public var name: String
        /// The painted texture (`masks/…`, relative to `materials/`); empty until painted.
        public var texture: String
        /// "Invert mask": the limbs show only away from the painted ones.
        public var invert = false
        /// "Hide mask geometry": the painted-over limbs are drawn only into the mask.
        public var hidesMaskGeometry = false
        /// The limbs the mask is painted over (islands).
        public var maskingLimbs: [Int] = []

        public init(id: UInt64, name: String, texture: String = "", invert: Bool = false, hidesMaskGeometry: Bool = false,
                    maskingLimbs: [Int] = []) {
            self.id = id
            self.name = name
            self.texture = texture
            self.invert = invert
            self.hidesMaskGeometry = hidesMaskGeometry
            self.maskingLimbs = maskingLimbs
        }
    }

    /// A limb's mask.
    public struct Limb: Codable, Hashable, Sendable {
        public var mask: UInt64
        /// "Additive blending": the limb adds to what's under it.
        public var additive = false

        public init(mask: UInt64, additive: Bool = false) {
            self.mask = mask
            self.additive = additive
        }
    }

    public var masks: [Mask] = []
    /// Per limb (island) its mask; nil for one drawn as usual.
    public var limbs: [Limb?] = []

    public init(masks: [Mask] = [], limbs: [Limb?] = []) {
        self.masks = masks
        self.limbs = limbs
    }

    /// An id no mask has. WE's editor numbers masks and islands from one counter; any unused id works.
    public var nextMaskID: UInt64 { (masks.map(\.id).max() ?? 0) + 1 }

    public func mask(_ id: UInt64) -> Mask? { masks.first { $0.id == id } }

    /// The limbs clipped by mask `id`.
    public func clippedLimbs(of id: UInt64) -> [Int] { limbs.indices.filter { limbs[$0]?.mask == id } }

    /// Whether any limb is clipped: only then does the `.mdl` carry masks.
    public var isActive: Bool { limbs.contains { $0.map { mask($0.mask) != nil } ?? false } }

    /// The limbs with a painted pixel of `painted` (texture space, top row first: an image of the
    /// mask) inside one of their triangles [I: WE's own test].
    public static func paintedLimbs(_ mesh: PuppetMesh, islands: [Int], painted: CGImage) -> [Int] {
        let width = painted.width, height = painted.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.draw(painted, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        // The context's first row is the image's top.
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        let size = SIMD2(Float(width), Float(height))
        var limbs = Set<Int>()
        for (index, triangle) in mesh.triangles.enumerated() where index < islands.count && !limbs.contains(islands[index]) {
            let a = mesh.vertices[Int(triangle.x)].uv * size, b = mesh.vertices[Int(triangle.y)].uv * size,
                c = mesh.vertices[Int(triangle.z)].uv * size
            let low = simd_max(simd_min(simd_min(a, b), c).rounded(.down), .zero)
            let high = simd_min(simd_max(simd_max(a, b), c).rounded(.up), size)
            guard low.x < high.x, low.y < high.y else { continue }
            scan: for y in Int(low.y)..<Int(high.y) {
                for x in Int(low.x)..<Int(high.x) where pixels[y * width + x] > 0 {
                    let centre = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    if let weights = PuppetMath.barycentric(centre, a, b, c), weights.min() >= -1e-4 {
                        limbs.insert(islands[index])
                        break scan
                    }
                }
            }
        }
        return limbs.sorted()
    }
}

extension PuppetMesh {
    /// Each triangle's island: the triangles joined through shared vertices, numbered in the
    /// order of their first triangle. A Puppet Warp limb.
    public var islands: [Int] {
        var parent = Array(vertices.indices)
        func root(_ v: Int) -> Int {
            var v = v
            while parent[v] != v {
                parent[v] = parent[parent[v]]
                v = parent[v]
            }
            return v
        }
        func join(_ a: UInt32, _ b: UInt32) {
            let ra = root(Int(a)), rb = root(Int(b))
            if ra != rb { parent[rb] = ra }
        }
        for t in triangles {
            join(t.x, t.y)
            join(t.x, t.z)
        }
        var numbers: [Int: Int] = [:]
        return triangles.map { t in
            let r = root(Int(t.x))
            if let number = numbers[r] { return number }
            numbers[r] = numbers.count
            return numbers[r]!
        }
    }

    public var islandCount: Int { Set(islands).count }
}

extension PuppetDocument {
    /// The mesh's topology changed: limbs are kept while the mesh has as many, else unassigned.
    mutating func clippingTopologyChanged() {
        guard var clipping, clipping.limbs.count != mesh.islandCount else { return }
        clipping.limbs = Array(repeating: nil, count: mesh.islandCount)
        for index in clipping.masks.indices { clipping.masks[index].maskingLimbs = [] }
        self.clipping = clipping
    }

    /// The limb (island) under `point` (mesh space, bind pose).
    public func limb(at point: SIMD2<Float>) -> Int? {
        guard let triangle = mesh.triangle(containing: point) else { return nil }
        let islands = mesh.islands
        return triangle < islands.count ? islands[triangle] : nil
    }

    /// The clipping masks with every limb listed.
    public var clippingOrEmpty: PuppetClipping {
        var value = clipping ?? PuppetClipping()
        let count = mesh.islandCount
        if value.limbs.count != count { value.limbs = Array(repeating: nil, count: count) }
        return value
    }

    /// Assigns `limb` to mask `id` (WE's Assign Clipping Mask), keeping its blending.
    public mutating func assignClippingMask(_ id: UInt64, to limb: Int) {
        var value = clippingOrEmpty
        guard value.limbs.indices.contains(limb), value.mask(id) != nil else { return }
        value.limbs[limb] = PuppetClipping.Limb(mask: id, additive: value.limbs[limb]?.additive ?? false)
        clipping = value
    }

    /// A new mask named `name`, assigned to `limb`; returns its id.
    @discardableResult
    public mutating func addClippingMask(named name: String, to limb: Int) -> UInt64 {
        var value = clippingOrEmpty
        let id = value.nextMaskID
        value.masks.append(PuppetClipping.Mask(id: id, name: name))
        clipping = value
        assignClippingMask(id, to: limb)
        return id
    }

    /// WE's Remove Clipping Mask: the limb draws as usual again. A mask no limb uses goes.
    public mutating func removeClippingMask(from limb: Int) {
        var value = clippingOrEmpty
        guard value.limbs.indices.contains(limb), let id = value.limbs[limb]?.mask else { return }
        value.limbs[limb] = nil
        if value.clippedLimbs(of: id).isEmpty { value.masks.removeAll { $0.id == id } }
        clipping = value.masks.isEmpty ? nil : value
    }

    public mutating func setClippingAdditive(_ additive: Bool, limb: Int) {
        var value = clippingOrEmpty
        guard value.limbs.indices.contains(limb), value.limbs[limb] != nil else { return }
        value.limbs[limb]?.additive = additive
        clipping = value
    }

    /// Changes mask `id`.
    public mutating func updateClippingMask(_ id: UInt64, _ change: (inout PuppetClipping.Mask) -> Void) {
        var value = clippingOrEmpty
        guard let index = value.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&value.masks[index])
        clipping = value
    }

    /// Problems with the masks: one nested back into a mask it clips (the docs' A → B → A).
    public var hasIncorrectlyNestedClippingMask: Bool {
        guard let clipping else { return false }
        // Mask b nests in a when all of b's masking limbs are clipped by a.
        func parent(of mask: PuppetClipping.Mask) -> UInt64? {
            guard !mask.maskingLimbs.isEmpty else { return nil }
            return clipping.masks.first { other in
                other.id != mask.id && mask.maskingLimbs.allSatisfy { clipping.limbs.indices.contains($0) && clipping.limbs[$0]?.mask == other.id }
            }?.id
        }
        for mask in clipping.masks {
            var seen: Set<UInt64> = [mask.id]
            var next = parent(of: mask)
            while let id = next {
                if !seen.insert(id).inserted { return true }
                next = clipping.mask(id).flatMap(parent(of:))
            }
        }
        return false
    }
}
