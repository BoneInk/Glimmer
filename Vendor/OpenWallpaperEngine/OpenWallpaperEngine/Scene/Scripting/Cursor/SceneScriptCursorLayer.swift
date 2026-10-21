import simd

/// One object WE's cursor pass considers, as it was last drawn. Image and text layers (object
/// types 1 and 4, wallpaper64.exe 0x14018a041) take the quad test and models (type 5) the box
/// test (`SceneScriptCursorHitTest`); every other object is left out of
/// `SceneScriptCursorFrame.layers`.
struct SceneScriptCursorLayer {
    /// A model's or puppet's named hit boxes this frame (`SceneScriptCursorShape`).
    struct HitBoxes {
        /// One per bone, by bone index.
        var boxes: [SceneScriptCursorShape.HitBox]
        /// A puppet's bones in draw-depth order, tried from the end, the first hit winning; nil for a
        /// model, whose boxes are all tried and the nearest wins.
        var order: [Int]?
        /// Each bone's world matrix this frame (the object's world times the bone's posed model
        /// matrix: puppet+0x340; a model's world times its animator's pose). Empty for a model
        /// without a pose, whose boxes then hang from its world matrix alone.
        var boneWorlds: [simd_float4x4]
    }

    /// Which test the object takes.
    enum Shape: Equatable {
        /// An image or text layer: the `size` quad.
        case quad
        /// A model: its box (`SceneScriptCursorShape`), nil without model data (never hit: WE's
        /// test returns false without it, 0x140185561).
        case model(MDLBounds?)
    }

    /// The object-table slot; cursor events reach the scripts of this slot.
    var slot: Int
    /// The object's world matrix (column-major, parents included), without camera parallax or
    /// shake: the object table's `worldMatrix`, or the object's 3D world where the table's 2D one
    /// isn't what WE tests (a model; any layer of a perspective scene).
    var worldMatrix: simd_float4x4
    /// `size`: the quad before scale, in scene units.
    var size: SIMD2<Float>
    var shape: Shape
    /// The object's own `origin` and `parallaxDepth`. WE's hit test offsets the quad by camera
    /// parallax from these (0x14018a0b3), not from the root object's as drawing does.
    var origin: SIMD2<Float>
    var parallaxDepth: SIMD2<Float>
    /// `origin.z`: with x and y, a perspective scene's cursor order (`SceneScriptCursorFrame`).
    var originZ: Float
    /// `solid`: only solid objects are tested (flag 0x2000; WE's default is solid).
    var isSolid: Bool
    /// `disablepropagation` (flag 0x4000).
    var disablesPropagation: Bool
    /// Its named hit boxes, if it has any.
    var hitBoxes: HitBoxes?
    /// `visible`, and every parent visible (0x140185010). Hidden objects are still hit and get
    /// their events; only a visible one stops propagation.
    var isVisible: Bool

    init(slot: Int, worldMatrix: simd_float4x4, size: SIMD2<Float> = .zero, shape: Shape = .quad,
         origin: SIMD2<Float> = .zero, parallaxDepth: SIMD2<Float> = SIMD2(1, 1), originZ: Float = 0,
         isSolid: Bool = true, disablesPropagation: Bool = false, isVisible: Bool = true, hitBoxes: HitBoxes? = nil) {
        self.slot = slot
        self.worldMatrix = worldMatrix
        self.size = size
        self.shape = shape
        self.origin = origin
        self.parallaxDepth = parallaxDepth
        self.originZ = originZ
        self.isSolid = isSolid
        self.disablesPropagation = disablesPropagation
        self.isVisible = isVisible
        self.hitBoxes = hitBoxes
    }

    /// Whether a hit on this layer keeps the cursor pass from reaching the layers under it.
    var stopsPropagation: Bool { disablesPropagation && isVisible }
}
