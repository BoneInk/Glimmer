import Foundation

/// The shader editor's Snippets menu as WE's (`codeeditor`'s shader menu in `scripts.js`):
/// Replace Shader, Add Include, Add Constant, Add Variable, and the text each item writes.
/// The insertions follow WE's rules: combos at the top, then includes, then uniforms, each kept
/// with its kind, and nothing written twice.
public enum ShaderSnippets {
    /// A uniform WE's menu declares: its type, name and the annotation after it, if any.
    public struct Uniform: Hashable, Sendable, Identifiable {
        public let type: String
        public let name: String
        public let annotation: String?
        public var id: String { name }
    }

    /// One of Add Constant's groups (WE's `ui_editor_shader_constants_*`).
    public struct ConstantGroup: Hashable, Sendable, Identifiable {
        public enum ID: String, Sendable { case general, view, textureSampler, textureInfo, audio }
        public let id: ID
        public let constants: [Uniform]
    }

    /// A sampler Add Constant › Texture Sampler declares: the next free `g_Texture<n>` with this
    /// annotation (WE's `ui_editor_shader_sampler_*`).
    public struct Sampler: Hashable, Sendable, Identifiable {
        public enum ID: String, Sendable { case basic, single, direction, uniformNoise, perlinNoise }
        public let id: ID
        /// The annotation, as WE writes it (`angular.toJson`, keys in WE's order).
        public let annotation: String
    }

    /// One of Add Variable's items (WE's `ui_editor_shader_variable_*` and `_combo_*`).
    public enum Variable: String, CaseIterable, Sendable, Identifiable {
        case sliderFloat, sliderInt, linkedSliders, colorPicker, uvPicker, knob
        case comboCheckbox, combo2Options, combo3Options
        public var id: String { rawValue }

