import OWEInspectorKit
import OWESceneEditing
import SwiftUI
import UniformTypeIdentifiers

/// The Model Editor's text, from its own catalog (`Resources/ModelEditor.xcstrings`).
let ML = EditorText(table: "ModelEditor")

/// WE's Model Editor (Configure Model; `editormodeleditormodal.html` in WE 2.8): the tabs
/// Animation, Attachments, Events and Constraints, and Materials for what WE puts in Advanced
/// Texture Settings. WE 2.8 ships its Blend Layers and Transitions tabs commented out, so they
/// aren't here (docs/model-import.md). OK compiles the model again and points the layers at it.
struct ModelEditorView: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    @StateObject var editor: ModelEditorModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable { case animation, attachments, events, constraints, materials }
    @State private var tab = Tab.animation

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                ModelAnimationTab(editor: editor, session: session, layer: layer)
                    .tabItem { Text(ML("Animation")) }.tag(Tab.animation)
                ModelAttachmentsTab(editor: editor)
                    .tabItem { Text(ML("Attachments")) }.tag(Tab.attachments)
                ModelEventsTab(editor: editor)
                    .tabItem { Text(ML("Events")) }.tag(Tab.events)
                ModelConstraintsTab(editor: editor)
                    .tabItem { Text(ML("Constraints")) }.tag(Tab.constraints)
                ModelMaterialsTab(editor: editor)
                    .tabItem { Text(ML("Materials")) }.tag(Tab.materials)
            }
            .padding([.horizontal, .top], 12)
            if let problem = editor.problem {
                Text(problem).foregroundStyle(.red).font(.callout).padding(.horizontal, 14).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.top, 8)
            HStack {
                Text(editor.model).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(ML("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(ML("OK")) {
                    if !editor.hasChanges || editor.apply(to: session) != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 600)
    }
}

/// Two columns, as WE's tabs lay out: lists on the left, the selection's options on the right.
struct ModelEditorColumns<Left: View, Right: View>: View {
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8, content: left).frame(width: 280)
            Divider()
            Form { right() }.formStyle(.grouped).frame(maxWidth: .infinity)
        }
        .padding(8)
    }
}

/// A titled list with its buttons under it.
struct ModelEditorList<Item: Identifiable, Row: View, Buttons: View>: View {
    let title: String
    let items: [Item]
    @Binding var selection: Item.ID?
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            List(selection: $selection) {
                ForEach(items) { item in row(item).tag(item.id) }
            }
            .listStyle(.bordered)
            HStack { buttons() }
        }
    }
}

/// A frame number field.
struct ModelFrameField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number).labelsHidden().frame(width: 80)
            Stepper(title, value: $value, in: 0...100_000).labelsHidden()
        }
    }
}

/// x, y, z fields.
struct ModelVectorField: View {
    let title: String
    @Binding var value: SIMD3<Float>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { axis in
                    TextField(["X", "Y", "Z"][axis], value: Binding(get: { Double(value[axis]) }, set: { value[axis] = Float($0) }),
                              format: .number.precision(.fractionLength(0...4)))
                        .labelsHidden().frame(width: 64)
                }
            }
        }
    }
}

extension ModelCompiler.AnimationInfo {
    var listTitle: String { name.isEmpty ? ML("Animation \(id)") : name }
}
