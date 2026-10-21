import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// A sound layer's properties, as WE's editor lists them (`wallpaperui.exe`'s sound table): its
/// samples, the mode (`playbackmode`: loop, random, single), the volume, the random mode's
/// minimum and maximum time between sounds, mute in editor, start silent, and spatialization with
/// its attenuation start distance and attenuation. Each row writes the scene.json field through
/// the session's overlay.
struct LayerSoundSection: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layer: SceneLayer

    /// WE's `playbackmode` values, in its menu's order.
    static let modes = ["loop", "random", "single"]

    private var samples: [String] {
        guard case .array(let files)? = layer.fields["sound"] else { return [] }
        return files.compactMap(\.stringValue)
    }

    private var mode: String { session.value("playbackmode", of: layer.id)?.stringValue?.lowercased() ?? "loop" }

    var body: some View {
        Section(L("Sound")) {
            if !samples.isEmpty {
                LabeledContent(L("Samples")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, path in
                            Text((path as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                }
            }
            LayerFieldRow(session: session, services: services, layerID: layer.id, field: "playbackmode", title: L("Mode")) {
                Picker(selection: Binding(
                    get: { Self.modes.contains(mode) ? mode : "loop" },
                    set: {
                        let field = L("Mode")
                        session.setValue(.string($0), for: "playbackmode", of: layer.id, actionName: L("Change \(field)"))
                    })) {
                    Text(L("Loop")).tag("loop")
                    Text(L("Random")).tag("random")
                    Text(L("Single")).tag("single")
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
            }
            LayerNumberRow(session: session, services: services, layerID: layer.id, field: "volume", title: L("Volume"),
                           range: 0...1, fallback: 1, displayScale: 100, suffix: "%", fractionDigits: 0)
            if mode == "random" {
                LayerNumberRow(session: session, services: services, layerID: layer.id, field: "mintime", title: L("Min Time"),
                               range: 0...60, fallback: 1, suffix: " s", fractionDigits: 1)
                LayerNumberRow(session: session, services: services, layerID: layer.id, field: "maxtime", title: L("Max Time"),
                               range: 0...60, fallback: 5, suffix: " s", fractionDigits: 1)
            }
        }
        Section(L("Playback")) {
            LayerToggleRow(session: session, services: services, layerID: layer.id, field: "muteineditor", title: L("Mute in Editor"))
            LayerToggleRow(session: session, services: services, layerID: layer.id, field: "startsilent", title: L("Start Silent"))
            LayerToggleRow(session: session, services: services, layerID: layer.id, field: "spatialization", title: L("Spatialization"))
            if session.value("spatialization", of: layer.id)?.boolValue == true {
                LayerNumberRow(session: session, services: services, layerID: layer.id, field: "mindistance",
                               title: L("Audio Attenuation Start Distance"), range: 0...2000, fallback: 1, step: 1, fractionDigits: 0)
                LayerNumberRow(session: session, services: services, layerID: layer.id, field: "attenuation",
                               title: L("Attenuation"), range: 0...10, fallback: 1)
            }
        }
    }
}
