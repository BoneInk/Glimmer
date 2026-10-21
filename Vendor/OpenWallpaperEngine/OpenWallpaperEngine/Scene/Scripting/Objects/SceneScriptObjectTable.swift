import Foundation
import JavaScriptCore

/// The struct-of-arrays the renderer and scripts share (docs/scenescript-plan.md §4.3): one slot of
/// `Layout.stride` floats per scene object, plus one dirty byte per slot. WP2 fixed the first
/// fields; the object model (WP7) appends the rest and builds the JS layer classes over it
/// (`objects-layers.js`), and WP11 makes the renderer read it.
///
/// Units are the renderer's: angles in radians (the JS getters convert to WE's degrees), colours
/// 0…1, flags 0 or 1. `worldMatrix` is written by the renderer after its transform pass
/// (column-major, like simd), for `getTransformMatrix` and cursor hit tests. `playing` is the
/// sound or particle system's playback state: the renderer keeps it current, and `play()`/`stop()`
/// set it immediately so `isPlaying()` agrees within the frame.
///
/// Effects, material constants, animations and the scene's own settings live in their own
/// `SceneScriptSlotBuffer`s (`SceneScriptObjectModel`).
final class SceneScriptObjectTable {
    /// Float offsets within a slot. `SceneScriptObjectField` names them for scripts.
    enum Layout {
        static let origin = 0          // x y z
        static let angles = 3          // x y z, radians
        static let scale = 6           // x y z
        static let alpha = 9
        static let color = 10          // r g b
        static let visible = 13
        static let parallaxDepth = 14  // x y
        static let size = 16           // x y, read-only for scripts
        static let worldMatrix = 18    // 16 floats
        // Appended by the object model (WP7).
        static let pointsize = 34
        static let maxwidth = 35
        static let maxrows = 36
        static let padding = 37
        static let limitrows = 38
        static let limitwidth = 39
        static let opaquebackground = 40
        static let backgroundcolor = 41  // r g b
        static let perspective = 44
        static let solid = 45
        static let volume = 46
        static let playing = 47
        static let fov = 48
        static let zoom = 49
        static let rootmotion = 50
        /// The particle system's `instance` (`instanceoverride` in scene.json): alpha, size, count,
        /// speed, lifetime, rate, colorn.
        static let instance = 51
        /// `instance.controlpoint0…7`, x y z each.
        static let controlPoints = 58
        static let brightness = 82
        /// A light's `intensity`, `radius`, `exponent`, `innercone` and `outercone`, then its
        /// `controlpoint` (x y z).
        static let intensity = 83
        static let radius = 84
        static let exponent = 85
        static let innercone = 86
        static let outercone = 87
        static let controlpoint = 88
        /// An image's video texture time in seconds, renderer-written (`IVideoTexture`).
        static let videoTime = 91
        static let stride = 92

        /// The offsets as the JS side reads them (`__rt.table.layout`).
        static var javaScriptObject: [String: Int] {
            var layout = ["worldMatrix": worldMatrix, "videoTime": videoTime, "stride": stride]
            for field in SceneScriptObjectField.allCases { layout[field.rawValue] = field.offset }
            return layout
        }
    }

    let capacity: Int
    let values: SceneScriptSharedBuffer<Float>
    /// 1 when a script wrote the slot this frame; the renderer clears it after reading.
    let dirty: SceneScriptSharedBuffer<UInt8>

    init?(capacity: Int, in context: JSContext) {
        guard let values = SceneScriptSharedBuffer<Float>(count: max(1, capacity) * Layout.stride, in: context),
              let dirty = SceneScriptSharedBuffer<UInt8>(count: max(1, capacity), in: context) else { return nil }
        self.capacity = capacity
        self.values = values
        self.dirty = dirty
    }

    /// The buffers scripts can reach, for `SceneScriptRuntime.watch(_:)`.
    var sharedBuffers: [SceneScriptDetachable] { [values, dirty] }

    /// Index of `field` of `slot` in `values`.
    static func index(slot: Int, field: Int) -> Int { slot * Layout.stride + field }

    subscript(slot: Int, field: SceneScriptObjectField) -> [Float] {
        get {
            let base = Self.index(slot: slot, field: field.offset)
            return (0..<field.components).map { values[base + $0] }
        }
        set {
            let base = Self.index(slot: slot, field: field.offset)
            for component in 0..<min(field.components, newValue.count) { values[base + component] = newValue[component] }
        }
    }

    /// Writes every field's default, then `overrides`, into `slot`, and an identity world matrix.
    func reset(slot: Int, with overrides: [SceneScriptObjectField: [Float]]) {
        for field in SceneScriptObjectField.allCases {
            self[slot, field] = overrides[field] ?? field.defaultValue
        }
        let matrix = Self.index(slot: slot, field: Layout.worldMatrix)
        for index in 0..<16 { values[matrix + index] = index % 5 == 0 ? 1 : 0 }
        dirty[slot] = 0
    }

    /// Publishes the table as `__rt.table = {values, dirty, layout, capacity}`.
    func install(on rt: JSValue) {
        let table = JSValue(newObjectIn: rt.context)
        table?.setValue(values.value, forProperty: "values")
        table?.setValue(dirty.value, forProperty: "dirty")
        table?.setValue(Layout.javaScriptObject, forProperty: "layout")
        table?.setValue(capacity, forProperty: "capacity")
        rt.setValue(table, forProperty: "table")
    }
}
