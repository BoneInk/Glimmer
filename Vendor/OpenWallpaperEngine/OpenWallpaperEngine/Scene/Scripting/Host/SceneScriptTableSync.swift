import Foundation

/// Moves values between the renderer and the object model's shared tables, on the script thread
/// (docs/scenescript-plan.md §4.3, WP11).
///
/// - Before a frame: the renderer's live values of each object (authored, user-bound, animated)
///   go into the fields scripts don't own, and every object's world matrix and size into theirs,
///   so reads see this frame's values (§1.9 P2) and `getTransformMatrix`/hit tests the last ones.
/// - After a frame: a slot's dirty byte says a script wrote it; a field that differs from what
///   was written before the frame is script-owned from then on (the renderer draws the table's
///   value). The dirty bytes are cleared.
///
/// `baselines` holds, per slot, the row as this type last left it, which is what a script write
/// is detected against: one flat buffer of `Layout.stride` floats per slot, like the table.
/// Confined to the script thread, and called every frame, so it works on the buffers directly.
final class SceneScriptTableSync {
    /// A field whose writes make it script-owned: every member but `playing` (native state behind
    /// `isPlaying()`). `size` is read-only for member writes, so only a script bound to it owns it.
    private struct Tracked {
        var bit: UInt64
        var offset: Int
        var components: Int
    }

    private static let tracked: [Tracked] = SceneScriptObjectField.allCases.filter { $0 != .playing }.map {
        Tracked(bit: SceneScriptOwnedFields.bit($0), offset: $0.offset, components: $0.components)
    }
    private static let originBit = SceneScriptOwnedFields.bit(.origin), scaleBit = SceneScriptOwnedFields.bit(.scale)
    private static let anglesBit = SceneScriptOwnedFields.bit(.angles), alphaBit = SceneScriptOwnedFields.bit(.alpha)
    private static let colorBit = SceneScriptOwnedFields.bit(.color), visibleBit = SceneScriptOwnedFields.bit(.visible)
    private static let brightnessBit = SceneScriptOwnedFields.bit(.brightness), sizeBit = SceneScriptOwnedFields.bit(.size)

    private typealias Layout = SceneScriptObjectTable.Layout
    private static let origin = SceneScriptObjectField.origin.offset
    private static let scale = SceneScriptObjectField.scale.offset
    private static let angles = SceneScriptObjectField.angles.offset
    private static let alpha = SceneScriptObjectField.alpha.offset
    private static let color = SceneScriptObjectField.color.offset
    private static let visible = SceneScriptObjectField.visible.offset
    private static let size = SceneScriptObjectField.size.offset
    private static let playing = SceneScriptObjectField.playing.offset
    private static let brightness = SceneScriptObjectField.brightness.offset

    private let store: SceneScriptObjectStore
    private var baselines: [Float]
    private var sceneBaseline: [Float]

    init(store: SceneScriptObjectStore) {
        self.store = store
        baselines = [Float](repeating: 0, count: store.table.capacity * Layout.stride)
        sceneBaseline = store.scene.read(slot: 0, offset: 0, count: SceneScriptSceneField.Layout.stride)
    }

    /// Records `slot`'s row as placed from `description` (before any script wrote it).
    func place(slot: Int, description: SceneScriptObjectDescription) {
        guard (0..<store.table.capacity).contains(slot) else { return }
        let base = slot * Layout.stride
        for field in SceneScriptObjectField.allCases {
            let value = description.values[field] ?? field.defaultValue
            for component in 0..<min(field.components, value.count) { baselines[base + field.offset + component] = value[component] }
        }
        for index in 0..<16 { baselines[base + Layout.worldMatrix + index] = index % 5 == 0 ? 1 : 0 }
    }

    // MARK: - Before the frame

