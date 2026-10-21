import AppKit
import SwiftUI
import OWESceneEditing

/// The script editor, docked under the canvas: the script of one field with its templates, the
/// properties it declares, its problems and the scripts' console. Apply attaches the script
/// (undoable) and the wallpaper runs it from the reload that follows.
struct ScriptEditorPanel: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let draft: ScriptDraft
    @State private var output = OutputTab.problems
    @State private var onlyThisScript = true

    enum OutputTab: Hashable { case problems, console }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                CodeEditorView(text: Binding(get: { authoring.draft?.text ?? "" }, set: { authoring.setDraftText($0) }),
                               diagnostics: authoring.diagnostics, catalog: authoring.catalog,
                               controller: authoring.codeEditor, onCommit: apply)
                    .frame(minWidth: 320, minHeight: 120)
                    .id(draft.target)
                let declarations = SceneScriptPropertyDeclaration.declarations(in: draft.text)
                if !declarations.isEmpty {
                    ScriptPropertiesForm(authoring: authoring, target: draft.target, declarations: declarations,
                                         isApplied: !draft.applied.isEmpty)
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                }
            }
            Divider()
            outputArea
                .frame(minHeight: 90, idealHeight: 130, maxHeight: 220)
        }
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(authoring.title(of: draft.target)).font(.headline).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if authoring.canStopScripts {
                Button {
                    authoring.setScriptsRunning(!authoring.scriptsRunning)
                } label: {
                    Label(authoring.scriptsRunning ? L("Stop Preview") : L("Run Preview"),
                          systemImage: authoring.scriptsRunning ? "stop.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help(authoring.scriptsRunning ? L("Stop the wallpaper’s scripts on the canvas")
                                               : L("Run the wallpaper’s scripts on the canvas again"))
            }
            ScriptSnippetsMenu(authoring: authoring)
            ScriptEditMenu(authoring: authoring)
            Menu {
                ForEach(SceneScriptTemplate.templates(for: draft.target.path.name)) { template in
                    Button(template.id.title) { authoring.useTemplate(template.id) }
                }
            } label: {
                Label(L("Templates"), systemImage: "doc.text")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Start from a template"))
            Button {
                authoring.setDraftText(draft.applied)
            } label: {
                Label(L("Discard Changes"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!draft.isDirty || draft.applied.isEmpty)
            .help(L("Go back to the script the wallpaper runs"))
            if !draft.applied.isEmpty {
                Button(role: .destructive) {
                    authoring.removeScript(draft.target)
                } label: {
                    Label(L("Remove Script"), systemImage: "trash")
                }
                .help(L("Remove the script; the field keeps its value"))
            }
            Button(action: apply) {
                Label(L("Apply"), systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .help(L("Run this script in the wallpaper (⌘↩)"))
            Button {
                authoring.closeScript()
            } label: {
                Label(L("Close"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(L("Close the script editor"))
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canApply: Bool { draft.syntax.isEmpty && (draft.isDirty || draft.applied.isEmpty) }

    private var status: String {
        if !draft.syntax.isEmpty { return L("Syntax error") }
        if draft.applied.isEmpty { return L("Not applied yet") }
        if draft.isDirty { return L("Edited — not applied") }
        return draft.appliedAt == nil ? L("Running") : L("Applied")
    }

    private func apply() {
        guard canApply else { return }
        authoring.applyScript()
    }

    // MARK: Output

    private var outputArea: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(selection: $output) {
                    Text(L("Problems")).tag(OutputTab.problems)
                    Text(L("Console")).tag(OutputTab.console)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if output == .console {
                    Toggle(L("This Script Only"), isOn: $onlyThisScript)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle(L("Clear Log on Run"), isOn: $authoring.clearsLogOnRun)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help(L("Empty the console when a script is applied or the preview runs"))
                    Toggle(L("Auto Scroll"), isOn: $authoring.autoScrollsLog)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help(L("Keep the newest line in view"))
                    Button {
                        authoring.console?.clear()
                    } label: {
                        Label(L("Clear"), systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(L("Clear the console"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch output {
            case .problems: problems
            case .console: ScriptConsoleView(entries: consoleEntries, isAvailable: authoring.console != nil,
                                             followsNewest: authoring.autoScrollsLog)
            }
        }
    }

    private var consoleEntries: [SceneScriptConsoleEntry] {
        guard let console = authoring.console else { return [] }
        return onlyThisScript ? console.entries(of: draft.target.layer, draft.target.path) : console.entries
    }

    @ViewBuilder private var problems: some View {
        let diagnostics = authoring.diagnostics
        if diagnostics.isEmpty {
            Text(L("No problems"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(diagnostics) { diagnostic in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
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
}

/// The scripts' console: what they logged and the errors they raised, newest last.
struct ScriptConsoleView: View {
    let entries: [SceneScriptConsoleEntry]
    let isAvailable: Bool
    /// Scroll to each new line (Auto Scroll).
    var followsNewest = true

    var body: some View {
        if !isAvailable || entries.isEmpty {
            Text(isAvailable ? L("Nothing logged yet. console.log and console.error write here.")
                             : L("The console isn’t available for this wallpaper."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: entry.level == .error ? "xmark.octagon.fill" : "text.bubble")
                            .foregroundStyle(entry.level == .error ? Color.red : Color.secondary)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let number = entry.line {
                            Text(L("Line \(number)")).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                .onChange(of: entries.last?.id) { _, last in
                    if followsNewest { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

/// The properties a script declares (`createScriptProperties()`), with their values for this
/// field, as WE's editor lists them under the script.
private struct ScriptPropertiesForm: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let target: FieldTarget
    let declarations: [SceneScriptPropertyDeclaration]
    let isApplied: Bool

    var body: some View {
        Form {
            Section {
                ForEach(declarations) { declaration in
                    row(declaration)
                }
            } header: {
                Text(L("Script Properties"))
            } footer: {
                if !isApplied {
                    Text(L("Apply the script to set its properties.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!isApplied)
    }

    private func value(_ declaration: SceneScriptPropertyDeclaration) -> SceneJSONValue? {
        let stored = authoring.session.drivers(target.path, of: target.layer).script?.scriptProperties?[declaration.name]
        // A user-bound entry (`{"user", "value"}`) shows its value.
        if case .object(let fields)? = stored { return fields["value"] ?? declaration.value }
        return stored ?? declaration.value
    }

    private func set(_ declaration: SceneScriptPropertyDeclaration, _ value: SceneJSONValue) {
        authoring.setScriptProperty(declaration.name, to: value == declaration.value ? nil : value, on: target)
    }

    @ViewBuilder private func row(_ declaration: SceneScriptPropertyDeclaration) -> some View {
        switch declaration.kind {
        case .checkbox:
            Toggle(declaration.label, isOn: Binding(
                get: { value(declaration)?.boolValue ?? false },
                set: { set(declaration, .bool($0)) }))
        case .slider:
            let lower = declaration.minimum ?? 0
            let upper = max(declaration.maximum ?? 1, lower + 0.0001)
            LabeledContent(declaration.label) {
                HStack {
                    Slider(value: Binding(
                        get: { min(max(value(declaration)?.doubleValue ?? lower, lower), upper) },
                        set: { set(declaration, .number(declaration.isInteger ? $0.rounded() : $0)) }),
                           in: lower...upper)
                    Text(SceneVector.string([value(declaration)?.doubleValue ?? lower]))
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        case .combo:
            Picker(declaration.label, selection: Binding(
                get: { value(declaration).map(UserPropertyDraft.text(of:)) ?? "" },
                set: { selected in
                    if let option = declaration.options.first(where: { UserPropertyDraft.text(of: $0.value) == selected }) {
                        set(declaration, option.value)
                    }
                })) {
                ForEach(declaration.options.indices, id: \.self) { index in
                    Text(declaration.options[index].label).tag(UserPropertyDraft.text(of: declaration.options[index].value))
                }
            }
        case .color:
            ColorPicker(declaration.label, selection: Binding(
                get: { PropertyColor.color(value(declaration).map(UserPropertyDraft.text(of:)) ?? "1 1 1") },
                set: { set(declaration, .string(PropertyColor.text($0))) }), supportsOpacity: false)
        case .text:
            TextField(declaration.label, text: Binding(
                get: { value(declaration)?.stringValue ?? "" },
                set: { set(declaration, .string($0)) }))
        }
    }
}

extension SceneScriptTemplate.ID {
    var title: String {
        switch self {
        case .empty: return L("Empty Script")
        case .clockText: return L("Clock Text")
        case .dateText: return L("Date Text")
        case .audioScale: return L("Audio-Reactive Scale")
        case .cursorFollow: return L("Follow the Cursor")
        case .objectScript: return L("Object Script")
        }
    }
}

/// Colours as WE's properties write them: normalized `"r g b"`.
enum PropertyColor {
    static func color(_ text: String) -> Color {
        let rgb: [Double] = SceneVector.components(.string(text), fallback: [1, 1, 1])
        // Some files write 0…255.
        let scale: Double = rgb.contains { (component: Double) -> Bool in component > 1 } ? 255.0 : 1.0
        let red: Double = rgb[0] / scale, green: Double = rgb[1] / scale, blue: Double = rgb[2] / scale
        return Color(red: red, green: green, blue: blue)
    }

    static func text(_ color: Color) -> String {
        let rgb: NSColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let components: [CGFloat] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return SceneVector.string(components.map { (component: CGFloat) -> Double in Double(component) })
    }
}
