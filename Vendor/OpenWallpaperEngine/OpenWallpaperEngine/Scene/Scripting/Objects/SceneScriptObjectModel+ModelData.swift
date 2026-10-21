import Foundation
import JavaScriptCore
import simd

/// The native half of `objects-modeldata.js`: shapes the script side checked, their typed arrays
/// copied into `SceneScriptModelDataStore`. Each function answers the token (create) or an empty
/// string, else WE's message, which the script side throws.
extension SceneScriptObjectModel {
    func installModelDataFunctions(on objects: JSValue) {
        let store = modelData
        let create: @convention(block) (JSValue, JSValue) -> Any = { shapes, bounds in
            guard let data = Self.modelData(shapes: shapes, bounds: bounds) else { return "Shapes missing." }
            return store.create(data)
        }
        let apply: @convention(block) (Int32, JSValue) -> String = { token, updates in
            do {
                try store.apply(Int(token), Self.modelDataUpdates(updates))
                return ""
            } catch {
                return "\(error)"
            }
        }
        let replace: @convention(block) (Int32, JSValue, JSValue) -> String = { token, shapes, bounds in
            guard let data = Self.modelData(shapes: shapes, bounds: bounds) else { return "Shapes missing." }
            do {
                try store.replace(Int(token), with: data)
                return ""
            } catch {
                return "\(error)"
            }
        }
        let destroy: @convention(block) (Int32) -> Void = { token in store.destroy(Int(token)) }
        objects.setValue(create, forProperty: "createModelData")
        objects.setValue(apply, forProperty: "applyModelData")
        objects.setValue(replace, forProperty: "replaceModelData")
        objects.setValue(destroy, forProperty: "destroyModelData")
    }

    /// The data of checked shapes (`objects-modeldata.js`'s `shape`); nil without a usable one.
    static func modelData(shapes: JSValue, bounds: JSValue) -> SceneScriptModelData? {
        guard shapes.isArray, let count = shapes.forProperty("length")?.toInt32(), count > 0 else { return nil }
        var made: [SceneScriptModelData.Shape] = []
        for index in 0..<Int(count) {
            guard let shape = shapes.atIndex(index), shape.isObject,
                  let vertices = typedArray(shape.forProperty("vertexBuffer")), vertices.type == kJSTypedArrayTypeFloat32Array,
                  let names = shape.forProperty("vertexFormat")?.toArray() as? [String],
                  let format = SceneScriptModelData.format(names),
                  let material = shape.forProperty("material"), material.isString else { return nil }
            let indices = typedArray(shape.forProperty("indexBuffer"))
            let workshop = shape.forProperty("workshop").flatMap { $0.isString ? $0.toString() : nil } ?? ""
            made.append(SceneScriptModelData.Shape(
                format: format,
                materialPaths: SceneScriptLayerSource.assetPaths(material.toString(), workshopID: workshop.isEmpty ? nil : workshop),
                vertices: vertices.bytes, indices: indices?.bytes, usesUInt32Indices: indices?.type == kJSTypedArrayTypeUint32Array,
                dynamicVertices: shape.forProperty("dynamicVertices")?.toBool() ?? false,
                dynamicIndices: shape.forProperty("dynamicIndices")?.toBool() ?? false))
        }
        return SceneScriptModelData(shapes: made, bounds: box(bounds) ?? SceneScriptModelData.positionBounds(made))
    }

    /// `applyData`'s per-shape buffers (each optional).
    static func modelDataUpdates(_ updates: JSValue) -> [SceneScriptModelDataUpdate] {
        guard updates.isArray, let count = updates.forProperty("length")?.toInt32() else { return [] }
        return (0..<Int(count)).map { index in
            let update = updates.atIndex(index)
            let vertices = typedArray(update?.forProperty("vertexBuffer"))
            let indices = typedArray(update?.forProperty("indexBuffer"))
            return SceneScriptModelDataUpdate(vertices: vertices?.bytes, indices: indices?.bytes,
                                              indicesAreUInt32: indices?.type == kJSTypedArrayTypeUint32Array)
        }
    }

    /// `[minX, minY, minZ, maxX, maxY, maxZ]`; nil without one.
    private static func box(_ value: JSValue) -> MDLBounds? {
        guard value.isArray, let numbers = value.toArray() as? [NSNumber], numbers.count == 6 else { return nil }
        let v = numbers.map { $0.floatValue }
        guard v.allSatisfy(\.isFinite) else { return nil }
        return MDLBounds(min: SIMD3(v[0], v[1], v[2]), max: SIMD3(v[3], v[4], v[5]))
    }

    /// A typed array's bytes (a copy) and type; nil for anything else.
    static func typedArray(_ value: JSValue?) -> (bytes: Data, type: JSTypedArrayType)? {
        guard let value, let context = value.context else { return nil }
        let contextRef = context.jsGlobalContextRef
        let type = JSValueGetTypedArrayType(contextRef, value.jsValueRef, nil)
        guard type != kJSTypedArrayTypeNone, type != kJSTypedArrayTypeArrayBuffer,
              let object = JSValueToObject(contextRef, value.jsValueRef, nil) else { return nil }
        let length = JSObjectGetTypedArrayByteLength(contextRef, object, nil)
        guard length > 0, let base = JSObjectGetTypedArrayBytesPtr(contextRef, object, nil) else { return (Data(), type) }
        // The pointer is the start of the whole buffer, not of the view (a `subarray`'s offset).
        let offset = JSObjectGetTypedArrayByteOffset(contextRef, object, nil)
        return (Data(bytes: base + offset, count: length), type)
    }
}
