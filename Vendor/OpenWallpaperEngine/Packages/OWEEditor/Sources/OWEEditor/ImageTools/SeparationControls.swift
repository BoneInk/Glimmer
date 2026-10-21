import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// WE's Foreground Separation sidebar: Undo and Redo, Editing (Polygon or Brush, the brush's
/// marks and size, Reset Mask) and Fine-tuning (Fill gaps, Mask tolerance, Smoothing, Quality
/// level).
struct SeparationControls: View {
    @ObservedObject var editor: SeparationEditor
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button { editor.undo() } label: { Label(IL("Undo"), systemImage: "arrow.uturn.backward") }
                        .disabled(!editor.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button { editor.redo() } label: { Label(IL("Redo"), systemImage: "arrow.uturn.forward") }
                        .disabled(!editor.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                }
                .labelStyle(.iconOnly)
            }
            Section(IL("Editing")) {
                Picker(IL("Editing"), selection: Binding(get: { editor.mode }, set: { editor.setMode($0) })) {
                    Label(IL("Polygon"), systemImage: "skew").tag(SeparationMarks.Mode.polygon)
                    Label(IL("Brush"), systemImage: "paintbrush").tag(SeparationMarks.Mode.brush)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if editor.mode == .brush {
                    Picker(IL("Brush"), selection: $editor.brush) {
                        Text(IL("Mark Foreground")).tag(SeparationEditor.Brush.foreground)
                        Text(IL("Mark Background")).tag(SeparationEditor.Brush.background)
                        Text(IL("Erase")).tag(SeparationEditor.Brush.erase)
                    }
                    .pickerStyle(.radioGroup)
                    LabeledContent(IL("Brush size")) {
                        NumericSliderInput(value: $editor.brushSize, range: 1...100, defaultValue: 20, step: 1, suffix: "%", fractionDigits: 0)
                    }
                }
                Button(IL("Reset Mask"), role: .destructive) { isConfirmingReset = true }
            }
            Section {
                integerSlider(IL("Fill gaps"), \.fillGaps, ForegroundSeparator.Settings.fillGapsRange, defaultValue: 100)
                integerSlider(IL("Mask tolerance"), \.maskTolerance, ForegroundSeparator.Settings.maskToleranceRange, defaultValue: -1)
                integerSlider(IL("Smoothing"), \.smoothing, ForegroundSeparator.Settings.smoothingRange, defaultValue: 1)
                integerSlider(IL("Quality level"), \.quality, ForegroundSeparator.Settings.qualityRange, defaultValue: 1)
            } header: {
                Text(IL("Fine-tuning"))
            } footer: {
                Text(IL("Higher values increase quality slightly but significantly increase time to recalculate."))
            }
        }
        .formStyle(.grouped)
        .alert(IL("Reset Mask"), isPresented: $isConfirmingReset) {
            Button(IL("Reset Mask"), role: .destructive) { editor.resetMarks() }
            Button(IL("Cancel"), role: .cancel) {}
        } message: {
            Text(IL("Are you sure that you want to reset the entire mask?"))
        }
    }

    private func integerSlider(_ title: String, _ keyPath: WritableKeyPath<ForegroundSeparator.Settings, Int>, _ range: ClosedRange<Int>,
                               defaultValue: Int) -> some View {
        LabeledContent(title) {
            NumericSliderInput(value: Binding(get: { Double(editor.settings[keyPath: keyPath]) },
                                              set: { editor.settings[keyPath: keyPath] = Int($0.rounded()) }),
                               range: Double(range.lowerBound)...Double(range.upperBound), defaultValue: Double(defaultValue),
                               step: 1, fractionDigits: 0)
        }
    }
}

/// WE's View buttons over the canvas: Original, Foreground & Original, Foreground, Background,
/// the Mask (M) with Improve visibility and Mask opacity, and Reset View.
struct SeparationViewBar: View {
    @ObservedObject var editor: SeparationEditor
    let resetView: () -> Void
    @State private var showsMaskOptions = false

    var body: some View {
        HStack(spacing: 8) {
            Picker(IL("View"), selection: $editor.preview) {
                Image(systemName: "figure.stand").help(IL("Original")).tag(SeparationEditor.Preview.original)
                Image(systemName: "square.2.layers.3d").help(IL("Foreground & Original")).tag(SeparationEditor.Preview.foregroundAndOriginal)
                Image(systemName: "square.3.layers.3d.top.filled").help(IL("Foreground")).tag(SeparationEditor.Preview.foreground)
                Image(systemName: "square.3.layers.3d.bottom.filled").help(IL("Background")).tag(SeparationEditor.Preview.background)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(editor.result == nil)
            Toggle(isOn: $editor.showsMarks) { Image(systemName: "circle.dashed") }
                .toggleStyle(.button)
                .help(IL("Mask (Hotkey: M)"))
            Button { showsMaskOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help(IL("Mask opacity"))
                .popover(isPresented: $showsMaskOptions) {
                    Form {
                        Toggle(IL("Improve visibility"), isOn: $editor.fadesOriginal)
                        LabeledContent(IL("Mask opacity")) {
                            NumericSliderInput(value: $editor.marksOpacity, range: 10...100, defaultValue: 50, step: 1, fractionDigits: 0)
                        }
                    }
                    .padding()
                    .frame(width: 300)
                }
            Button { resetView() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .help(IL("Reset View"))
            Spacer()
            if editor.isComputing { ProgressView().controlSize(.small) }
        }
        .padding(8)
    }
}

/// WE's footer of the separation windows: Recalculate (R, lit while a change waits), Auto
/// Recalculate and Help.
struct SeparationFooterTools: View {
    @ObservedObject var editor: SeparationEditor
    let helpURL: URL

    var body: some View {
        HStack {
            Button(IL("Recalculate")) { editor.recalculate() }
                .disabled(!editor.needsRecalculate)
                .help(IL("Hotkey: R"))
            Toggle(IL("Auto Recalculate"), isOn: $editor.settings.autoRecalculate)
                .toggleStyle(.button)
            Button(IL("Help")) { NSWorkspace.shared.open(helpURL) }
        }
    }
}
