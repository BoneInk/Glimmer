import SwiftUI
import OWESceneEditing

/// Add Layer › Preset: WE's presets that add other layers than particle systems (Clock and
/// 3D Clock, Countdown, the light-shaft shapes), each variant under its preset with WE's
/// description. WE's particle presets are in Add Particle System.
struct PresetBrowserView: View {
    let presets: [ParticlePreset]
    let hasWEAssets: Bool
    let openAssetsSetup: () -> Void
    let choose: (ParticlePreset, ParticlePreset.Variant) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private static func id(_ preset: ParticlePreset, _ variant: ParticlePreset.Variant) -> String { "\(preset.id)/\(variant.id)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Add Preset")).font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            if !hasWEAssets {
                EditorAssetsPrompt(message: L("Wallpaper Engine’s presets come with its assets, which aren’t installed.")) {
                    dismiss()
                    openAssetsSetup()
                }
                Spacer()
            } else if presets.isEmpty {
                Text(L("This copy of Wallpaper Engine’s assets has no presets. Install the assets again to add them."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(40)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(presets) { preset in
                        Section(preset.title) {
                            ForEach(preset.variants) { variant in
                                Text(variant.title)
                                    .tag(Self.id(preset, variant))
                                    .onTapGesture(count: 2) { add(preset, variant) }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let summary = selected?.0.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) { selected.map { add($0.0, $0.1) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
    }

    private var selected: (ParticlePreset, ParticlePreset.Variant)? {
        for preset in presets {
            for variant in preset.variants where Self.id(preset, variant) == selection { return (preset, variant) }
        }
        return nil
    }

    private func add(_ preset: ParticlePreset, _ variant: ParticlePreset.Variant) {
        dismiss()
        choose(preset, variant)
    }
}
