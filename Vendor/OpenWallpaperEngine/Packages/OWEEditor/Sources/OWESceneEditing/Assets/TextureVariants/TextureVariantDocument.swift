import Foundation
import WEFormat

/// A texture's variants as WE's editor authors them (WE 2.6, Texture Properties › Variants; the
/// texture-variant page of WE's docs): groups, each showing at most one of its options, every
/// option an image (or video) of the texture's size and kind, Replace or Alpha-blended, on while
/// its condition (a bool user property, or a combo property having one value) holds. In a group
/// the first option that is on wins; none on shows the base.
///
/// WE keeps them in the texture's `.tex-json` (`"variants": [{"options": [{"file", "blend",
/// "variantcondition"}]}]`) and compiles them into the `.tex`. The editor does the same in its
/// files: the compiled `.tex` and, beside it, this document as its `.tex-json`, with the base
/// texture it was made from (`source`) and each option's source file, so the variants can be
/// edited again.
public struct TextureVariantDocument: Hashable, Sendable {
    public enum Blend: String, CaseIterable, Hashable, Sendable {
        /// The option's texture replaces the base where it differs.
        case replace
        /// The option's pixels are drawn over the base by their alpha (RGBA8888 textures only).
        case alphaBlend = "alphablend"
    }

    public enum Condition: Hashable, Sendable {
        /// On while the bool property is true (`"variantcondition": "<key>"`).
        case flag(String)
        /// On while the combo property has the value (`{"name": "<key>", "condition": "<value>"}`).
        case equals(String, String)

        public var property: String {
            switch self {
            case .flag(let key), .equals(let key, _): return key
            }
        }

        /// The `.tex` option record's condition, as WE's resource compiler writes it (capture 540:
        /// the `.tex-json`'s `variantcondition` under `condition`, keys sorted, no spaces):
        /// `{"condition":"<key>"}` or `{"condition":{"condition":"<value>","name":"<key>"}}`.
        public var compiledJSON: String {
            switch self {
            case .flag(let key): return #"{"condition":"# + Self.quoted(key) + "}"
            case .equals(let key, let value):
                return #"{"condition":{"condition":"# + Self.quoted(value) + #","name":"# + Self.quoted(key) + "}}"
            }
        }

        var json: Any {
            switch self {
            case .flag(let key): return key
            case .equals(let key, let value): return ["name": key, "condition": value]
            }
        }

        init?(json: Any?) {
            if let key = json as? String, !key.isEmpty {
                self = .flag(key)
            } else if let object = json as? [String: Any], let key = object["name"] as? String, !key.isEmpty,
                      let value = object["condition"] {
                self = .equals(key, value as? String ?? "\(value)")
            } else {
                return nil
            }
        }

        static func quoted(_ text: String) -> String {
            // A string fragment is always encodable.
            let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    public struct Option: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// The option's image or video, by scene path (`materials/editor/variants/<name>.png`).
        public var file: String
        public var blend: Blend
        public var condition: Condition?

        public init(id: UUID = UUID(), name: String, file: String, blend: Blend = .replace, condition: Condition? = nil) {
            self.id = id
            self.name = name
            self.file = file
            self.blend = blend
            self.condition = condition
        }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var options: [Option]

        public init(id: UUID = UUID(), name: String, options: [Option] = []) {
            self.id = id
            self.name = name
            self.options = options
        }
    }

    /// The texture the variants go over (`editor/<name>`, a wallpaper's `<name>`), without them.
    public var source: String
    public var groups: [Group]

    public init(source: String, groups: [Group] = []) {
        self.source = source
        self.groups = groups
    }

    // MARK: Compiling

    /// The options as the `.tex` numbers them, from 1 as WE's compiler does (capture 540: group 1,
    /// options 1 and 2): groups by their position, options by their position among all options,
    /// each group's options in its order (the first that is on wins).
    public var compiledOptions: [(group: UInt32, id: UInt32, option: Option)] {
        var result: [(UInt32, UInt32, Option)] = []
        var next: UInt32 = 1
        for (groupIndex, group) in groups.enumerated() {
            for option in group.options {
                result.append((UInt32(groupIndex + 1), next, option))
                next += 1
            }
        }
        return result
    }

    // MARK: The .tex-json

    /// The `.tex-json`: WE's `variants` as its editor writes them (capture 540: each group's `name`
    /// and `options`, each option's `blend`, `file`, `name` and `variantcondition`, `null` while
    /// unset) and the base texture, `source`, which WE's has no need of (its base is the picture
    /// the `.tex-json` sits beside).
    public var json: Data {
        let variants: [[String: Any]] = groups.map { group in
            ["name": group.name, "options": group.options.map { option -> [String: Any] in
                // WE writes `null` for an option without a condition.
                ["name": option.name, "file": option.file, "blend": option.blend.rawValue,
                 "variantcondition": option.condition?.json ?? NSNull()]
            }]
        }
        let root: [String: Any] = ["source": source, "variants": variants]
        // Plain strings, arrays and dictionaries are always encodable.
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// A `.tex-json` with variants; nil when it has none. One without `source` (WE's own) goes over
    /// `texture`, the texture it sits beside.
    public init?(json data: Data, texture: String) {
        // Optional: a `.tex-json` that isn't JSON has no variants the editor can show.
        guard let root = (try? TolerantJSON.object(from: data)) as? [String: Any],
              let variants = root["variants"] as? [[String: Any]] else { return nil }
        source = root["source"] as? String ?? texture
        groups = variants.enumerated().map { index, entry in
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let file = option["file"] as? String else { return nil }
                return Option(name: option["name"] as? String ?? ((file as NSString).lastPathComponent as NSString).deletingPathExtension,
                              file: file, blend: Blend(rawValue: (option["blend"] as? String ?? "").lowercased()) ?? .replace,
                              condition: Condition(json: option["variantcondition"]))
            }
            return Group(name: entry["name"] as? String ?? "Variant \(index + 1)", options: options)
        }
    }

    /// The `.tex-json` path beside a texture (`editor/a` → `materials/editor/a.tex-json`).
    public static func sidecarPath(of texture: String) -> String { "materials/\(texture).tex-json" }
}
