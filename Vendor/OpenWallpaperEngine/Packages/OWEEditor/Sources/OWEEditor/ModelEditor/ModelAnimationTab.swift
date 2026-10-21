import OWEModelImport
import OWESceneEditing
import SwiftUI
import UniformTypeIdentifiers

/// The Animation tab: the source's animations (Add Clip), the extra animation files (Add FBX
/// File) and the clips with their options: name, start and end frame, frame offset, frame rate,
/// how it plays past its end, Match loop and root motion (WE's clip options).
struct ModelAnimationTab: View {
    @ObservedObject var editor: ModelEditorModel
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    @State private var animation: UInt64?
    @State private var clip: UInt64?
    @State private var file: String?
    @State private var isAddingFile = false

    struct FileItem: Identifiable { var id: String }

    var body: some View {
        ModelEditorColumns {
            ModelEditorList(title: ML("Animations"), items: editor.animations, selection: $animation) { item in
                VStack(alignment: .leading) {
                    Text(item.listTitle)
                    Text(Self.framesText(item)).font(.caption).foregroundStyle(.secondary)
                }
            } buttons: {
                Button(ML("Add Clip")) { animation.map { clip = editor.addClip(from: $0) } }
                    .disabled(animation == nil)
                Spacer()
                playButton(animation)
            }
            ModelEditorList(title: ML("FBX files"), items: editor.config.additionalFiles.map(FileItem.init), selection: $file) { item in
                Text(item.id)
            } buttons: {
                Button(ML("Add FBX File…")) { isAddingFile = true }
                Button { file.map(editor.removeAnimationFile); file = nil } label: { Image(systemName: "minus") }
                    .disabled(file == nil)
            }
            .frame(maxHeight: 160)
        } right: {
            Section(ML("Clips")) {
                if editor.clips.isEmpty {
                    Text(ML("Pick an animation and Add Clip to cut a part of it.")).foregroundStyle(.secondary)
                }
                ForEach(editor.clips) { item in
                    HStack {
                        Button(item.listTitle) { clip = item.id }.buttonStyle(.plain)
                            .fontWeight(clip == item.id ? .semibold : .regular)
                        Spacer()
                        playButton(item.id)
                        Button { editor.removeClip(item.id); if clip == item.id { clip = nil } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(ML("Remove Clip"))
                    }
                }
            }
            if let id = clip, let options = editor.config.clips.first(where: { $0.id == id }) {
                clipOptions(options)
            }
        }
        .fileImporter(isPresented: $isAddingFile, allowedContentTypes: [UTType(filenameExtension: "fbx") ?? .data, UTType(filenameExtension: "obj") ?? .data]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                editor.addAnimationFile(url)
            }
        }
    }

    static func framesText(_ item: ModelCompiler.AnimationInfo) -> String {
        let fps = Int(item.fps.rounded())
        return ML("\(item.frames) frames at \(fps) fps")
    }