        /// A uniform with its annotation, or nil for a combo.
        public var uniform: Uniform? {
            switch self {
            case .sliderFloat: return Uniform(type: "float", name: "u_userNewSlider",
                                              annotation: #"{"material":"My new slider","default":1,"range":[0,1]}"#)
            case .sliderInt: return Uniform(type: "float", name: "u_userNewIntSlider",
                                            annotation: #"{"material":"My new slider","int":true,"default":0,"range":[0,10]}"#)
            case .linkedSliders: return Uniform(type: "vec2", name: "u_userNewLinkedSliders",
                                                annotation: #"{"material":"My new linked sliders","linked":true,"default":"0.5 0.5","range":[0,1]}"#)
            case .colorPicker: return Uniform(type: "vec3", name: "u_userNewColor",
                                              annotation: #"{"material":"My new color","type":"color","default":"1 1 1"}"#)
            case .uvPicker: return Uniform(type: "vec2", name: "u_userNewPosition",
                                           annotation: #"{"material":"My new position","position":true,"default":"0.5 0.5"}"#)
            case .knob: return Uniform(type: "float", name: "u_userNewRotation",
                                       annotation: #"{"material":"My rotation","default":3.14159265358,"direction":true,"conversion":"rad2deg"}"#)
            case .comboCheckbox, .combo2Options, .combo3Options: return nil
            }
        }

        /// A combo's declaration, or nil for a uniform.
        public var combo: String? {
            switch self {
            case .comboCheckbox:
                return #"{"material":"My Combo Name","combo":"USERCOMBOIDENTIFIER","type":"options","default":0}"#
            case .combo2Options:
                return #"{"material":"My Combo Name","combo":"USERCOMBOIDENTIFIER","type":"options","default":0,"options":{"Option A":0,"Option B":1}}"#
            case .combo3Options:
                return #"{"material":"My Combo Name","combo":"USERCOMBOIDENTIFIER","type":"options","default":0,"options":{"Option A":0,"Option B":1,"Option C":2}}"#
            default: return nil
            }
        }

        /// Combos come after a divider in WE's menu.
        public var isCombo: Bool { combo != nil }
    }

    /// Replace Shader's items: WE's snippet files (`ui/dist/monaco/snippets/<file>.js`) by stage.
    public enum Replacement: String, CaseIterable, Sendable, Identifiable {
        case basicVertex = "shader_vert_passthrough"
        case maskedVertex = "shader_vert_passthrough_masked"
        case basicFragment = "shader_frag_passthrough"
        case maskedFragment = "shader_frag_passthrough_masked"
        public var id: String { rawValue }
        /// The snippet file's name without `.js`.
        public var file: String { rawValue }
        public var isVertex: Bool { self == .basicVertex || self == .maskedVertex }
    }

    /// Add Include's headers.
    public static let includes = ["common.h", "common_blending.h", "common_fragment.h", "common_vertex.h"]

    /// Add Constant's groups, in WE's order.
    public static let constantGroups: [ConstantGroup] = [
        ConstantGroup(id: .general, constants: [
            .init(type: "float", name: "g_Alpha", annotation: nil), .init(type: "vec3", name: "g_Color", annotation: nil),
            .init(type: "vec4", name: "g_Color4", annotation: nil), .init(type: "float", name: "g_Time", annotation: nil),
            .init(type: "float", name: "g_Daytime", annotation: nil), .init(type: "vec2", name: "g_PointerPosition", annotation: nil),
            .init(type: "vec2", name: "g_PointerPositionLast", annotation: nil), .init(type: "vec2", name: "g_TexelSize", annotation: nil),
            .init(type: "vec2", name: "g_TexelSizeHalf", annotation: nil), .init(type: "vec3", name: "g_Screen", annotation: nil),
            .init(type: "vec2", name: "g_ParallaxPosition", annotation: nil),
        ]),
        ConstantGroup(id: .view, constants: [
            .init(type: "vec3", name: "g_EyePosition", annotation: nil), .init(type: "vec3", name: "g_ViewForward", annotation: nil),
            .init(type: "vec3", name: "g_ViewRight", annotation: nil), .init(type: "vec3", name: "g_ViewUp", annotation: nil),
            .init(type: "vec3", name: "g_OrientationForward", annotation: nil), .init(type: "vec3", name: "g_OrientationRight", annotation: nil),
            .init(type: "vec3", name: "g_OrientationUp", annotation: nil),
            .init(type: "mat4", name: "g_ModelMatrix", annotation: nil), .init(type: "mat4", name: "g_ModelMatrixInverse", annotation: nil),
            .init(type: "mat4", name: "g_ViewProjectionMatrix", annotation: nil),
            .init(type: "mat4", name: "g_ModelViewProjectionMatrix", annotation: nil),
            .init(type: "mat4", name: "g_ModelViewProjectionMatrixInverse", annotation: nil),
            .init(type: "mat3", name: "g_NormalModelMatrix", annotation: nil),
            .init(type: "mat4", name: "g_EffectModelMatrix", annotation: nil),
            .init(type: "mat4", name: "g_EffectModelViewProjectionMatrix", annotation: nil),
            .init(type: "mat4", name: "g_EffectModelViewProjectionMatrixInverse", annotation: nil),
            .init(type: "mat4", name: "g_EffectTextureProjectionMatrix", annotation: nil),
            .init(type: "mat4", name: "g_EffectTextureProjectionMatrixInverse", annotation: nil),
            .init(type: "mat4", name: "g_LayerModelMatrix", annotation: nil),
        ]),
        ConstantGroup(id: .textureInfo, constants: (0..<8).flatMap { slot in [
            Uniform(type: "vec4", name: "g_Texture\(slot)Resolution", annotation: nil),
            Uniform(type: "vec4", name: "g_Texture\(slot)Rotation", annotation: nil),
            Uniform(type: "vec2", name: "g_Texture\(slot)Translation", annotation: nil),
        ] }),
        ConstantGroup(id: .audio, constants: [
            .init(type: "float", name: "g_AudioSpectrum16Left[16]", annotation: nil),
            .init(type: "float", name: "g_AudioSpectrum16Right[16]", annotation: nil),
            .init(type: "float", name: "g_AudioSpectrum32Left[32]", annotation: nil),
            .init(type: "float", name: "g_AudioSpectrum32Right[32]", annotation: nil),
            .init(type: "float", name: "g_AudioSpectrum64Left[64]", annotation: nil),
            .init(type: "float", name: "g_AudioSpectrum64Right[64]", annotation: nil),
        ]),
    ]

    /// Add Constant › Texture Sampler, in WE's order.
    public static let samplers: [Sampler] = [
        Sampler(id: .basic, annotation: #"{"label":"ui_editor_properties_image"}"#),
        Sampler(id: .single, annotation: #"{"label":"ui_editor_properties_opacity","mode":"opacitymask","paintdefaultcolor":"0 0 0 1"}"#),
        Sampler(id: .direction, annotation: #"{"label":"ui_editor_properties_flow_map","mode":"flowmask","default":"util/noflow"}"#),
        Sampler(id: .uniformNoise, annotation: #"{"label":"ui_editor_properties_noise","default":"util/uniform_256"}"#),
        Sampler(id: .perlinNoise, annotation: #"{"label":"ui_editor_properties_perlin_noise","default":"util/perlin_256"}"#),
    ]

    /// WE's limit of samplers a shader the menu adds to (`ui_editor_shader_error_too_many_samplers`).
    public static let samplerLimit = 10

    // MARK: Inserting

    /// `#include "<name>"` after the combos and the includes already there; unchanged when the
    /// shader includes it.
    public static func addingInclude(_ name: String, to text: String) -> String {
        insert("#include \"\(name)\"", into: text, after: [.combos, .includes])
    }

    /// `uniform <type> <name>; // <annotation>` after the combos, includes and uniforms already
    /// there; unchanged when the shader has that line.
    public static func addingUniform(_ uniform: Uniform, to text: String) -> String {
        var line = "uniform \(uniform.type) \(uniform.name);"
        if let annotation = uniform.annotation { line += " // \(annotation)" }
        return insert(line, into: text, after: [.combos, .includes, .uniforms])
    }

    /// `// [COMBO] <declaration>` after the combos already there.
    public static func addingCombo(_ declaration: String, to text: String) -> String {
        insert("// [COMBO] \(declaration)", into: text, after: [.combos])
    }

    public enum SamplerError: Error, Equatable {
        /// The shader has `g_Texture<samplerLimit - 1>` or a higher slot already.
        case tooMany(limit: Int)
    }

    /// The sampler `g_Texture<n>`, `n` one past the highest slot the shader names (WE reads every
    /// `g_Texture<digits>` in it), with the sampler's annotation.
    public static func addingSampler(_ sampler: Sampler, to text: String) throws -> String {
        let slot = nextTextureSlot(in: text)
        guard slot < samplerLimit else { throw SamplerError.tooMany(limit: samplerLimit) }
        return addingUniform(Uniform(type: "sampler2D", name: "g_Texture\(slot)", annotation: sampler.annotation), to: text)
    }

    /// One past the highest `g_Texture<n>` the text names (0 for none).
    public static func nextTextureSlot(in text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: #"g_Texture(\d+)"#)
        var next = 0
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text), let slot = Int(text[range]) { next = max(next, slot + 1) }
        }
        return next
    }

    private enum Block { case combos, includes, uniforms }

    /// WE's insertion: from the top, past blank lines and then each block in turn (with the blank
    /// lines between them), the line goes before the first line of none of them; a blank line
    /// separates it from what follows, and from what precedes when the text doesn't start empty.
    private static func insert(_ line: String, into text: String, after blocks: [Block]) -> String {
        if text.contains(line) { return text }
        var lines = text.components(separatedBy: "\n")
        var index = 0
        func skipBlank() { while index < lines.count - 1, lines[index].isEmpty { index += 1 } }
        var inserted = line
        if !(lines.first ?? "").isEmpty { inserted = "\n" + inserted }
        skipBlank()
        for (position, block) in blocks.enumerated() {
            if position > 0 { skipBlank() }
            let marker: String
            switch block {
            case .combos: marker = "// [COMBO]"
            case .includes: marker = "#include"
            case .uniforms: marker = "uniform"
            }
            while index < lines.count, lines[index].contains(marker) { index += 1 }
        }
        inserted += index < lines.count - 1 && lines[min(index, lines.count - 1)].isEmpty ? "\n" : "\n\n"
        let insertion = inserted.components(separatedBy: "\n")
        // Monaco inserts at column 0 of line `index`: the text's last part joins that line.
        let head = insertion.dropLast()
        let tail = insertion.last ?? ""
        if index < lines.count {
            lines[index] = tail + lines[index]
            lines.insert(contentsOf: head, at: index)
        } else {
            lines.append(contentsOf: head)
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Replacing

    /// The text a Replace Shader snippet writes: WE's file without its leading empty line.
    public static func replacement(_ snippet: String) -> String {
        snippet.hasPrefix("\n") ? String(snippet.dropFirst()) : snippet
    }
}
