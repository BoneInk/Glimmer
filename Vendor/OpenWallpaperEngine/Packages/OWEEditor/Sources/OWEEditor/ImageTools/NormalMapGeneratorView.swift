import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// WE's Normal Map Generation window: the options on the left (Shape: Blur, Depth, Exponent,
/// Threshold; Details: Blur, Depth, Invert), the picture or its normal map on the right.
struct NormalMapGeneratorView: View {
    @StateObject private var model: NormalMapGeneratorModel
    @State private var viewport = ImageToolViewport()
    @Environment(\.dismiss) private var dismiss

    init(session: SceneEditSession, layerID: Int, services: WallpaperEditorServices, tools: EditorTools) {
        _model = StateObject(wrappedValue: NormalMapGeneratorModel(session: session, layerID: layerID, services: services, tools: tools))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                controls
                    .frame(width: 280)
                Divider()
                VStack(spacing: 0) {
                    previewBar
                    Divider()
                    ImageToolCanvas(image: model.shownImage, viewport: $viewport) { _ in EmptyView() }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 600, idealHeight: 760)
        .onAppear { viewport.imageSize = model.imageSize }
        .onDisappear { model.cancel() }
    }

    private var controls: some View {
        Form {
            Section {
                Button(IL("Reset View")) { viewport.fit() }
                Button(IL("Reset")) { model.resetSettings() }
            } header: {
                Text(IL("Normal Map Generation")).font(.headline)
            }
            Section(IL("Shape")) {
                slider(IL("Blur"), value: oddBinding(\.blur), range: NormalMapGenerator.Settings.blurRange, defaultValue: 63)
                slider(IL("Depth"), value: $model.settings.depth, range: NormalMapGenerator.Settings.depthRange, defaultValue: 1, step: 0.01)
                slider(IL("Exponent"), value: $model.settings.exponent, range: NormalMapGenerator.Settings.exponentRange, defaultValue: 4,
                       step: 0.1)
                slider(IL("Threshold"), value: $model.settings.threshold, range: NormalMapGenerator.Settings.thresholdRange, defaultValue: 1,
                       step: 0.1)
            }
            Section(IL("Details")) {
                slider(IL("Blur"), value: oddBinding(\.detailsBlur), range: NormalMapGenerator.Settings.detailsBlurRange, defaultValue: 21)
                slider(IL("Depth"), value: $model.settings.detailsDepth, range: NormalMapGenerator.Settings.depthRange, defaultValue: 1,
                       step: 0.01)
                Toggle(IL("Invert"), isOn: $model.settings.detailsInvert)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double,
                        step: Double? = nil) -> some View {
        LabeledContent(title) {
            NumericSliderInput(value: value, range: range, defaultValue: defaultValue, step: step, fractionDigits: 2)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Int>, defaultValue: Int) -> some View {
        LabeledContent(title) {
            NumericSliderInput(value: value, range: Double(range.lowerBound)...Double(range.upperBound),
                               defaultValue: Double(defaultValue), step: 2, fractionDigits: 0)
        }
    }

    /// A blur size (odd, as WE's sliders step by 2) as a slider value.
    private func oddBinding(_ keyPath: WritableKeyPath<NormalMapGenerator.Settings, Int>) -> Binding<Double> {
        Binding(get: { Double(model.settings[keyPath: keyPath]) }, set: { newValue in
            var value = Int(newValue.rounded())
            if value.isMultiple(of: 2) { value += 1 }
            model.settings[keyPath: keyPath] = value
        })
    }

    private var previewBar: some View {
        HStack {
            Picker(IL("View"), selection: $model.preview) {
                Text(IL("Normal Map")).tag(NormalMapGeneratorModel.Preview.normalMap)
                Text(IL("Original")).tag(NormalMapGeneratorModel.Preview.original)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            if model.isGenerating { ProgressView().controlSize(.small) }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(IL("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(IL("OK")) { if model.apply() { dismiss() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.normalMap == nil || model.isGenerating)
        }
        .padding(12)
    }
}

/// The inspector's normal map row for an image layer (WE's material panel: Normal map, with
/// Generate and Remove).
struct NormalMapSection: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer
    @State private var isGenerating = false

    private var material: ImageLayerMaterial? { ImageLayerMaterial(layer: layer, readFile: services.readFile) }

    var body: some View {
        if let material, material.texture != nil {
            Section(IL("Normal Map")) {
                LabeledContent(IL("Normal Map")) {
                    Text(material.normalMap.map(ImageLayerMaterial.baseName) ?? IL("None"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button(IL("Generate…")) { isGenerating = true }
                        .disabled(services.assetStore?.encoder == nil)
                    if material.normalMap != nil {
                        Button(IL("Remove")) { remove() }
                    }
                }
            }
            .sheet(isPresented: $isGenerating) {
                NormalMapGeneratorView(session: session, layerID: layer.id, services: services, tools: tools)
            }
        }
    }

    private func remove() {
        guard let store = services.assetStore else { return }
        do {
            try session.removeNormalMap(of: layer.id, store: store, readFile: services.readFile, actionName: IL("Remove Normal Map"))
        } catch {
            tools.problem = IL("The normal map couldn’t be removed: \(error.localizedDescription)")
        }
    }
}
