import Foundation

/// The texture variants a `.tex` declares (WE 2.6, "Texture Properties › Variants"): textures of
/// the base's size and type a user property swaps in or blends over the base.
///
/// They aren't in scene.json. The editor keeps them in the texture's `.tex-json`
/// (`"variants": [{"options": [{"file", "blend": "replace" | "alphablend", "variantcondition"}]}]`)
/// and the resource compiler bakes them into the `.tex`, which WE's loader reads
/// (`wallpaper64.exe` 0x14015c8d0, the `TEXB` reader):
///
/// ```
/// "TEXB0004\0"  u32 image count, i32 FreeImage format, u32 option count
/// per option:   u32 group, u32 option id, u32 blend, NUL-terminated JSON condition
/// per image:    u32 mipmap count
///   per mipmap: u32 width, height, compression, uncompressed size, stored size, bytes
///               then, with options: u32 group count, per group u32 patch count,
///               per patch u32 group, u32 option id, u32 x, y, width, height,
///               i32 FreeImage format, u32 stored size, bytes
/// ```
///
/// A condition is `{"condition": "<bool property>"}` (on while the property is true) or
/// `{"condition": {"name": "<combo property>", "condition": "<value>"}}` (on while the property
/// has that value). In each group only the first option that is on applies; a group whose
/// options are all off shows the base (`TEXVariantResolver`).
struct TEXVariants: Equatable {
    /// How an option's patches go into the base mipmap (its `blend` word).
    struct Blend: OptionSet, Hashable {
        let rawValue: UInt32

        /// Drawn over the base by the patch's alpha ("Alpha-blended"); RGBA8888 textures only.
        static let alphaBlend = Blend(rawValue: 1)
        /// The patch's bytes are the whole mipmap, stored as the base's are (a replaced video or
        /// a replaced picture of the same encoding).
        static let wholeMipmap = Blend(rawValue: 2)
    }

    enum Condition: Hashable {
        /// On while the bool property is true.
        case flag(property: String)
        /// On while the combo property has `value`.
        case equals(property: String, value: String)

        var property: String {
            switch self {
            case .flag(let property), .equals(let property, _): return property
            }
        }

        /// `{"condition": "<name>"}` or `{"condition": {"name", "condition"}}`; nil for anything
        /// else, which WE's loader never turns on.
        init?(json text: String) {
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            } catch {
                OWELog.error(.texture, "A texture variant's condition isn't JSON (\(text)): \(error)")
                return nil
            }
            guard let fields = object as? [String: Any] else { return nil }
            if let name = fields["condition"] as? String {
                self = .flag(property: name)
            } else if let binding = fields["condition"] as? [String: Any], let name = binding["name"] as? String,
                      let value = binding["condition"] {
                self = .equals(property: name, value: value as? String ?? "\(value)")
            } else {
                return nil
            }
        }
    }

    struct Option: Equatable {
        let group: UInt32
        let id: UInt32
        let blend: Blend
        /// Nil when the record has none WE reads: the option is never on.
        let condition: Condition?
    }

    let options: [Option]

    /// The options each group shows when `isOn` says which conditions hold: the first option of
    /// a group that is on, by option id with its blend.
    func enabled(_ isOn: (Condition) -> Bool) -> [UInt32: Blend] {
        var groups: Set<UInt32> = []
        var chosen: [UInt32: Blend] = [:]
        for option in options {
            guard let condition = option.condition, isOn(condition), !groups.contains(option.group) else { continue }
            groups.insert(option.group)
            chosen[option.id] = option.blend
        }
        return chosen
    }

    /// The variants `data` declares; nil when it is not a `TEXB0004` `.tex` with any.
    init?(texData data: Data) {
        guard var reader = TEXReader(data), reader.header.variantCount > 0,
              let options = reader.options(count: reader.header.variantCount) else { return nil }
        self.options = options
    }

    init(options: [Option]) {
        self.options = options
    }

    /// Whether `data` is a `.tex` that declares variants, read from its header alone.
    static func declares(in data: Data) -> Bool {
        // The header is in the first hundred bytes; the file isn't copied to read it.
        guard let header = TEXHeader([UInt8](data.prefix(128))) else { return false }
        return header.variantCount > 0
    }
}

extension TEXReader {
    /// The option records after a `TEXB0004` header (`TEXVariants` has the layout).
    mutating func options(count: Int) -> [TEXVariants.Option]? {
        // Each record is at least three words and a NUL.
        guard count <= (bytes.count - cursor) / 13 else { return nil }
        var options: [TEXVariants.Option] = []
        for _ in 0..<count {
            guard let group = word(), let id = word(), let blend = word(), let condition = string() else { return nil }
            options.append(TEXVariants.Option(group: group, id: id, blend: TEXVariants.Blend(rawValue: blend),
                                              condition: TEXVariants.Condition(json: condition)))
        }
        return options
    }
}
