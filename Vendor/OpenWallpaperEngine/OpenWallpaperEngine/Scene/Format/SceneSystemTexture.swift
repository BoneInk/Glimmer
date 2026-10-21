import Foundation

/// A texture WE supplies at run time, which a `usertextures` entry binds to a texture slot by name:
/// `{"name": "$mediaThumbnail", "type": "system"}`. The now-playing artwork and the one before it.
enum SceneSystemTexture: String, CaseIterable {
    case mediaThumbnail = "$mediaThumbnail"
    case mediaPreviousThumbnail = "$mediaPreviousThumbnail"

    /// The name of the system texture a `usertextures` array binds to `slot`; nil when the slot has
    /// none or a user property's texture (a plain string, `SceneUserTexture`).
    static func name(in userTextures: SceneJSON?, slot: Int) -> String? {
        guard case .array(let entries)? = userTextures, slot < entries.count,
              case .object(let entry) = entries[slot], case .string("system")? = entry["type"],
              case .string(let name)? = entry["name"] else { return nil }
        return name
    }

    /// The system texture bound to `slot` by the first of `userTextures` (most specific first: an
    /// object's `instance` or pass, then its material) whose slot names one; nil for none.
    static func name(in userTextures: [SceneJSON?], slot: Int) -> String? {
        userTextures.lazy.compactMap { name(in: $0, slot: slot) }.first
    }

    /// Every slot the arrays bind to a system texture this app supplies, most specific first
    /// (`name(in:slot:)`). A name it doesn't supply is logged and the slot keeps its texture.
    static func bindings(in userTextures: [SceneJSON?], owner: String) -> [Int: SceneSystemTexture] {
        let count = userTextures.map { value -> Int in
            if case .array(let entries)? = value { return entries.count }
            return 0
        }.max() ?? 0
        var bindings: [Int: SceneSystemTexture] = [:]
        for slot in 0..<count {
            guard let name = name(in: userTextures, slot: slot) else { continue }
            guard let texture = SceneSystemTexture(rawValue: name) else {
                OWELog.error(.scene, "\(owner) binds the system texture \(name) to slot \(slot), which isn't supplied; it keeps its texture")
                continue
            }
            bindings[slot] = texture
        }
        return bindings
    }
}
