import Foundation
import JavaScriptCore

/// Fixed-stride float slots plus one dirty byte per slot, shared with JavaScript like
/// `SceneScriptObjectTable`: effect visibility, material constants, animation state and the scene's
/// settings. Confined to the runtime's thread.
final class SceneScriptSlotBuffer {
    let stride: Int
    let capacity: Int
    let values: SceneScriptSharedBuffer<Float>
    /// Set by scripts when they write a slot; the renderer clears it after reading.
    let dirty: SceneScriptSharedBuffer<UInt8>

    init?(stride: Int, capacity: Int, dirtyCount: Int? = nil, in context: JSContext) {
        guard stride > 0, capacity > 0,
              let values = SceneScriptSharedBuffer<Float>(count: stride * capacity, in: context),
              let dirty = SceneScriptSharedBuffer<UInt8>(count: dirtyCount ?? capacity, in: context) else { return nil }
        self.stride = stride
        self.capacity = capacity
        self.values = values
        self.dirty = dirty
    }

    /// The buffers scripts can reach, for `SceneScriptRuntime.watch(_:)`.
    var sharedBuffers: [SceneScriptDetachable] { [values, dirty] }

    subscript(slot: Int, offset: Int) -> Float {
        get { values[slot * stride + offset] }
        set { values[slot * stride + offset] = newValue }
    }

    func write(_ components: [Float], slot: Int, offset: Int) {
        for (index, component) in components.enumerated() { self[slot, offset + index] = component }
    }

    func read(slot: Int, offset: Int, count: Int) -> [Float] {
        (0..<count).map { self[slot, offset + $0] }
    }

    /// `{values, dirty, stride, capacity}` for the JS side.
    func javaScriptObject(in context: JSContext) -> JSValue? {
        let object = JSValue(newObjectIn: context)
        object?.setValue(values.value, forProperty: "values")
        object?.setValue(dirty.value, forProperty: "dirty")
        object?.setValue(stride, forProperty: "stride")
        object?.setValue(capacity, forProperty: "capacity")
        return object
    }
}
