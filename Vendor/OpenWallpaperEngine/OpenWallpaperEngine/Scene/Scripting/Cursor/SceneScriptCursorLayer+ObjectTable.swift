import simd

extension SceneScriptCursorLayer {
    /// A hit-testable object (an image, text or model layer) in draw order, with what the object
    /// table doesn't hold.
    struct TableEntry {
        var slot: Int
        /// scene.json `disablepropagation`.
        var disablesPropagation: Bool
        var shape: Shape
        /// Its named hit boxes (`SceneScriptCursorShape`), posed each frame by `boneWorlds`.
        var hitBoxes: [SceneScriptCursorShape.HitBox]
        /// A puppet's draw-depth order of its bones.
        var hitBoxOrder: [Int]?

        init(slot: Int, disablesPropagation: Bool = false, shape: Shape = .quad,
             hitBoxes: [SceneScriptCursorShape.HitBox] = [], hitBoxOrder: [Int]? = nil) {
            self.slot = slot
            self.disablesPropagation = disablesPropagation
            self.shape = shape
            self.hitBoxes = hitBoxes
            self.hitBoxOrder = hitBoxOrder
        }
    }

    /// The layers of `drawOrder` (bottom first) as the object table holds them after the last
    /// frame: world matrix, size, origin, parallax depth, `solid` and `visible`, which scripts may
    /// have changed. `parentOf` names an object's parent slot, for visibility; `world` gives the
    /// renderer's 3D world matrix of a slot where WE tests that rather than the table's 2D one (a
    /// model, whose box is never tested without it; every layer of a perspective scene). Slots
    /// outside the table are skipped. On the runtime's thread, like every read of the table.
    static func layers(in table: SceneScriptObjectTable, drawOrder: [TableEntry],
                       parentOf: (Int) -> Int?,
                       world: (Int) -> simd_float4x4? = { _ in nil },
                       boneWorlds: (Int) -> [simd_float4x4]? = { _ in nil }) -> [SceneScriptCursorLayer] {
        // Every frame, for every image and text layer: straight reads of the table's floats.
        let values = table.values.pointer
        typealias Layout = SceneScriptObjectTable.Layout
        let size = SceneScriptObjectField.size.offset, origin = SceneScriptObjectField.origin.offset
        let depth = SceneScriptObjectField.parallaxDepth.offset, solid = SceneScriptObjectField.solid.offset
        var layers: [SceneScriptCursorLayer] = []
        layers.reserveCapacity(drawOrder.count)
        for entry in drawOrder {
            let slot = entry.slot
            guard (0..<table.capacity).contains(slot) else { continue }
            let row = values + slot * Layout.stride
            let m = row + Layout.worldMatrix
            var shape = entry.shape
            let matrix: simd_float4x4
            if let renderer = world(slot) {
                matrix = renderer
            } else {
                matrix = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                       SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
                if case .model = shape { shape = .model(nil) }
            }
            layers.append(SceneScriptCursorLayer(
                slot: slot, worldMatrix: matrix, size: SIMD2(row[size], row[size + 1]), shape: shape,
                origin: SIMD2(row[origin], row[origin + 1]), parallaxDepth: SIMD2(row[depth], row[depth + 1]),
                originZ: row[origin + 2], isSolid: row[solid] != 0, disablesPropagation: entry.disablesPropagation,
                isVisible: isVisible(slot, in: table, parentOf: parentOf),
                hitBoxes: hitBoxes(entry, boneWorlds: boneWorlds(slot))))
        }
        return layers
    }

    /// An entry's hit boxes this frame: a puppet's need its posed bones; a model's hang from its
    /// world matrix without them.
    private static func hitBoxes(_ entry: TableEntry, boneWorlds: [simd_float4x4]?) -> HitBoxes? {
        guard !entry.hitBoxes.isEmpty else { return nil }
        if entry.hitBoxOrder != nil && boneWorlds == nil { return nil }
        return HitBoxes(boxes: entry.hitBoxes, order: entry.hitBoxOrder, boneWorlds: boneWorlds ?? [])
    }

    /// `visible` of the object and every parent (0x140185010). A parent chain longer than the table
    /// is a cycle and counts as hidden.
    private static func isVisible(_ slot: Int, in table: SceneScriptObjectTable, parentOf: (Int) -> Int?) -> Bool {
        let values = table.values.pointer
        let visible = SceneScriptObjectField.visible.offset
        var current: Int? = slot
        var steps = 0
        while let object = current {
            guard (0..<table.capacity).contains(object), steps <= table.capacity else { return false }
            if values[object * SceneScriptObjectTable.Layout.stride + visible] == 0 { return false }
            current = parentOf(object)
            steps += 1
        }
        return true
    }
}