    /// Plays the animation on the layer being edited (its only animation layer, as WE's
    /// Skeletal animation › Add makes one); playing it again stops it. It plays the model as
    /// last compiled: OK first for a new clip.
    @ViewBuilder private func playButton(_ id: UInt64?) -> some View {
        let playing = id.map { ModelAnimationLayers.plays($0, layer: layer.id, in: session) } ?? false
        Button {
            guard let id else { return }
            ModelAnimationLayers.play(playing ? nil : id, name: editor.animation(id)?.listTitle ?? "", layer: layer.id, in: session)
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(id == nil)
        .help(playing ? ML("Stop on the Layer") : ML("Play on the Layer"))
    }

    @ViewBuilder private func clipOptions(_ options: ModelImportConfig.Clip) -> some View {
        let id = options.id
        let frames = editor.animation(options.animation)?.frames ?? 0
        Section(ML("Clip options")) {
            TextField(ML("Name"), text: Binding(get: { options.name }, set: { name in editor.updateClip(id) { $0.name = name } }))
            LabeledContent(ML("Animation"), value: editor.animation(options.animation)?.listTitle ?? "")
            ModelFrameField(title: ML("Start frame"), value: Binding(get: { options.start }, set: { value in
                editor.updateClip(id) { $0.start = min(max(value, 0), frames) }
            }))
            ModelFrameField(title: ML("End frame"), value: Binding(get: { options.end }, set: { value in
                editor.updateClip(id) { $0.end = min(max(value, 0), frames) }
            }))
            ModelFrameField(title: ML("Frame offset"), value: Binding(get: { options.frameOffset }, set: { value in
                editor.updateClip(id) { $0.frameOffset = max(value, 0) }
            }))
            LabeledContent(ML("Frame rate")) {
                TextField(ML("Frame rate"), value: Binding(get: { Double(options.fps ?? editor.animation(options.animation)?.fps ?? 30) },
                                                           set: { value in editor.updateClip(id) { $0.fps = Float(max(value, 0.1)) } }),
                          format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden().frame(width: 80)
            }
            // WE's clips have no mode (""), which plays as a loop.
            Picker(ML("Playback"), selection: Binding(get: { options.mode.isEmpty ? "loop" : options.mode },
                                                      set: { mode in editor.updateClip(id) { $0.mode = mode == "loop" ? "" : mode } })) {
                Text(ML("Loop")).tag("loop")
                Text(ML("Mirror")).tag("mirror")
                Text(ML("Single")).tag("single")
            }
        }
        Section(ML("Root motion")) {
            Toggle(ML("Match loop"), isOn: Binding(get: { options.matchLoop }, set: { on in editor.updateClip(id) { $0.matchLoop = on } }))
            Picker(ML("Motion root bone"), selection: Binding(get: { options.rootMotion }, set: { bone in
                editor.updateClip(id) { $0.rootMotion = bone }
            })) {
                Text(ML("None")).tag("")
                ForEach(editor.bones, id: \.self) { Text($0).tag($0) }
            }
            if !options.rootMotion.isEmpty {
                flag(ML("Position X"), ModelImportConfig.Clip.positionX, options)
                flag(ML("Position Y"), ModelImportConfig.Clip.positionY, options)
                flag(ML("Position Z"), ModelImportConfig.Clip.positionZ, options)
                flag(ML("Rotation Y"), ModelImportConfig.Clip.rotationY, options)
            }
        }
    }

    private func flag(_ title: String, _ bit: UInt32, _ options: ModelImportConfig.Clip) -> some View {
        Toggle(title, isOn: Binding(get: { options.motionFlags & bit != 0 }, set: { on in
            editor.updateClip(options.id) { $0.motionFlags = on ? $0.motionFlags | bit : $0.motionFlags & ~bit }
        }))
    }
}

/// A model layer's `animationlayers` as WE's Skeletal animation section writes one: an
/// animation layer playing a clip by its id at rate 1 and full blend.
enum ModelAnimationLayers {
    @MainActor
    static func plays(_ animation: UInt64, layer: Int, in session: SceneEditSession) -> Bool {
        guard case .array(let layers)? = session.value("animationlayers", of: layer) else { return false }
        return layers.contains { $0["animation"]?.doubleValue == Double(animation) }
    }

    /// Makes `animation` the layer's only animation layer; nil removes its animation layers.
    @MainActor
    static func play(_ animation: UInt64?, name: String, layer: Int, in session: SceneEditSession) {
        let value: SceneJSONValue? = animation.map { id in
            .array([.object([
                "additive": .bool(false), "animation": .number(Double(id)), "blend": .number(1), "blendin": .bool(false),
                "blendout": .bool(false), "blendtime": .number(0.5), "id": .number(Double(id)), "name": .string(name),
                "rate": .number(1), "visible": .bool(true),
            ])])
        }
        session.setValue(value ?? .array([]), for: "animationlayers", of: layer,
                         actionName: animation == nil ? ML("Stop Animation") : ML("Play Animation"))
    }
}
