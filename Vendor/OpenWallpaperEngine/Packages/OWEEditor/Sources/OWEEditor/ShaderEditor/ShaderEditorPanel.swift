import AppKit
import SwiftUI
import OWESceneEditing

/// The shader editor, docked under the canvas as the script editor is: WE's "Shader - {{name}}"
/// pane with Apply (✓), Snippets, View Errors (once the translator found a problem), OK and
/// Cancel, the code with WE's dialect highlighted and completed, and the problems below.
struct ShaderEditorPanel: View {
    @ObservedObject var model: ShaderEditorModel
    let document: ShaderDocument
    @State private var isShowingErrors = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CodeEditorView(text: Binding(get: { model.document?.text ?? "" }, set: { model.setText($0) }),
                           diagnostics: model.diagnostics, catalog: .standard, language: .shader,
                           onCommit: model.apply)
                .frame(minWidth: 320, minHeight: 120)
                .id(document.path)
            Divider()
            problems
                .frame(minHeight: 60, idealHeight: 90, maxHeight: 160)
        }
        .background(.background)
        .sheet(isPresented: $isShowingErrors) {
            if let result = model.result {
                ShaderErrorsView(title: document.title, result: result)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "function")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Shader - \(document.title)")).font(.headline).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            snippetsMenu
            if model.result?.isSuccess == false, model.result?.translatedSource != nil || model.result?.log.isEmpty == false {
                Button(role: .destructive) {
                    isShowingErrors = true
                } label: {
                    Text(L("View Errors"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help(L("Show the translated shader and the translator’s errors"))
            }
            Button(action: model.apply) {
                Label(L("Apply"), systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!document.isDirty)
            .help(L("Rebuild the shader and show it on the canvas (⌘↩)"))
            Button(L("OK")) {
                model.apply()
                model.close()
            }
            .buttonStyle(.borderedProminent)
            Button(L("Cancel")) {
                model.revert()
                model.close()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        if let notice = model.notice { return notice }
        if model.isChecking { return L("Rebuilding shaders") }
        if document.isDirty { return L("Edited — not applied") }
        if model.result?.isSuccess == false { return L("\(document.fileName) doesn’t translate") }
        return document.fileName
    }

    // MARK: Snippets

    private var snippetsMenu: some View {
        Menu {
            Menu(L("Replace Shader")) {
                ForEach(ShaderSnippets.Replacement.allCases) { replacement in
                    let text = model.snippet(replacement)
                    Button(title(replacement)) {
                        if let text { model.edit { _ in text } }
                    }
                    .disabled(text == nil)
                    if replacement == .maskedVertex { Divider() }
                }
            }
            Menu(L("Add Include")) {
                ForEach(ShaderSnippets.includes, id: \.self) { name in
                    Button(name) { model.edit { ShaderSnippets.addingInclude(name, to: $0) } }
                }
            }
            Menu(L("Add Constant")) {
                constantMenu(.general)
                constantMenu(.view)
                Menu(L("Texture Sampler")) {
                    ForEach(ShaderSnippets.samplers) { sampler in
                        Button(title(sampler.id)) { model.edit { try ShaderSnippets.addingSampler(sampler, to: $0) } }
                    }
                }
                constantMenu(.textureInfo)
                constantMenu(.audio)
            }
            Menu(L("Add Variable")) {
                ForEach(ShaderSnippets.Variable.allCases) { variable in
                    if variable == .comboCheckbox { Divider() }
                    Button(title(variable)) {
                        model.edit { text in
                            if let uniform = variable.uniform { return ShaderSnippets.addingUniform(uniform, to: text) }
                            return ShaderSnippets.addingCombo(variable.combo ?? "", to: text)
                        }
                    }
                }
            }
        } label: {
            Text(L("Snippets"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private func constantMenu(_ id: ShaderSnippets.ConstantGroup.ID) -> some View {
        if let group = ShaderSnippets.constantGroups.first(where: { $0.id == id }) {
            Menu(title(id)) {
                ForEach(group.constants) { uniform in
                    Button(uniform.name) { model.edit { ShaderSnippets.addingUniform(uniform, to: $0) } }
                    // WE's View menu: the vectors, the model matrices, then the effect's.
                    if uniform.name == "g_OrientationUp" || uniform.name == "g_NormalModelMatrix" { Divider() }
                }
            }
        }
    }

    // MARK: Problems

    @ViewBuilder private var problems: some View {
        let diagnostics = model.result?.diagnostics ?? []
        if diagnostics.isEmpty {
            Text(model.isChecking ? L("Rebuilding shaders") : L("No problems"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(diagnostics) { diagnostic in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(diagnostic.stage == .vertex ? L("Vertex") : L("Fragment")).foregroundStyle(.secondary)
                    if let number = diagnostic.line {
                        Text(L("Line \(number)")).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(diagnostic.message).textSelection(.enabled)
                }
                .font(.callout)
            }
            .listStyle(.plain)
        }
    }

    // MARK: Titles (WE's `ui_editor_shader_*`)

    private func title(_ replacement: ShaderSnippets.Replacement) -> String {
        switch replacement {
        case .basicVertex: return L("Basic Effect Vertex Shader")
        case .maskedVertex: return L("Masked Effect Vertex Shader")
        case .basicFragment: return L("Basic Effect Fragment Shader")
        case .maskedFragment: return L("Masked Effect Fragment Shader")
        }
    }

    private func title(_ group: ShaderSnippets.ConstantGroup.ID) -> String {
        switch group {
        case .general: return L("General")
        case .view: return L("View")
        case .textureSampler: return L("Texture Sampler")
        case .textureInfo: return L("Texture Info")
        case .audio: return L("Audio")
        }
    }

    private func title(_ sampler: ShaderSnippets.Sampler.ID) -> String {
        switch sampler {
        case .basic: return L("Normal Texture")
        case .single: return L("Mask, Single Channel (red)")
        case .direction: return L("Flow Direction (red, green)")
        case .uniformNoise: return L("Uniform Noise (red, green, blue, alpha)")
        case .perlinNoise: return L("Perlin Noise (red, green, blue, alpha)")
        }
    }

    private func title(_ variable: ShaderSnippets.Variable) -> String {
        switch variable {
        case .sliderFloat: return L("Slider Float")
        case .sliderInt: return L("Slider Int")
        case .linkedSliders: return L("Linked Sliders")
        case .colorPicker: return L("Color Picker")
        case .uvPicker: return L("UV Position Picker")
        case .knob: return L("Knob")
        case .comboCheckbox: return L("Combo - Checkbox")
        case .combo2Options: return L("Combo - 2 Options")
        case .combo3Options: return L("Combo - 3 Options")
        }
    }
}

/// View Errors: the source the translator's failing step compiled, its lines numbered and the
/// first problem's line marked, with the translator's whole output above (WE's "HLSL - {{name}}"
/// pane, which shows the translated source and reveals the error's line).
struct ShaderErrorsView: View {
    let title: String
    let result: ShaderCheckResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Translated Shader - \(title)")).font(.headline)
                Spacer()
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Text(result.log)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            if let source = result.translatedSource {
                let lines = source.components(separatedBy: "\n")
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1)")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                    Text(line.isEmpty ? " " : line)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .background(index + 1 == result.translatedLine ? Color.red.opacity(0.2) : Color.clear)
                                .id(index + 1)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(8)
                    }
                    .onAppear {
                        if let line = result.translatedLine { proxy.scrollTo(line, anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 620)
    }
}
