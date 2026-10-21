import Foundation

/// One `{"user": …}` occurrence in a document the scene loads: WE's one binding form, anywhere a
/// value can be authored (`{"user": "<name>", "value": …}`, or `{"user": {"name", "condition"},
/// "value": …}` for a flag that is whether the property equals `condition`). Materials also bind
/// through `usershadervalues` (`{"<property>": "<constant key>"}`), which is recorded the same way.
/// Recorded by `UserPropertyBindingTable`, which resolves every bound value.
struct UserPropertyBinding: Equatable {
    /// The user property.
    let name: String
    /// For the condition form: the value the property is compared with.
    let condition: String?
    /// The authored `value`, the fallback while the property has no value; nil when absent.
    let defaultValue: SceneJSON?
    /// The document and the exact JSON path of the bound value (the object holding `user`).
    let site: UserPropertyBindingSite
    /// What the value drives.
    let target: UserPropertyBindingTarget
    /// What a change of the property invalidates.
    let dependency: UserPropertyBindingDependency
    /// The scene object (or the scene) whose state the value belongs to.
    let owner: UserPropertyBindingOwner
    /// The resolved document holds the bare value in place of the binding object: a structural
    /// site with nothing but `user` and `value`, which no live path reads, so every parser reads
    /// it as a plain value of its type (a combo as an int, a size as a string). Other sites keep
    /// the object, `value` resolved, for the paths that follow the binding.
    var collapses = false
}

/// Where a bound value is: a document and a JSON path inside it.
struct UserPropertyBindingSite: Hashable, CustomStringConvertible {
    let document: UserPropertyBindingDocument
    let path: UserPropertyBindingPath

    var description: String { "\(document):\(path)" }
}

/// A document the scene loads: scene.json itself, or a JSON file it pulls in (an effect, material,
/// particle system, model or font description), by its path inside the wallpaper, a Workshop
/// dependency or WE's assets.
enum UserPropertyBindingDocument: Hashable, CustomStringConvertible {
    case scene
    case asset(String)

    var description: String {
        switch self {
        case .scene: return "scene.json"
        case .asset(let path): return path
        }
    }
}

/// A JSON path: object keys and array indices from the document's root.
struct UserPropertyBindingPath: Hashable, CustomStringConvertible, ExpressibleByArrayLiteral {
    enum Component: Hashable {
        case key(String)
        case index(Int)
    }

    var components: [Component]

    init(_ components: [Component] = []) { self.components = components }
    init(arrayLiteral elements: Component...) { components = elements }

    func appending(_ component: Component) -> UserPropertyBindingPath {
        UserPropertyBindingPath(components + [component])
    }

    /// The key at `position`, nil for an index or past the end.
    func key(at position: Int) -> String? {
        guard components.indices.contains(position), case .key(let key) = components[position] else { return nil }
        return key
    }

    /// The index at `position`, nil for a key or past the end.
    func index(at position: Int) -> Int? {
        guard components.indices.contains(position), case .index(let index) = components[position] else { return nil }
        return index
    }

    var count: Int { components.count }

    /// `objects/3/effects/0/passes/0/constantshadervalues/strength`.
    var description: String {
        components.map {
            switch $0 {
            case .key(let key): return key
            case .index(let index): return String(index)
            }
        }.joined(separator: "/")
    }
}

/// What a bound value invalidates when its property changes (`UserPropertyBindingClassifier`).
enum UserPropertyBindingDependency: Int, Comparable {
    /// A shader constant or colour on pipelines that stay: the value is updated in place for the
    /// next frame.
    case uniform = 0
    /// A transform, alpha, visibility, text, particle override or script-visible value: the
    /// owner's state is updated and the owner marked dirty.
    case object = 1
    /// A combo, texture, size or condition that adds or removes layers or effects: the owner is
    /// rebuilt off the render thread and swapped in. Paths nothing classifies land here.
    case structural = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whose state a bound value belongs to.
enum UserPropertyBindingOwner: Hashable, Comparable {
    /// The scene as a whole: `general`, or anything outside the scene's objects.
    case scene
    /// A scene object by its scene.json id (fallback ids assigned, `SceneObjectIdentity`).
    case object(Int)

    /// The renderer's key for the object (`SceneMetalLayer.id`), nil for the scene.
    var objectKey: String? {
        if case .object(let id) = self { return String(id) }
        return nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.scene, .object): return true
        case (.object(let a), .object(let b)): return a < b
        default: return false
        }
    }
}

/// The typed value a binding drives.
enum UserPropertyBindingTarget: Hashable {
    /// `origin`, `scale`, `angles`, `color`, `alpha`, `brightness`, `size`, `pointsize` of an object.
    case objectField(SceneObjectValueField)
    /// An object's `visible`.
    case objectVisible
    /// A text object's `text`.
    case text
    /// `visible` of entry `effect` of an object's `effects`.
    case effectVisible(effect: Int)
    /// A `constantshadervalues` entry: of an object's effect pass, an object's own `instance`, or
    /// a material or effect document's pass (`effect` nil).
    case shaderConstant(effect: Int?, pass: Int, key: String)
    /// A `combos` entry, which picks a shader variant.
    case combo(effect: Int?, pass: Int, key: String)
    /// A material's `usershadervalues` entry, which binds constant `key` to the property.
    case userShaderValue(key: String)
    /// A particle object's `instanceoverride` field.
    case instanceOverride(String)
    /// A field of entry `layer` of an object's `animationlayers`.
    case animationLayer(layer: Int, field: String)
    /// A field of `general`.
    case general(String)
    /// A `scriptproperties` entry of a script-driven value, or a value a script drives.
    case scriptValue(String)
    /// Anything else, by path: resolved like every other binding, and rebuilt with its owner.
    case other(String)
}
