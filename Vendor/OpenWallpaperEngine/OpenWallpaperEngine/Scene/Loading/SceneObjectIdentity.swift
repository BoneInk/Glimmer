//
//  SceneObjectIdentity.swift
//  Open Wallpaper Engine
//

/// The id an object is known by when scene.json leaves `id` out. The transform hierarchy keys
/// such objects by their index in `objects`; layers, visibility and property keys use the same
/// id so a parent lookup, a layer and its controls all agree.
enum SceneObjectIdentity {
    /// Object `index`'s id: its authored `id`, else its index in `objects`.
    static func id(of object: WESceneObject, at index: Int) -> Int {
        object.id ?? index
    }

    static func assigningFallbackIDs(_ objects: [WESceneObject]) -> [WESceneObject] {
        objects.enumerated().map { index, object in
            guard object.id == nil else { return object }
            var keyed = object
            keyed.id = id(of: object, at: index)
            return keyed
        }
    }
}
