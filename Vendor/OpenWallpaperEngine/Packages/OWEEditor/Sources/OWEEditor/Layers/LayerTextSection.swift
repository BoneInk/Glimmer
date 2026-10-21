import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// A text layer's Text section: what it says (or the script that writes it, a clock or a date,
/// with the script's options), its font, size, alignment and padding.
struct LayerTextSection: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer

    var body: some View {
        Section(L("Text")) {
            let script: String? = session.textScript(of: layer.id)
            let known: SceneLayerFactory.TextScript? = SceneLayerFactory.TextScript(source: script)
            contentRow(script: script, known: known)
            scriptOptions(script: script, known: known)
            fontRow
            sizeRow
            alignmentRow
            verticalAlignmentRow
            paddingRow
            Button(L("Edit on Canvas")) { session.editingText = layer.id }
                .disabled(script != nil || session.geometry(of: layer.id) == nil)
        }
    }

    private func contentRow(script: String?, known: SceneLayerFactory.TextScript?) -> some View {
        let selection = Binding<String>(
            get: { known?.rawValue ?? (script == nil ? "none" : "custom") },
            set: { (choice: String) in
                guard choice != "custom" else { return }
                session.setTextScript(SceneLayerFactory.TextScript(rawValue: choice), of: layer.id,
                                      actionName: L("Change Text Script"))
            })
        return LabeledContent(L("Content")) {
            Picker(selection: selection) {
                Text(L("Text")).tag("none")
                Text(L("Clock")).tag(SceneLayerFactory.TextScript.clock.rawValue)
                Text(L("Date")).tag(SceneLayerFactory.TextScript.date.rawValue)
                if script != nil && known == nil { Text(L("Script")).tag("custom") }
            } label: { EmptyView() }
            .labelsHidden()
            .disabled(!session.isEditable("text", of: layer.id))
        }
    }

    @ViewBuilder
    private func scriptOptions(script: String?, known: SceneLayerFactory.TextScript?) -> some View {
        if script == nil {
            textEditor
        } else if known == .clock {
            scriptToggle("use24hFormat", title: L("24-Hour Clock"), default: true)
            scriptToggle("showSeconds", title: L("Show Seconds"), default: false)
            separatorRow
        } else if known == .date {
            scriptToggle("showWeekday", title: L("Show Weekday"), default: true)
        } else {
            Text(L("A script writes this text. Its code is edited in the Script editor."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textEditor: some View {
        let text = Binding<String>(
            get: { session.textContent(of: layer.id) ?? "" },
            set: { (value: String) in session.setText(value, of: layer.id, actionName: L("Change Text")) })
        return TextEditor(text: text)
            .font(.body)
            .frame(minHeight: 54, maxHeight: 120)
            .disabled(!session.isEditable("text", of: layer.id))
    }

    private var separatorRow: some View {
        let text = Binding<String>(
            get: { session.textScriptProperties(of: layer.id)["delimiter"]?.stringValue ?? ":" },
            set: { (value: String) in
                session.setTextScriptProperty("delimiter", to: .string(value), of: layer.id,
                                              actionName: L("Change Text Script"))
            })
        return LabeledContent(L("Separator")) {
            TextField(L("Separator"), text: text)
                .labelsHidden()
                .frame(width: 60)
        }
    }

    private var sizeRow: some View {
        let value = Binding<Double>(
            get: { session.number("pointsize", of: layer.id, default: 32) },
            set: { (size: Double) in
                session.setValue(.number(size.rounded()), for: "pointsize", of: layer.id,
                                 actionName: L("Change Text Size"), coalescing: true)
            })
        return fieldRow("pointsize", title: L("Size")) {
            NumericSliderInput<Double>(value: value, range: 4...256, defaultValue: 32, step: 1, fractionDigits: 0,
                                       fieldWidth: 48, clampsTypedValue: false)
        }
    }

    private func alignmentBinding(_ field: String) -> Binding<String> {
        return Binding<String>(
            get: { session.value(field, of: layer.id)?.stringValue ?? "center" },
            set: { (value: String) in
                session.setValue(.string(value), for: field, of: layer.id, actionName: L("Change Alignment"))
            })
    }

    private var alignmentRow: some View {
        fieldRow("horizontalalign", title: L("Alignment")) {
            Picker(selection: alignmentBinding("horizontalalign")) {
                Image(systemName: "text.alignleft").help(L("Left")).tag("left")
                Image(systemName: "text.aligncenter").help(L("Center")).tag("center")
                Image(systemName: "text.alignright").help(L("Right")).tag("right")
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var verticalAlignmentRow: some View {
        fieldRow("verticalalign", title: L("Vertical Alignment")) {
            Picker(selection: alignmentBinding("verticalalign")) {
                Text(L("Top")).tag("top")
                Text(L("Center")).tag("center")
                Text(L("Bottom")).tag("bottom")
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var paddingRow: some View {
        let value = Binding<Double>(
            get: { SceneVector.components(session.value("padding", of: layer.id)).first ?? 32 },
            set: { (padding: Double) in
                session.setValue(.number(padding.rounded()), for: "padding", of: layer.id,
                                 actionName: L("Change Padding"), coalescing: true)
            })
        return fieldRow("padding", title: L("Padding")) {
            NumericSliderInput<Double>(value: value, range: 0...200, defaultValue: 32, step: 1, fractionDigits: 0,
                                       fieldWidth: 48, clampsTypedValue: false)
        }
    }

    private func scriptToggle(_ name: String, title: String, default fallback: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { session.textScriptProperties(of: layer.id)[name]?.boolValue ?? fallback },
            set: { session.setTextScriptProperty(name, to: .bool($0), of: layer.id, actionName: L("Change Text Script")) }))
            .toggleStyle(.checkbox)
    }

    private var fontRow: some View {
        // WE parses an absent font as empty and draws it in its fallback face, Arial.
        let current = session.value("font", of: layer.id)?.stringValue ?? ""
        var fonts = services.fonts()
        if !fonts.contains(where: { $0.value == current }) {
            let title = current.isEmpty ? L("Default") : (current as NSString).lastPathComponent
            fonts.insert(EditorFont(value: current, title: title), at: 0)
        }
        return fieldRow("font", title: L("Font")) {
            HStack(spacing: 4) {
                Picker(selection: Binding(
                    get: { current },
                    set: { session.setValue(.string($0), for: "font", of: layer.id, actionName: L("Change Font")) })) {
                    ForEach(fonts) { font in Text(font.title).tag(font.value) }
                } label: { EmptyView() }
                .labelsHidden()
                Button {
                    importFont()
                } label: {
                    Label(L("Import Font…"), systemImage: "plus").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(services.assetStore == nil)
                .help(L("Import Font…"))
            }
        }
    }

    private func importFont() {
        guard let store = services.assetStore, let url = EditorFilePicker.choose(.font).first else { return }
        do {
            let path = try store.importFont(from: url)
            session.setValue(.string(path), for: "font", of: layer.id, actionName: L("Change Font"))
        } catch {
            tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
        }
    }

    /// The field's control, or, for one a user property sets, which property.
    @ViewBuilder private func fieldRow<Control: View>(_ field: String, title: String,
                                                      @ViewBuilder control: () -> Control) -> some View {
        if case .userProperty(let key) = session.binding(field, of: layer.id) {
            let name = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
            LabeledContent(title) {
                Text(L("Set by the user property “\(name)”"))
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent(title) { control() }
        }
    }
}

/// An image layer's size, and a solid layer's fill.
struct LayerSizeRows: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer

    var body: some View {
        if layer.kind == .image, !layer.fillsScene {
            LabeledContent(L("Size")) {
                HStack {
                    sizeField("W", component: 0)
                    sizeField("H", component: 1)
                }
            }
        }
    }

    private func sizeField(_ axis: String, component: Int) -> some View {
        TextField(value: Binding<Double>(
            get: { SceneVector.components(session.value("size", of: layer.id), fallback: [100, 100])[component] },
            set: { value in
                var size = SceneVector.components(session.value("size", of: layer.id), fallback: [100, 100])
                size[component] = max(value, 1)
                session.setValue(SceneVector.value(size), for: "size", of: layer.id, actionName: L("Change Size"), coalescing: true)
            }), format: .number.precision(.fractionLength(0...1))) {
            Text(verbatim: axis)
        }
        .multilineTextAlignment(.trailing)
        .disabled(!session.isEditable("size", of: layer.id))
    }
}
