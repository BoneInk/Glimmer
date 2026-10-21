import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// The Attachments tab: named points on bones (`MDAT`), which a layer's Set Parent Attachment
/// names. WE lists the bones alphabetically.
struct ModelAttachmentsTab: View {
    @ObservedObject var editor: ModelEditorModel
    @State private var selection: UInt64?

    var body: some View {
        ModelEditorColumns {
            ModelEditorList(title: ML("Attachments"), items: editor.config.attachments, selection: $selection) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.bone).font(.caption).foregroundStyle(.secondary)
                }
            } buttons: {
                Button(ML("Add Attachment")) { selection = editor.addAttachment() }
                    .disabled(editor.bones.isEmpty)
                Button { selection.map(editor.removeAttachment); selection = nil } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
        } right: {
            if editor.bones.isEmpty {
                Text(ML("The model has no bones.")).foregroundStyle(.secondary)
            } else if let id = selection, let item = editor.config.attachments.first(where: { $0.id == id }) {
                Section(ML("Attachment options")) {
                    TextField(ML("Name"), text: Binding(get: { item.name }, set: { name in editor.updateAttachment(id) { $0.name = name } }))
                    Picker(ML("Bone"), selection: Binding(get: { item.bone }, set: { bone in editor.updateAttachment(id) { $0.bone = bone } })) {
                        ForEach(editor.sortedBones, id: \.self) { Text($0).tag($0) }
                    }
                    ModelVectorField(title: ML("Origin"), value: Binding(get: { item.origin }, set: { value in
                        editor.updateAttachment(id) { $0.origin = value }
                    }))
                    ModelVectorField(title: ML("Angles"), value: Binding(get: { item.angles * (180 / .pi) }, set: { value in
                        editor.updateAttachment(id) { $0.angles = value * (.pi / 180) }
                    }))
                }
            } else {
                Text(ML("Add an attachment to hang other layers from a bone.")).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Events tab: named frames of an animation or clip, which a scene's scripts receive
/// (`animationEvent`).
struct ModelEventsTab: View {
    @ObservedObject var editor: ModelEditorModel
    @State private var animation: UInt64?
    @State private var event: UInt64?

    static func frameText(_ frame: Float) -> String {
        let number = Int(frame)
        return ML("Frame \(number)")
    }

    var body: some View {
        ModelEditorColumns {
            ModelEditorList(title: ML("Animations"), items: editor.output?.animations ?? [], selection: $animation) { item in
                Label(item.listTitle, systemImage: item.isClip ? "film" : "figure.walk")
            } buttons: {
                Button(ML("Add Event")) { animation.map { event = editor.addEvent(to: $0) } }
                    .disabled(animation == nil)
            }
        } right: {
            if let animation {
                let events = editor.config.events.filter { $0.animation == animation }.sorted { $0.frame < $1.frame }
                Section(ML("Events")) {
                    if events.isEmpty { Text(ML("No events.")).foregroundStyle(.secondary) }
                    ForEach(events) { item in
                        HStack {
                            Button(item.name) { event = item.id }.buttonStyle(.plain).fontWeight(event == item.id ? .semibold : .regular)
                            Spacer()
                            Text(ModelEventsTab.frameText(item.frame)).foregroundStyle(.secondary)
                            Button { editor.removeEvent(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                if let id = event, let item = events.first(where: { $0.id == id }) {
                    Section(ML("Event options")) {
                        TextField(ML("Name"), text: Binding(get: { item.name }, set: { name in editor.updateEvent(id) { $0.name = name } }))
                        ModelFrameField(title: ML("Frame"), value: Binding(get: { Int(item.frame) }, set: { value in
                            let frames = editor.animation(animation)?.frames ?? 0
                            editor.updateEvent(id) { $0.frame = Float(min(max(value, 0), frames)) }
                        }))
                    }
                }
            } else {
                Text(ML("Pick an animation or clip.")).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Constraints tab: each bone's physics, as Puppet Warp's (presets, spring or rigid,
/// rotation and position springs per axis, gravity, limits).
struct ModelConstraintsTab: View {
    @ObservedObject var editor: ModelEditorModel
    @State private var bone: String?
    @State private var copied: PuppetBonePhysics?

    struct BoneItem: Identifiable { var id: String }

    var body: some View {
        ModelEditorColumns {
            ModelEditorList(title: ML("Bones"), items: editor.sortedBones.map(BoneItem.init), selection: $bone) { item in
                Label(item.id, systemImage: editor.config.constraints[item.id] == nil ? "circle" : "circle.inset.filled")
            } buttons: {
                EmptyView()
            }
        } right: {
            if let bone {
                settings(bone, editor.config.constraints[bone])
            } else {
                Text(editor.bones.isEmpty ? ML("The model has no bones.") : ML("Pick a bone to give it physics."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ bone: String, _ physics: PuppetBonePhysics?) {
        editor.config.constraints[bone] = physics
        editor.refresh()
    }

    private func update(_ bone: String, _ change: (inout PuppetBonePhysics) -> Void) {
        guard var physics = editor.config.constraints[bone] else { return }
        change(&physics)
        editor.config.constraints[bone] = physics
    }

    @ViewBuilder private func settings(_ bone: String, _ physics: PuppetBonePhysics?) -> some View {
        Section(ML("Constraint options")) {
            Toggle(PL("Simulate This Bone"), isOn: Binding(get: { physics != nil }, set: { set(bone, $0 ? PuppetBonePhysics() : nil) }))
            if physics != nil {
                Menu(PL("Preset")) {
                    ForEach(PuppetBonePhysics.Preset.allCases, id: \.self) { preset in
                        Button(preset.title) { set(bone, PuppetBonePhysics(preset: preset)) }
                    }
                }
                Picker(PL("Kind"), selection: Binding(get: { physics?.kind ?? .spring }, set: { kind in update(bone) { $0.kind = kind } })) {
                    Text(PL("Spring")).tag(PuppetBonePhysics.Kind.spring)
                    Text(PL("Rigid")).tag(PuppetBonePhysics.Kind.rigid)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button(PL("Reset")) { set(bone, PuppetBonePhysics()) }
                    Button(ML("Copy")) { copied = physics }
                    Button(ML("Paste")) { copied.map { set(bone, $0) } }.disabled(copied == nil)
                }
            }
        }
        if let physics {
            Section(PL("Rotation")) {
                toggle(PL("Simulate Rotation"), \.rotation, bone, physics)
                if physics.rotation {
                    slider(PL("Stiffness"), \.rotationStiffness, 0...1000, bone, physics)
                    slider(PL("Friction"), \.rotationFriction, 0...100, bone, physics)
                    slider(PL("Inertia"), \.rotationInertia, 0...100, bone, physics)
                    axes(ML("Rotation axes"), \.rotationAxes, bone, physics)
                }
            }
            Section(PL("Position")) {
                toggle(PL("Simulate Position"), \.translation, bone, physics)
                if physics.translation {
                    slider(PL("Stiffness"), \.translationStiffness, 0...1000, bone, physics)
                    slider(PL("Friction"), \.translationFriction, 0...100, bone, physics)
                    slider(PL("Inertia"), \.translationInertia, 0...100, bone, physics)
                    slider(PL("Maximum Distance"), \.maxDistance, 0...1000, bone, physics)
                    axes(ML("Position axes"), \.translationAxes, bone, physics)
                }
            }
            Section(PL("Gravity")) {
                toggle(PL("Gravity"), \.gravity, bone, physics)
                if physics.gravity {
                    ModelVectorField(title: PL("Direction"), value: Binding(get: { physics.gravityDirection }, set: { value in
                        update(bone) { $0.gravityDirection = value }
                    }))
                    slider(PL("Mass"), \.mass, 0...1000, bone, physics)
                }
            }
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<PuppetBonePhysics, Bool>, _ bone: String, _ physics: PuppetBonePhysics) -> some View {
        Toggle(title, isOn: Binding(get: { physics[keyPath: key] }, set: { on in update(bone) { $0[keyPath: key] = on } }))
    }

    private func slider(_ title: String, _ key: WritableKeyPath<PuppetBonePhysics, Float>, _ range: ClosedRange<Float>,
                        _ bone: String, _ physics: PuppetBonePhysics) -> some View {
        LabeledContent(title) {
            NumericSliderInput<Float>(value: Binding(get: { physics[keyPath: key] }, set: { value in update(bone) { $0[keyPath: key] = value } }),
                                      range: range, defaultValue: PuppetBonePhysics()[keyPath: key], step: 1, fractionDigits: 0, fieldWidth: 52,
                                      clampsTypedValue: false)
        }
    }

    private func axes(_ title: String, _ key: WritableKeyPath<PuppetBonePhysics, PuppetAxes>, _ bone: String, _ physics: PuppetBonePhysics) -> some View {
        LabeledContent(title) {
            HStack {
                ForEach(0..<3, id: \.self) { axis in
                    Toggle(["X", "Y", "Z"][axis], isOn: Binding(get: { physics[keyPath: key][axis] }, set: { on in
                        update(bone) { $0[keyPath: key][axis] = on }
                    }))
                }
            }
        }
    }
}
