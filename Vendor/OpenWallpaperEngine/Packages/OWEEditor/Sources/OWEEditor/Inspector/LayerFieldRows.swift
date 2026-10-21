import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// One row of a layer's inspector for the scene.json field `field`: its control, or, for a field a
/// user property sets, which property, as WE's editor shows it. Every change is one undo step of
/// the session's overlay (a run of changes of one control, one step).
struct LayerFieldRow<Control: View>: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layerID: Int
    let field: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        Group {
            if case .userProperty(let key) = session.binding(field, of: layerID) {
                let name = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
                LabeledContent(title) {
                    Text(L("Set by the user property “\(name)”"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent(title) { control() }
            }
        }
        .fieldAuthoring(layer: layerID, path: SceneFieldPath(components: [field]))
    }
}

/// A layer's on/off field (`perspective`, `solid`, `startsilent`…), `fallback` when unauthored.
struct LayerToggleRow: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layerID: Int
    let field: String
    let title: String
    var fallback = false

    var body: some View {
        LayerFieldRow(session: session, services: services, layerID: layerID, field: field, title: title) {
            Toggle(isOn: Binding(
                get: { session.value(field, of: layerID)?.boolValue ?? fallback },
                set: { session.setValue(.bool($0), for: field, of: layerID, actionName: L("Change \(title)")) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

/// A layer's number field with WE's slider and a typed value past its range.
struct LayerNumberRow: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layerID: Int
    let field: String
    let title: String
    let range: ClosedRange<Double>
    let fallback: Double
    var step: Double?
    var displayScale = 1.0
    var suffix = ""
    var fractionDigits = 2

    var body: some View {
        LayerFieldRow(session: session, services: services, layerID: layerID, field: field, title: title) {
            NumericSliderInput<Double>(value: Binding<Double>(
                get: { session.number(field, of: layerID, default: fallback) },
                set: { session.setValue(.number($0), for: field, of: layerID, actionName: L("Change \(title)"), coalescing: true) }),
                range: range, defaultValue: fallback, step: step, displayScale: displayScale, suffix: suffix,
                fractionDigits: fractionDigits, fieldWidth: 52, clampsTypedValue: false)
        }
    }
}
