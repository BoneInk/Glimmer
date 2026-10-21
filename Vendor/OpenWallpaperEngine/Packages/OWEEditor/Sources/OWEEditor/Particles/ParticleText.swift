import Foundation
import OWEInspectorKit
import OWESceneEditing

/// The particle editor's text, from its own catalog (`Particles/Resources/Particles.xcstrings`),
/// which holds every language the app ships.
let PartL = EditorText(table: "Particles")

/// A text the schema names (a field's label, a component's name, an option): WE's English
/// wording, translated by the same catalog.
func PLSchema(_ english: String) -> String {
    Bundle.module.localizedString(forKey: english, value: english, table: "Particles")
}

extension ParticleEditorSchema.Section {
    /// The panel section's heading.
    var title: String {
        switch self {
        case .emitter: return PartL("Emitters")
        case .initializer: return PartL("Initializers")
        case .operator: return PartL("Operators")
        case .renderer: return PartL("Renderers")
        case .children: return PartL("Children")
        case .controlpoint: return PartL("Control Points")
        case .system: return PartL("General")
        case .instanceoverride: return PartL("Instance Override")
        }
    }

    /// The Add menu's title for the section.
    var addTitle: String {
        switch self {
        case .emitter: return PartL("Add Emitter")
        case .initializer: return PartL("Add Initializer")
        case .operator: return PartL("Add Operator")
        case .renderer: return PartL("Add Renderer")
        case .children: return PartL("Add Child")
        case .controlpoint: return PartL("Add Control Point")
        case .system, .instanceoverride: return PartL("Add")
        }
    }

    /// Shown when the list is empty.
    var emptyText: String {
        switch self {
        case .emitter: return PartL("No emitters: the system spawns nothing.")
        case .initializer: return PartL("No initializers")
        case .operator: return PartL("No operators")
        case .renderer: return PartL("No renderer: sprites are drawn.")
        case .children: return PartL("No child systems")
        case .controlpoint: return PartL("No control points")
        case .system, .instanceoverride: return ""
        }
    }
}

extension ParticleEditorSchema.Component {
    var localizedTitle: String { PLSchema(title) }
}

extension ParticleEditorSchema.Field {
    var localizedLabel: String { PLSchema(label) }

    /// A vector component's name: the axis letters as they are, words translated.
    func localizedComponent(_ index: Int) -> String {
        guard components.indices.contains(index) else { return ["X", "Y", "Z", "W"][min(index, 3)] }
        let name = components[index]
        return name.count == 1 ? name : PLSchema(name)
    }
}

extension ParticleEditorSchema.Option {
    var localizedLabel: String { PLSchema(label) }
}
