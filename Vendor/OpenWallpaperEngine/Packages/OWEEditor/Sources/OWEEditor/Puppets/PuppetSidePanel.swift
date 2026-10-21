import OWEInspectorKit
import OWESceneEditing
import simd
import SwiftUI

/// The tool's panel beside the puppet canvas.
struct PuppetSidePanel: View {
    @ObservedObject var workspace: PuppetWorkspace

    var body: some View {
        Form {
            switch workspace.tool {
            case .mesh: PuppetMeshPanel(workspace: workspace)
            case .skeleton: PuppetSkeletonPanel(workspace: workspace)
            case .weights: PuppetWeightsPanel(workspace: workspace)
            case .animate: PuppetAnimationPanel(workspace: workspace)
            case .physics: PuppetPhysicsPanel(workspace: workspace)
            case .clipping: PuppetClippingPanel(workspace: workspace)
            }
            if let document = workspace.document, !document.problems.isEmpty {
                Section {
                    ForEach(Array(document.problems.enumerated()), id: \.offset) { _, problem in
                        Label(problem.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } footer: {
                    Text(PL("Save as New Wallpaper writes the puppet once these are fixed."))
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension PuppetProblem {
    var text: String {
        switch self {
        case .noBones: return PL("The puppet has no bones.")
        case .tooManyBones: return PL("Wallpaper Engine allows at most 128 bones.")
        case .noMesh: return PL("The puppet has no mesh.")
        case .unweightedVertices(let number): return PL("\(number) vertices have no weights.")
        }
    }
}

// MARK: - Mesh

private struct PuppetMeshPanel: View {
    @ObservedObject var workspace: PuppetWorkspace
    @State private var isConfirmingGenerate = false

    private var thresholdBinding: Binding<Double> {
        return Binding<Double>(get: { Double(workspace.meshOptions.threshold) },
                               set: { (value: Double) in workspace.meshOptions.threshold = UInt8(min(max(value, 0), 254)) })
    }

    var body: some View {
        Section(PL("Generate from Alpha")) {
            LabeledContent(PL("Point Spacing")) {
                NumericSliderInput(value: $workspace.meshOptions.spacing, range: 6...200, defaultValue: 40, step: 1, suffix: " px",
                                   fractionDigits: 0, fieldWidth: 52)
            }
            .help(PL("Pixels between the mesh's points: smaller makes a denser mesh that bends more smoothly."))
            LabeledContent(PL("Edge Padding")) {
                NumericSliderInput(value: $workspace.meshOptions.padding, range: 0...32, defaultValue: 2, step: 1, suffix: " px",
                                   fractionDigits: 0, fieldWidth: 52)
            }
            LabeledContent(PL("Alpha Threshold")) {
                NumericSliderInput<Double>(value: thresholdBinding, range: 0...254, defaultValue: 8, step: 1,
                                           fractionDigits: 0, fieldWidth: 52)
            }
            Button(PL("Generate Mesh")) { isConfirmingGenerate = true }
                .disabled(workspace.source?.texture == nil)
                .confirmationDialog(PL("Replace the Mesh?"), isPresented: $isConfirmingGenerate) {
                    Button(PL("Generate Mesh")) { workspace.generateMesh() }
                } message: {
                    Text(PL("The new mesh is weighted to the bones automatically. You can undo this."))
                }
        }
        Section(PL("Edit")) {
            Picker(PL("Click To"), selection: $workspace.meshTool) {
                Text(PL("Select")).tag(PuppetWorkspace.MeshTool.select)
                Text(PL("Add Vertices")).tag(PuppetWorkspace.MeshTool.add)
            }
            .pickerStyle(.segmented)
            Button(PL("Delete Selected Vertices")) { workspace.deleteSelectedVertices() }
                .disabled(workspace.selectedVertices.isEmpty)
            if let document = workspace.document {
                LabeledContent(PL("Vertices"), value: String(document.mesh.vertices.count))
                LabeledContent(PL("Triangles"), value: String(document.mesh.triangles.count))
                LabeledContent(PL("Selected"), value: String(workspace.selectedVertices.count))
            }
        }
        PuppetTextureChannelsSection(channels: workspace.document?.preserved.textureChannels ?? [])
    }
}

/// The rig's texture channels, read only: Wallpaper Engine's editor makes them (Puppet Warp ›
/// Texture Channels), and saving writes them back as they were.
private struct PuppetTextureChannelsSection: View {
    let channels: [PuppetPreservedData.TextureChannelMesh]

    var body: some View {
        if !channels.isEmpty {
            Section {
                ForEach(Array(channels.enumerated()), id: \.offset) { _, mesh in
                    LabeledContent(PL("Channels"), value: mesh.channelCount.formatted())
                    LabeledContent(PL("Material")) { Text(verbatim: mesh.material).textSelection(.enabled) }
                }
            } header: {
                Text(PL("Texture Channels"))
            } footer: {
                Text(PL("Made in Wallpaper Engine's editor. Saving keeps them as they are."))
            }
        }
    }
}

// MARK: - Bones

/// The bones as a hierarchy, the selected one highlighted.
private struct PuppetBoneList: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var workspace: PuppetWorkspace

    var body: some View {
        if let document = workspace.document {
            ForEach(Self.order(document), id: \.bone) { entry in
                let bone = document.bones[entry.bone]
                Button {
                    workspace.selectedBone = entry.bone
                    workspace.refreshPose()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: bone.ik != nil ? "link" : bone.physics != nil ? "wind" : "line.diagonal")
                            .foregroundStyle(bone.ik != nil ? .yellow : bone.physics != nil ? .orange : .secondary)
                        Text(bone.name)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(entry.depth) * 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(workspace.selectedBone == entry.bone ? accentColor.opacity(0.25) : nil)
            }
        }
    }

    /// Depth-first, children under their parent.
    static func order(_ document: PuppetDocument) -> [(bone: Int, depth: Int)] {
        var result: [(Int, Int)] = []
        func visit(_ bone: Int, _ depth: Int) {
            result.append((bone, depth))
            for child in document.children(of: bone) { visit(child, depth + 1) }
        }
        for bone in document.bones.indices where document.bones[bone].parent == nil { visit(bone, 0) }
        return result.map { (bone: $0.0, depth: $0.1) }
    }
}

private struct PuppetSkeletonPanel: View {
    @ObservedObject var workspace: PuppetWorkspace
    @State private var name = ""

    var body: some View {
        Section(PL("Bones")) {
            Picker(PL("Click To"), selection: $workspace.skeletonTool) {
                Text(PL("Select")).tag(PuppetWorkspace.SkeletonTool.select)
                Text(PL("Add Bones")).tag(PuppetWorkspace.SkeletonTool.add)
            }
            .pickerStyle(.segmented)
            .help(PL("Adding: drag from the new bone's joint toward its end; it goes under the selected bone."))
            PuppetBoneList(workspace: workspace)
        }
        if let document = workspace.document, let bone = workspace.selectedBone, document.bones.indices.contains(bone) {
            PuppetSelectedBoneSection(workspace: workspace, document: document, bone: bone, name: $name)
            PuppetBlendRulesSection(workspace: workspace, document: document, bone: bone)
        }
    }
}

private struct PuppetSelectedBoneSection: View {
    @ObservedObject var workspace: PuppetWorkspace
    let document: PuppetDocument
    let bone: Int
    @Binding var name: String

    private var world: simd_float4x4 { document.bindWorlds[bone] }

    private var parentBinding: Binding<Int> {
        return Binding<Int>(get: { document.bones[bone].parent ?? -1 },
                            set: { (parent: Int) in workspace.reparentBone(bone, to: parent < 0 ? nil : parent) })
    }

    private var parentCandidates: [Int] {
        let below: Set<Int> = document.subtree(of: bone)
        return document.bones.indices.filter { (index: Int) -> Bool in !below.contains(index) }
    }

    private var jointText: String {
        let x: Float = world.columns.3.x
        let y: Float = world.columns.3.y
        return String(format: "%.1f, %.1f", x, y)
    }

    private var angleBinding: Binding<Double> {
        let degrees: Double = Double(PuppetMath.angle(of: world)) * 180 / Double.pi
        return Binding<Double>(get: { degrees }, set: { (newDegrees: Double) in
            let radians: Float = Float(newDegrees * Double.pi / 180)
            workspace.edit(PL("Rotate Bone"), coalescing: true) { $0.rotateBone(bone, toAngle: radians) }
        })
    }

    var body: some View {
        Section(PL("Selected Bone")) {
            TextField(PL("Name"), text: $name)
                .onSubmit { workspace.renameBone(bone, to: name) }
                .onAppear { name = document.bones[bone].name }
                .onChange(of: bone) { _, new in name = workspace.document?.bones[new].name ?? "" }
            Picker(PL("Parent"), selection: parentBinding) {
                Text(PL("None")).tag(-1)
                ForEach(parentCandidates, id: \.self) { (index: Int) in
                    Text(document.bones[index].name).tag(index)
                }
            }
            LabeledContent(PL("Joint")) {
                Text(verbatim: jointText).monospacedDigit()
            }
            LabeledContent(PL("Angle")) {
                NumericSliderInput<Double>(value: angleBinding, range: -180...180, defaultValue: 0, step: 1, suffix: "°",
                                           fractionDigits: 1, fieldWidth: 56)
            }
            Button(PL("Delete Bone"), role: .destructive) { workspace.deleteSelectedBone() }
                .disabled(document.bones.count < 2)
        }
    }
}

// MARK: - Weights

private struct PuppetWeightsPanel: View {
    @ObservedObject var workspace: PuppetWorkspace

    var body: some View {
        Section(PL("Automatic Weights")) {
            Picker(PL("Method"), selection: $workspace.weightMethod) {
                Text(PL("Heat Diffusion")).tag(PuppetAutoWeights.Method.heat)
                Text(PL("Distance")).tag(PuppetAutoWeights.Method.distance)
            }
            .help(PL("Heat diffusion follows the image's shape; distance only looks at how near each bone is."))
            Button(PL("Weight All Vertices")) { workspace.autoWeights() }
        }
        Section(PL("Brush")) {
            Picker(PL("Mode"), selection: $workspace.brush.mode) {
                Text(PL("Add")).tag(PuppetWeightBrush.Mode.add)
                Text(PL("Subtract")).tag(PuppetWeightBrush.Mode.subtract)
                Text(PL("Smooth")).tag(PuppetWeightBrush.Mode.smooth)
                Text(PL("Replace")).tag(PuppetWeightBrush.Mode.replace)
            }
            LabeledContent(PL("Size")) {
                NumericSliderInput(value: $workspace.brush.radius, range: 2...400, defaultValue: 40, step: 1, suffix: " px",
                                   fractionDigits: 0, fieldWidth: 52)
            }
            LabeledContent(PL("Strength")) {
                NumericSliderInput(value: $workspace.brush.strength, range: 0.01...1, defaultValue: 0.25, displayScale: 100,
                                   suffix: "%", fractionDigits: 0, fieldWidth: 52)
            }
            Toggle(PL("Show Heat Map"), isOn: Binding(get: { workspace.showsHeatMap },
                                                       set: { workspace.showsHeatMap = $0; workspace.refreshPose() }))
        }
        Section(PL("Paint Bone")) {
            if workspace.selectedBone == nil {
                Text(PL("Pick a bone to paint its weights.")).foregroundStyle(.secondary)
            }
            PuppetBoneList(workspace: workspace)
        }
    }
}

// MARK: - Animation

private struct PuppetAnimationPanel: View {
    @ObservedObject var workspace: PuppetWorkspace
    @State private var name = ""

    var body: some View {
        if let clip = workspace.clip, let clipIndex = workspace.clipIndex, let document = workspace.document {
            Section(PL("Animation")) {
                TextField(PL("Name"), text: $name)
                    .onSubmit {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        workspace.updateClip(PL("Rename Animation"), coalescing: false) { $0.name = trimmed }
                    }
                    .onAppear { name = clip.name }
                    .onChange(of: clipIndex) { _, _ in name = workspace.clip?.name ?? "" }
                LabeledContent(PL("Frame Rate")) {
                    NumericSliderInput<Float>(value: Binding<Float>(get: { clip.fps }, set: { fps in
                        workspace.updateClip(PL("Change Frame Rate")) { $0.fps = max(fps, 1) }
                    }), range: 1...120, defaultValue: 30, step: 1, suffix: " fps", fractionDigits: 0, fieldWidth: 52)
                }
                LabeledContent(PL("Length")) {
                    NumericSliderInput<Double>(value: Binding<Double>(get: { Double(clip.frames) }, set: { frames in
                        workspace.updateClip(PL("Change Length")) { $0.setFrames(Int(frames.rounded())) }
                    }), range: 1...1000, defaultValue: 60, step: 1, fractionDigits: 0, fieldWidth: 52, clampsTypedValue: false)
                }
                Picker(PL("Playback"), selection: Binding(get: { clip.mode }, set: { mode in
                    workspace.updateClip(PL("Change Playback"), coalescing: false) { $0.mode = mode; $0.modeName = nil }
                })) {
                    Text(PL("Loop")).tag(PuppetClip.Mode.loop)
                    Text(PL("Mirror")).tag(PuppetClip.Mode.mirror)
                    Text(PL("Play Once")).tag(PuppetClip.Mode.single)
                }
                Button(PL("Delete Animation"), role: .destructive) { workspace.deleteClip() }
            }
            rootMotion(clip, clipIndex: clipIndex, document: document)
            if let bone = workspace.selectedBone, document.bones.indices.contains(bone) {
                PuppetBlendRulesSection(workspace: workspace, document: document, bone: bone, keysWeights: true)
            }
        } else {
            Section(PL("Animation")) {
                Text(PL("No animation yet.")).foregroundStyle(.secondary)
                Button(PL("New Animation")) { workspace.addClip() }
            }
        }
        layers
    }

    private func set(_ change: @escaping (inout PuppetClip.RootMotion) -> Void) {
        workspace.updateClip(PL("Change Root Motion"), coalescing: false) { clip in
            var motion = clip.rootMotion ?? PuppetClip.RootMotion()
            change(&motion)
            clip.rootMotion = motion.flags == PuppetClip.RootMotion().flags && motion.sourceClip == nil
                && motion.rootBone == nil ? nil : motion
        }
    }

    @ViewBuilder
    private func rootMotion(_ clip: PuppetClip, clipIndex: Int, document: PuppetDocument) -> some View {
        let motion = clip.rootMotion ?? PuppetClip.RootMotion()
        Section {
            Picker(PL("Motion Root"), selection: Binding(get: { motion.rootBone ?? -1 }, set: { bone in set { $0.rootBone = bone < 0 ? nil : bone } })) {
                Text(PL("None")).tag(-1)
                ForEach(document.bones.indices, id: \.self) { Text(document.bones[$0].name).tag($0) }
            }
            Toggle(PL("Position X"), isOn: Binding(get: { motion.positionX }, set: { on in set { $0.positionX = on } }))
            Toggle(PL("Position Y"), isOn: Binding(get: { motion.positionY }, set: { on in set { $0.positionY = on } }))
            Toggle(PL("Position Z"), isOn: Binding(get: { motion.positionZ }, set: { on in set { $0.positionZ = on } }))
            Toggle(PL("Rotation Y"), isOn: Binding(get: { motion.rotationY }, set: { on in set { $0.rotationY = on } }))
            Toggle(PL("Match Loop"), isOn: Binding(get: { motion.matchLoop }, set: { on in set { $0.matchLoop = on } }))
            Picker(PL("Cut From"), selection: Binding(get: { motion.sourceClip ?? -1 }, set: { source in
                set {
                    $0.sourceClip = source < 0 ? nil : source
                    if source >= 0, $0.endFrame == 0 { $0.endFrame = clip.frames }
                }
            })) {
                Text(PL("None")).tag(-1)
                ForEach(0..<clipIndex, id: \.self) { Text(document.clips[$0].name).tag($0) }
            }
            if motion.sourceClip != nil {
                LabeledContent(PL("Start Frame")) {
                    Stepper(value: Binding(get: { motion.startFrame }, set: { value in set { $0.startFrame = max(value, 0) } }), in: 0...100_000) {
                        Text(verbatim: String(motion.startFrame)).monospacedDigit()
                    }
                }
                LabeledContent(PL("End Frame")) {
                    Stepper(value: Binding(get: { motion.endFrame }, set: { value in set { $0.endFrame = max(value, 0) } }), in: 0...100_000) {
                        Text(verbatim: String(motion.endFrame)).monospacedDigit()
                    }
                }
                LabeledContent(PL("Frame Offset")) {
                    Stepper(value: Binding(get: { motion.frameOffset }, set: { value in set { $0.frameOffset = max(value, 0) } }), in: 0...100_000) {
                        Text(verbatim: String(motion.frameOffset)).monospacedDigit()
                    }
                }
            }
        } header: {
            Text(PL("Root Motion"))
        } footer: {
            Text(PL("Kept in the clip as Wallpaper Engine's model editor writes it. Wallpaper Engine moves models by it, not puppets."))
        }
    }

    @ViewBuilder private var layers: some View {
        Section {
            if let document = workspace.document {
                ForEach(Array(document.layers.enumerated()), id: \.offset) { index, layer in
                    PuppetLayerRow(workspace: workspace, index: index, layer: layer, clips: document.clips,
                                   isLast: index == document.layers.count - 1)
                }
                Button(PL("Add Layer")) { workspace.addLayer() }
                    .disabled(workspace.clip == nil)
            }
        } header: {
            Text(PL("Animation Layers"))
        } footer: {
            Text(PL("What the wallpaper plays, top to bottom: a blend of 1 replaces the pose below, less mixes it, additive layers add their change."))
        }
    }
}

private struct PuppetLayerRow: View {
    @ObservedObject var workspace: PuppetWorkspace
    let index: Int
    let layer: PuppetAnimationLayer
    let clips: [PuppetClip]
    let isLast: Bool

    var body: some View {
        DisclosureGroup {
            Picker(PL("Animation"), selection: Binding(get: { layer.clipID }, set: { id in
                workspace.updateLayer(index, PL("Change Layer Animation"), coalescing: false) { $0.clipID = id }
            })) {
                ForEach(clips, id: \.id) { Text($0.name).tag($0.id) }
            }
            LabeledContent(PL("Blend")) {
                NumericSliderInput<Float>(value: Binding<Float>(get: { layer.blend }, set: { value in
                    workspace.updateLayer(index, PL("Change Layer Blend")) { $0.blend = value }
                }), range: 0...1, defaultValue: 1, displayScale: 100, suffix: "%", fractionDigits: 0, fieldWidth: 48,
                    clampsTypedValue: false)
            }
            LabeledContent(PL("Rate")) {
                NumericSliderInput<Float>(value: Binding<Float>(get: { layer.rate }, set: { value in
                    workspace.updateLayer(index, PL("Change Layer Rate")) { $0.rate = value }
                }), range: -4...4, defaultValue: 1, step: 0.05, suffix: "×", fractionDigits: 2, fieldWidth: 48, clampsTypedValue: false)
            }
            Toggle(PL("Additive"), isOn: Binding(get: { layer.additive }, set: { on in
                workspace.updateLayer(index, PL("Change Layer Blending"), coalescing: false) { $0.additive = on }
            }))
            Toggle(PL("Blend In"), isOn: Binding(get: { layer.blendIn }, set: { on in
                workspace.updateLayer(index, PL("Change Layer Blending"), coalescing: false) { $0.blendIn = on }
            }))
            Toggle(PL("Blend Out"), isOn: Binding(get: { layer.blendOut }, set: { on in
                workspace.updateLayer(index, PL("Change Layer Blending"), coalescing: false) { $0.blendOut = on }
            }))
            .help(PL("Only for animations that play once, as in Wallpaper Engine."))
            LabeledContent(PL("Blend Time")) {
                NumericSliderInput<Float>(value: Binding<Float>(get: { layer.blendTime }, set: { value in
                    workspace.updateLayer(index, PL("Change Layer Blending")) { $0.blendTime = max(value, 0) }
                }), range: 0...5, defaultValue: 0.5, step: 0.05, suffix: " s", fractionDigits: 2, fieldWidth: 48)
            }
            HStack {
                Button { workspace.moveLayer(index, by: -1) } label: { Label(PL("Move Up"), systemImage: "arrow.up") }
                    .disabled(index == 0)
                Button { workspace.moveLayer(index, by: 1) } label: { Label(PL("Move Down"), systemImage: "arrow.down") }
                    .disabled(isLast)
                Spacer()
                Button(role: .destructive) { workspace.deleteLayer(index) } label: { Label(PL("Remove"), systemImage: "trash") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } label: {
            HStack {
                Toggle(isOn: Binding(get: { layer.visible }, set: { on in
                    workspace.updateLayer(index, on ? PL("Show Layer") : PL("Hide Layer"), coalescing: false) { $0.visible = on }
                })) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
                Text(clips.first { $0.id == layer.clipID }?.name ?? PL("Missing Animation"))
                if layer.additive { Text(PL("Additive")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Physics

private struct PuppetPhysicsPanel: View {
    @ObservedObject var workspace: PuppetWorkspace

    var body: some View {
        Section(PL("Preview")) {
            Toggle(PL("Simulate"), isOn: $workspace.simulatesPhysics)
            HStack {
                Button(PL("Shake")) { workspace.impulse() }
                    .disabled(workspace.selectedBone == nil)
                    .help(PL("Push the selected bone, as a script's bone impulse does"))
                Button(PL("Reset")) { workspace.resetPhysics() }
            }
        }
        if let document = workspace.document, let bone = workspace.selectedBone, document.bones.indices.contains(bone) {
            if let ik = document.bones[bone].ik {
                modeSection(physics: nil, ik: ik, bone: bone)
                PuppetKinematicChainSections(workspace: workspace, ik: ik, bone: bone)
            } else {
                settings(document.bones[bone].physics, bone: bone)
            }
        } else {
            Section {
                Text(PL("Pick a bone to give it physics.")).foregroundStyle(.secondary)
            }
        }
        Section(PL("Bones")) { PuppetBoneList(workspace: workspace) }
    }

    private func update(_ bone: Int, _ actionName: String = PL("Change Bone Physics"), coalescing: Bool = true,
                        _ change: @escaping (inout PuppetBonePhysics) -> Void) {
        workspace.updatePhysics(of: bone, actionName, coalescing: coalescing) { physics in
            guard var value = physics else { return }
            change(&value)
            physics = value
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<PuppetBonePhysics, Float>, _ range: ClosedRange<Float>,
                        _ fallback: Float, bone: Int, physics: PuppetBonePhysics?, suffix: String = "") -> some View {
        LabeledContent(title) {
            NumericSliderInput<Float>(value: Binding<Float>(get: { physics?[keyPath: key] ?? fallback }, set: { value in
                update(bone) { $0[keyPath: key] = value }
            }), range: range, defaultValue: fallback, step: 1, suffix: suffix, fractionDigits: 0, fieldWidth: 52,
                clampsTypedValue: false)
        }
    }

    @ViewBuilder
    private func settings(_ physics: PuppetBonePhysics?, bone: Int) -> some View {
        modeSection(physics: physics, ik: nil, bone: bone)
        headerSection(physics, bone: bone)
        if let physics {
            rotationSection(physics, bone: bone)
            positionSection(physics, bone: bone)
            gravitySection(physics, bone: bone)
            tipSection(physics, bone: bone)
        }
    }

    /// A checkbox for one of the physics' switches.
    private func toggle(_ title: String, _ key: WritableKeyPath<PuppetBonePhysics, Bool>, bone: Int,
                        physics: PuppetBonePhysics) -> some View {
        let isOn = Binding<Bool>(get: { physics[keyPath: key] },
                                 set: { (on: Bool) in update(bone, coalescing: false) { $0[keyPath: key] = on } })
        return Toggle(title, isOn: isOn)
    }

    /// A slider in degrees over a value the physics keeps in radians (or as a direction).
    private func degreesSlider(_ title: String, range: ClosedRange<Float>, defaultValue: Float, bone: Int,
                               radians: @escaping () -> Float,
                               set: @escaping (inout PuppetBonePhysics, Float) -> Void) -> some View {
        let value = Binding<Float>(get: { radians() * 180 / Float.pi }, set: { (degrees: Float) in
            let newRadians: Float = degrees * Float.pi / 180
            update(bone) { set(&$0, newRadians) }
        })
        return LabeledContent(title) {
            NumericSliderInput<Float>(value: value, range: range, defaultValue: defaultValue, step: 1, suffix: "°",
                                      fractionDigits: 0, fieldWidth: 48)
        }
    }

    /// WE's Simulation mode: Not simulated, Spring physics, Rigid physics or Kinematic chain.
    private enum Mode: Hashable { case none, spring, rigid, chain }

    private func modeSection(physics: PuppetBonePhysics?, ik: PuppetBoneIK?, bone: Int) -> some View {
        let mode = Binding<Mode>(get: {
            ik != nil ? .chain : physics.map { $0.kind == .rigid ? Mode.rigid : .spring } ?? .none
        }, set: { (mode: Mode) in
            workspace.edit(mode == .none ? PL("Remove Bone Physics") : mode == .chain ? PL("Add Kinematic Chain")
                           : PL("Add Bone Physics")) { document in
                guard document.bones.indices.contains(bone) else { return }
                switch mode {
                case .none:
                    document.bones[bone].physics = nil
                    document.bones[bone].ik = nil
                case .spring, .rigid:
                    var value = document.bones[bone].physics ?? PuppetBonePhysics()
                    value.kind = mode == .rigid ? .rigid : .spring
                    document.bones[bone].physics = value
                    document.bones[bone].ik = nil
                case .chain:
                    document.bones[bone].ik = document.bones[bone].ik ?? PuppetBoneIK()
                    document.bones[bone].physics = nil
                }
            }
        })
        return Section {
            Picker(PL("Simulation mode"), selection: mode) {
                Text(PL("Not simulated")).tag(Mode.none)
                Text(PL("Spring physics")).tag(Mode.spring)
                Text(PL("Rigid physics")).tag(Mode.rigid)
                Text(PL("Kinematic chain")).tag(Mode.chain)
            }
        } header: {
            Text(workspace.document?.bones[bone].name ?? "")
        }
    }

    @ViewBuilder
    private func headerSection(_ physics: PuppetBonePhysics?, bone: Int) -> some View {
        if physics != nil {
            Section {
                Menu(PL("Preset")) {
                    ForEach(PuppetBonePhysics.Preset.allCases, id: \.self) { (preset: PuppetBonePhysics.Preset) in
                        Button(preset.title) {
                            workspace.updatePhysics(of: bone, PL("Apply Physics Preset"), coalescing: false) { $0 = PuppetBonePhysics(preset: preset) }
                        }
                    }
                }
            }
        }
    }

    private func rotationSection(_ physics: PuppetBonePhysics, bone: Int) -> some View {
        Section(PL("Rotation")) {
            toggle(PL("Simulate Rotation"), \.rotation, bone: bone, physics: physics)
            if physics.rotation {
                slider(PL("Stiffness"), \.rotationStiffness, 0...1000, 200, bone: bone, physics: physics)
                slider(PL("Friction"), \.rotationFriction, 0...100, 20, bone: bone, physics: physics)
                slider(PL("Inertia"), \.rotationInertia, 0...100, 30, bone: bone, physics: physics, suffix: "%")
                toggle(PL("Limit Angle"), \.limitAngles, bone: bone, physics: physics)
                if physics.limitAngles {
                    degreesSlider(PL("Minimum"), range: -180...0, defaultValue: -180, bone: bone,
                                  radians: { physics.minAngles.z }, set: { $0.minAngles.z = $1 })
                    degreesSlider(PL("Maximum"), range: 0...180, defaultValue: 180, bone: bone,
                                  radians: { physics.maxAngles.z }, set: { $0.maxAngles.z = $1 })
                }
                toggle(PL("Limit Torque"), \.limitTorque, bone: bone, physics: physics)
                if physics.limitTorque {
                    slider(PL("Maximum Torque"), \.maxTorque, 0...360, 100, bone: bone, physics: physics, suffix: "°")
                }
            }
        }
    }

    private func positionSection(_ physics: PuppetBonePhysics, bone: Int) -> some View {
        Section(PL("Position")) {
            toggle(PL("Simulate Position"), \.translation, bone: bone, physics: physics)
            if physics.translation {
                slider(PL("Stiffness"), \.translationStiffness, 0...1000, 200, bone: bone, physics: physics)
                slider(PL("Friction"), \.translationFriction, 0...100, 20, bone: bone, physics: physics)
                slider(PL("Inertia"), \.translationInertia, 0...100, 30, bone: bone, physics: physics, suffix: "%")
                slider(PL("Maximum Distance"), \.maxDistance, 0...1000, 200, bone: bone, physics: physics, suffix: " px")
            }
        }
    }

    private func gravitySection(_ physics: PuppetBonePhysics, bone: Int) -> some View {
        Section(PL("Gravity")) {
            toggle(PL("Gravity"), \.gravity, bone: bone, physics: physics)
            if physics.gravity {
                degreesSlider(PL("Direction"), range: -180...180, defaultValue: -90, bone: bone,
                              radians: { atan2(physics.gravityDirection.y, physics.gravityDirection.x) },
                              set: { (value: inout PuppetBonePhysics, radians: Float) in
                                  value.gravityDirection = SIMD3<Float>(cos(radians), sin(radians), 0)
                              })
                slider(PL("Mass"), \.mass, 0...1000, 20, bone: bone, physics: physics)
            }
        }
    }

    private func tipSection(_ physics: PuppetBonePhysics, bone: Int) -> some View {
        let tipSize = Binding<Float>(get: { physics.tipSize }, set: { (value: Float) in
            update(bone) { $0.tipSize = max(value, 0); $0.compiledTip = nil }
        })
        return Section(PL("Tip")) {
            LabeledContent(PL("Tip Size")) {
                NumericSliderInput<Float>(value: tipSize, range: 0...500, defaultValue: 0, step: 1, suffix: " px",
                                          fractionDigits: 0, fieldWidth: 52)
            }
            .help(PL("0 reaches the bone's first child."))
            degreesSlider(PL("Direction"), range: -180...180, defaultValue: 0, bone: bone,
                          radians: { atan2(physics.forward.y, physics.forward.x) },
                          set: { (value: inout PuppetBonePhysics, radians: Float) in
                              value.forward = SIMD3<Float>(cos(radians), sin(radians), 0)
                              value.compiledTip = nil
                          })
        }
    }
}

extension PuppetBonePhysics.Preset {
    var title: String {
        switch self {
        case .springy: return PL("Springy")
        case .stiff: return PL("Stiff")
        case .floppy: return PL("Floppy")
        case .bouncyPosition: return PL("Bouncy Position")
        }
    }
}
