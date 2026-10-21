import Foundation
import JavaScriptCore

/// Swift-owned memory that JavaScript sees as a typed array over the same bytes, so the renderer
/// and scripts exchange per-frame data without marshalling (docs/scenescript-plan.md §4.3).
///
/// Scripts can reach these arrays (`thisLayer._t`, `__rt.ring`), and any of them can call
/// `array.buffer.transfer()` (JavaScriptCore has it from macOS 14.4), which normally detaches the
/// array and moves the bytes, with their deallocator, to a new `ArrayBuffer` the script may drop
/// (SF3). Three layers keep Swift's writes safe:
///
/// - The array's buffer is pinned at creation (`JSObjectGetTypedArrayBytesPtr` pins and locks
///   it), and JavaScriptCore copies a pinned buffer on `transfer()` instead of detaching it.
/// - The memory is reference counted: this object holds one reference and the typed array's
///   deallocator the other, so the bytes are freed only when both are gone, whichever
///   `ArrayBuffer` holds them by then. `pointer` stays valid for this object's lifetime.
/// - `isDetached` reports an array that got detached anyway; the runtime checks it after every
///   entry into script code and stops the wallpaper's scripts (`SceneScriptRuntime.watch(_:)`).
///
/// Fixed capacity; a larger table is a new buffer. Confined to the runtime's thread.
final class SceneScriptSharedBuffer<Element: SceneScriptSharedElement>: SceneScriptDetachable {
    let count: Int
    let pointer: UnsafeMutablePointer<Element>
    /// The typed array (`Float32Array`, `Int32Array`, …) to hand to JavaScript.
    let value: JSValue
    private let memory: SceneScriptSharedMemory
    /// `value`'s object; `value` keeps it alive.
    private let object: JSObjectRef
    private let contextRef: JSGlobalContextRef

    init?(count: Int, in context: JSContext) {
        guard count > 0, let contextRef = context.jsGlobalContextRef else { return nil }
        let byteCount = count * MemoryLayout<Element>.stride
        let memory = SceneScriptSharedMemory(byteCount: byteCount, alignment: MemoryLayout<Element>.alignment)
        let typed = memory.bytes.bindMemory(to: Element.self, capacity: count)
        typed.initialize(repeating: Element.zero, count: count)
        // The typed array's reference, released by JavaScriptCore when the bytes are collected.
        let retained = Unmanaged.passRetained(memory).toOpaque()
        let release: JSTypedArrayBytesDeallocator = { _, context in
            guard let context else { return }
            Unmanaged<SceneScriptSharedMemory>.fromOpaque(context).release()
        }
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            contextRef, Element.typedArrayType, memory.bytes, byteCount, release, retained, &exception) else {
            // JavaScriptCore calls the deallocator itself when it fails after wrapping the bytes
            // (an exception); when it fails before, nothing owns that reference.
            if exception == nil { Unmanaged<SceneScriptSharedMemory>.fromOpaque(retained).release() }
            return nil
        }
        // A garbage-collected object from here on: its deallocator owns the reference.
        guard exception == nil, let value = JSValue(jsValueRef: object, in: context) else { return nil }
        _ = JSObjectGetTypedArrayBytesPtr(contextRef, object, nil) // pins: `transfer()` copies
        self.count = count
        self.pointer = typed
        self.value = value
        self.memory = memory
        self.object = object
        self.contextRef = contextRef
    }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "SceneScriptSharedBuffer index out of range")
            return pointer[index]
        }
        set {
            precondition(index >= 0 && index < count, "SceneScriptSharedBuffer index out of range")
            pointer[index] = newValue
        }
    }

    /// True once the typed array was detached: JavaScript no longer sees this memory through
    /// `value` (its length is 0).
    var isDetached: Bool {
        JSObjectGetTypedArrayLength(contextRef, object, nil) != count
    }
}

/// Something the runtime checks after each entry into script code (`SceneScriptRuntime.watch`).
protocol SceneScriptDetachable: AnyObject {
    var isDetached: Bool { get }
}

/// The bytes behind a shared buffer, freed with the last reference (Swift's or JavaScriptCore's).
final class SceneScriptSharedMemory {
    let bytes: UnsafeMutableRawPointer

    init(byteCount: Int, alignment: Int) {
        bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: max(alignment, 16))
    }

    deinit {
        bytes.deallocate()
    }
}

/// The element types a shared buffer can hold, with their JavaScript typed-array kind.
protocol SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { get }
    static var zero: Self { get }
}

extension Float: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeFloat32Array }
}

extension Double: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeFloat64Array }
}

extension Int32: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeInt32Array }
}

extension UInt8: SceneScriptSharedElement {
    static var typedArrayType: JSTypedArrayType { kJSTypedArrayTypeUint8Array }
}