    /// Writes the renderer's values of the object in `slot` into the fields `owned` doesn't list
    /// (and into animated ones: the timeline runs before scripts, §1.9 P2).
    func write(_ feedback: SceneScriptObjectFeedback, slot: Int, owned: SceneScriptOwnedFields) {
        guard (0..<store.table.capacity).contains(slot) else { return }
        let table = store.table.values.pointer + slot * Layout.stride
        baselines.withUnsafeMutableBufferPointer { buffer in
            let baseline = buffer.baseAddress! + slot * Layout.stride
            func put(_ offset: Int, _ value: Float) {
                table[offset] = value
                baseline[offset] = value
            }
            func writable(_ bit: UInt64) -> Bool {
                !owned.contains(bit: bit) || feedback.animated.contains(bit: bit)
            }
            if writable(Self.originBit) {
                put(Self.origin, feedback.origin.x)
                put(Self.origin + 1, feedback.origin.y)
            }
            if writable(Self.scaleBit) {
                put(Self.scale, feedback.scale.x)
                put(Self.scale + 1, feedback.scale.y)
            }
            if writable(Self.anglesBit) { put(Self.angles + 2, feedback.angle) }
            if let alpha = feedback.alpha, writable(Self.alphaBit) { put(Self.alpha, alpha) }
            if let color = feedback.color, writable(Self.colorBit) {
                put(Self.color, color.x)
                put(Self.color + 1, color.y)
                put(Self.color + 2, color.z)
            }
            if writable(Self.visibleBit) { put(Self.visible, feedback.visible ? 1 : 0) }
            if let brightness = feedback.brightness, writable(Self.brightnessBit) { put(Self.brightness, brightness) }
            if let size = feedback.size, writable(Self.sizeBit) {
                put(Self.size, size.x)
                put(Self.size + 1, size.y)
            }
            if let playing = feedback.playing { put(Self.playing, playing ? 1 : 0) }
            if let videoTime = feedback.videoTime { put(Layout.videoTime, videoTime) }
            // The world matrix, column-major like simd: the 2D affine part in a 4×4.
            let linear = feedback.world.linear, translation = feedback.world.translation
            let matrix = Layout.worldMatrix
            put(matrix, linear.columns.0.x)
            put(matrix + 1, linear.columns.0.y)
            put(matrix + 4, linear.columns.1.x)
            put(matrix + 5, linear.columns.1.y)
            put(matrix + 12, translation.x)
            put(matrix + 13, translation.y)
        }
    }

    // MARK: - After the frame

    /// Whether a script wrote `slot` since the last read.
    func isDirty(_ slot: Int) -> Bool {
        (0..<store.table.capacity).contains(slot) && store.table.dirty[slot] != 0
    }

    /// The fields of a dirty `slot` scripts wrote since the last read, added to `owned`, and the
    /// row. Clears its dirty byte.
    func read(slot: Int, owned: SceneScriptOwnedFields) -> (owned: SceneScriptOwnedFields, row: [Float]) {
        store.table.dirty[slot] = 0
        let table = store.table.values.pointer + slot * Layout.stride
        var owned = owned
        baselines.withUnsafeMutableBufferPointer { buffer in
            let baseline = buffer.baseAddress! + slot * Layout.stride
            // Plain loops over the buffers: this runs for every written object every frame.
            Self.tracked.withUnsafeBufferPointer { fields in
                var index = 0
                while index < fields.count {
                    let tracked = fields[index]
                    index += 1
                    guard !owned.contains(bit: tracked.bit) else { continue }
                    var component = tracked.offset
                    let end = tracked.offset + tracked.components
                    while component < end {
                        if table[component].bitPattern != baseline[component].bitPattern {
                            owned.insert(bit: tracked.bit)
                            break
                        }
                        component += 1
                    }
                }
            }
            baseline.update(from: table, count: Layout.stride)
        }
        return (owned, Array(UnsafeBufferPointer(start: table, count: Layout.stride)))
    }

    /// Effects (of the object's `effectSlots`) whose `visible` a script wrote: effect index →
    /// visible. Clears their bytes.
    func readEffects(_ effectSlots: [Int]) -> [Int: Bool] {
        var changed: [Int: Bool] = [:]
        for (index, effectSlot) in effectSlots.enumerated() where store.effects.dirty[effectSlot] != 0 {
            store.effects.dirty[effectSlot] = 0
            changed[index] = store.effects[effectSlot, 0] != 0
        }
        return changed
    }

    /// The scene settings scripts wrote since the last read, added to `state`. False when clean.
    /// A scene setting a timeline set this frame (docs/timeline-plan.md §2.6): written into the
    /// scene buffer and taken as its baseline, so only a script's write this frame makes the
    /// setting the script's (`readScene`).
    func writeScene(_ field: SceneScriptSceneField, _ value: SIMD4<Float>) {
        for component in 0..<field.components {
            store.scene[0, field.offset + component] = value[component]
            sceneBaseline[field.offset + component] = value[component]
        }
    }

    func readScene(into state: inout SceneScriptSceneState) -> Bool {
        let scene = store.scene
        let settingsDirty = scene.dirty[SceneScriptSceneField.Layout.settingsDirty] != 0
        let cameraDirty = scene.dirty[SceneScriptSceneField.Layout.cameraDirty] != 0
        guard settingsDirty || cameraDirty else { return false }
        scene.dirty[SceneScriptSceneField.Layout.settingsDirty] = 0
        scene.dirty[SceneScriptSceneField.Layout.cameraDirty] = 0
        let row = scene.read(slot: 0, offset: 0, count: SceneScriptSceneField.Layout.stride)
        for field in SceneScriptSceneField.allCases where !state.owned.contains(field) {
            for component in 0..<field.components where
                row[field.offset + component].bitPattern != sceneBaseline[field.offset + component].bitPattern {
                state.owned.insert(field)
                break
            }
        }
        sceneBaseline = row
        state.values = row
        return true
    }
}
