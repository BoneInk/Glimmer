import SwiftUI
import OWESceneEditing
import WEFormat

/// An editable effect's Shaders in the inspector (WE's `ui_editor_properties_shaders` with an
/// Edit button beside each shader, `editablefile`): each material's vertex and fragment shader,
/// opened in the shader editor, and its Shader Options. Only for the wallpaper's own editable
/// effects (My Effects).
struct CustomEffectSection: View {
    @ObservedObject var session: SceneEditSession
    @EnvironmentObject private var shaders: ShaderEditorModel
    let layer: SceneLayer
    let effect: SceneLayerEffect

    var body: some View {
        if let effectInfo = CustomEffectInfo.read(effect.file, model: shaders) {
            Text(L("Shaders")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(effectInfo.materials, id: \.path) { material in
                if effectInfo.materials.count > 1 {
                    Text((material.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                ForEach([ShaderDiagnostic.Stage.vertex, .fragment], id: \.self) { stage in
                    LabeledContent(stage == .vertex ? L("Vertex Shader") : L("Fragment Shader")) {
                        HStack(spacing: 6) {
                            Text("\((material.shader as NSString).lastPathComponent).\(stage.rawValue)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button(L("Edit")) {
                                shaders.open(effectFile: effect.file, title: effectInfo.title, shader: material.shader, stage: stage,
                                             layerID: layer.id, effectKey: effect.key)
                            }
                        }
                    }
                }
                ShaderOptionsRows(session: session, model: shaders, materialPath: material.path)
            }
        }
    }
}

/// A material's Shader Options (WE's Blending, Culling, Depth test and Depth write), each change
/// written into the editor's copy of the material, one undo step.
struct ShaderOptionsRows: View {
    @ObservedObject var session: SceneEditSession
    let model: ShaderEditorModel
    let materialPath: String

    var body: some View {
        if let text = model.text(at: materialPath), let options = MaterialShaderOptions(material: text) {
            Text(L("Shader Options")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Picker(L("Blending"), selection: binding(text, options, \.blending)) {
                ForEach(MaterialShaderOptions.Blending.allCases) { blending in
                    Text(Self.title(blending)).tag(blending)
                }
            }
            Picker(L("Culling"), selection: binding(text, options, \.culling)) {
                Text(L("No cull")).tag(MaterialShaderOptions.Culling.nocull)
                Text(L("Normal")).tag(MaterialShaderOptions.Culling.normal)
            }
            Toggle(L("Depth test"), isOn: binding(text, options, \.depthTest))
                .toggleStyle(.checkbox)
            Toggle(L("Depth write"), isOn: binding(text, options, \.depthWrite))
                .toggleStyle(.checkbox)
                .disabled(!options.depthWriteApplies)
        }
    }

    private func binding<Value>(_ text: String, _ options: MaterialShaderOptions,
                                _ keyPath: WritableKeyPath<MaterialShaderOptions, Value>) -> Binding<Value> {
        Binding(get: { options[keyPath: keyPath] }, set: { value in
            var changed = options
            changed[keyPath: keyPath] = value
            session.setMaterialOptions(changed, material: materialPath, text: text, actionName: L("Change Shader Option"))
        })
    }

    static func title(_ blending: MaterialShaderOptions.Blending) -> String {
        switch blending {
        case .normal: return L("Normal")
        case .translucent: return L("Translucent")
        case .additive: return L("Additive")
        case .alphatocoverage: return L("Alpha to coverage")
        }
    }
}

/// What the inspector shows of an editable effect: its title and each material with its shader.
struct CustomEffectInfo {
    struct Material {
        /// The editor's file of the material (`effects/<id>/materials/effects/<id>.json`).
        var path: String
        var shader: String
    }

    var title: String
    var materials: [Material]

    /// The effect at `file` when it is one the editor can edit: made in the editor, or the
    /// wallpaper's own with `editable` set (WE's `localeffects`).
    @MainActor
    static func read(_ file: String, model: ShaderEditorModel) -> CustomEffectInfo? {
        guard let text = model.text(at: file),
              let json = try? TolerantJSON.object(from: Data(text.utf8)) as? [String: Any] else { return nil }
        let madeHere = model.session.overlay.effectFile(file) != nil
        guard madeHere || json["editable"] as? Bool == true else { return nil }
        let directory = (file as NSString).deletingLastPathComponent
        var materials: [Material] = []
        for pass in json["passes"] as? [[String: Any]] ?? [] {
            guard let relative = pass["material"] as? String else { continue }
            let path = model.resolvedPath(relative, in: directory)
            guard !materials.contains(where: { $0.path == path }), let materialText = model.text(at: path),
                  let material = try? TolerantJSON.object(from: Data(materialText.utf8)) as? [String: Any],
                  let shader = (material["passes"] as? [[String: Any]])?.first?["shader"] as? String else { continue }
            materials.append(Material(path: path, shader: shader))
        }
        return CustomEffectInfo(title: json["name"] as? String ?? (directory as NSString).lastPathComponent, materials: materials)
    }
}
