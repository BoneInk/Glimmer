import Foundation
import WEFormat

/// A material's rendering options as WE's inspector edits them (`ui_editor_properties_blending`,
/// `_culling`, `_depth_test`, `_depth_write`, wallpaperui.exe's material properties): the
/// `blending`, `cullmode`, `depthtest` and `depthwrite` of its passes, written back into the
/// material's JSON as WE writes it.
public struct MaterialShaderOptions: Hashable, Sendable {
    /// WE's blending choices for a material, in its order.
    public enum Blending: String, CaseIterable, Sendable, Identifiable {
        case normal, translucent, additive, alphatocoverage
        public var id: String { rawValue }
    }

    /// WE's culling choices (`nocull`, and `normal`: back faces culled).
    public enum Culling: String, CaseIterable, Sendable, Identifiable {
        case nocull, normal
        public var id: String { rawValue }
    }

    public var blending: Blending
    public var culling: Culling
    public var depthTest: Bool
    public var depthWrite: Bool

    /// The first pass's options; a key the material doesn't set reads as WE's blank effect
    /// writes it (normal, no cull, depth test and write disabled). Nil for text that isn't a
    /// material.
    public init?(material text: String) {
        guard let object = try? TolerantJSON.object(from: Data(text.utf8)) as? [String: Any],
              let pass = (object["passes"] as? [[String: Any]])?.first else { return nil }
        blending = (pass["blending"] as? String).flatMap { Blending(rawValue: $0.lowercased()) } ?? .normal
        culling = ((pass["cullmode"] ?? pass["culling"]) as? String).flatMap { Culling(rawValue: $0.lowercased()) } ?? .nocull
        depthTest = (pass["depthtest"] as? String)?.lowercased() == "enabled"
        depthWrite = (pass["depthwrite"] as? String)?.lowercased() == "enabled"
    }

    public init(blending: Blending = .normal, culling: Culling = .nocull, depthTest: Bool = false, depthWrite: Bool = false) {
        self.blending = blending
        self.culling = culling
        self.depthTest = depthTest
        self.depthWrite = depthWrite
    }

    /// Depth write matters only to opaque drawing that tests depth: WE's inspector greys it out
    /// otherwise (`!['alphatocoverage','normal'].includes(blending) || depthtest != 'enabled'`).
    public var depthWriteApplies: Bool {
        (blending == .normal || blending == .alphatocoverage) && depthTest
    }

    /// `text` (a material) with these options in every pass, as WE's styled JSON; nil when it
    /// isn't a material.
    public func applied(to text: String) -> String? {
        guard let object = try? TolerantJSON.object(from: Data(text.utf8)),
              case .object(var material)? = SceneJSONValue(any: object),
              case .array(let passes)? = material["passes"] else { return nil }
        material["passes"] = .array(passes.map { pass in
            guard case .object(var members) = pass else { return pass }
            members["blending"] = .string(blending.rawValue)
            members["culling"] = nil
            members["cullmode"] = .string(culling.rawValue)
            members["depthtest"] = .string(depthTest ? "enabled" : "disabled")
            members["depthwrite"] = .string(depthWrite ? "enabled" : "disabled")
            return .object(members)
        })
        return SceneJSONValue.object(material).editorJSON
    }
}

extension SceneEditSession {
    /// Writes `options` into the editor's copy of the material at `path` (`text` is its text as
    /// the scene has it), one undo step.
    public func setMaterialOptions(_ options: MaterialShaderOptions, material path: String, text: String, actionName: String) {
        guard let written = options.applied(to: text), written != text else { return }
        setEffectFile(path, text: written, actionName: actionName)
    }
}
