import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

extension SceneInspectorContent {
    @ViewBuilder func effectList(for item: SceneInspectorItem) -> some View {
        if !item.effects.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Effects").font(.title3.bold())
                ForEach(item.effects) { effect in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            if let maskPath = effect.maskPath {
                                HStack(spacing: 5) {
                                    Text("Mask").font(.headline)
                                    InfoTip(String(localized: "Limits this effect to the white areas of the mask. Black areas are left untouched."))
                                }
                                Text(maskPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let mask = model.decodedMasks[effect.id] {
                                    Image(nsImage: mask.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity, maxHeight: 300)
                                        .background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else if model.loadingItemID == item.id {
                                    ProgressView()
                                }
                            } else {
                                Text("No mask").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(effect.combos.filter { model.requirementsHold($0, in: effect) }) { combo in
                                effectComboControl(combo, effect: effect)
                            }
                            ForEach(effect.controls) { control in
                                if control.isColor {
                                    if control.component == 0 {
                                        ColorPicker(selection: Binding(
                                            get: { model.effectColor(for: control) },
                                            set: { model.setEffectColor($0, control: control) }
                                        ), supportsOpacity: false) {
                                            parameterLabel(control.title, help: parameterHelp(control, effect: effect.name))
                                        }
                                        .anchorsColorPanel()
                                    }
                                } else {
                                    effectSlider(control, effect: effect)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Toggle("Enabled", isOn: Binding(
                                get: { model.effectEnabled[effect.id] ?? true },
                                set: { model.setEffectEnabled($0, effect: effect) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            Label(effect.title, systemImage: "slider.horizontal.3")
                            InfoTip(SceneHelp.effect(effect.name))
                        }
                    }
                }
            }
        }
    }

    /// WE's material slider: the annotation's range, step 0.01 (1 for `int`), and a number field
    /// that accepts values past the range.
    @ViewBuilder func effectSlider(_ control: SceneInspectorEffectControl, effect: SceneInspectorEffect) -> some View {
        let value = Binding<Double>(
            get: { model.displayedEffectValue(for: control) },
            set: { model.setDisplayedEffectValue($0, control: control) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                parameterLabel(control.title, help: parameterHelp(control, effect: effect.name))
                if control.isLinked, control.component == 0 {
                    Toggle(isOn: Binding(get: { model.isLinked(control) },
                                         set: { model.setLinked($0, control: control) })) {
                        Image(systemName: "link")
                    }
                    .toggleStyle(.button)
                    .help("Edit X and Y together")
                }
            }
            NumericSliderInput(value: value,
                               range: control.minimum...max(control.maximum, control.minimum + 0.001),
                               defaultValue: control.defaultValue,
                               step: control.isInteger ? 1 : 0.01,
                               fractionDigits: control.isInteger ? 0 : 2, fieldWidth: 76,
                               clampsTypedValue: false)
            inspectorMusicSyncControls(for: control)
        }
    }

    @ViewBuilder func effectComboControl(_ combo: SceneInspectorEffectCombo, effect: SceneInspectorEffect) -> some View {
        let selection = Binding<Int>(get: { model.comboValue(combo) }, set: { model.setComboValue($0, combo: combo) })
        if combo.options.isEmpty {
            Toggle(combo.title, isOn: Binding(get: { selection.wrappedValue != 0 },
                                              set: { selection.wrappedValue = $0 ? 1 : 0 }))
                .toggleStyle(.checkbox)
        } else {
            Picker(combo.title, selection: selection) {
                ForEach(Self.optionGroups(combo), id: \.offset) { group in
                    if let heading = group.heading {
                        Section(heading) {
                            ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                        }
                    } else {
                        ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                    }
                }
            }
        }
    }

    /// The combo's options in runs of one editor group (WE's "Native (fast)" / "Emulated (slow)"
    /// blend modes), in order; one run without a heading for authored options.
    static func optionGroups(_ combo: SceneInspectorEffectCombo)
        -> [(offset: Int, heading: String?, options: [(title: String, value: Int)])] {
        // Shared with the Wallpaper Editor (`InspectorOptionGroups`).
        InspectorOptionGroups.groups(combo.options.map { InspectorOption(title: $0.title, value: $0.value, group: $0.group) })
            .map { group -> (offset: Int, heading: String?, options: [(title: String, value: Int)]) in
                (group.id, group.heading, group.options.map { (title: $0.title, value: $0.value) })
            }
    }

    @ViewBuilder func inspectorMusicSyncControls(for control: SceneInspectorEffectControl) -> some View {
        let isEnabled = Binding<Bool>(
            get: { model.musicSyncEnabled(for: control) },
            set: { model.setMusicSyncEnabled($0, for: control) }
        )
        Toggle("Sync to Music", isOn: isEnabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(SceneHelp.musicSyncSource)
        if isEnabled.wrappedValue {
            let span = max(control.maximum - control.minimum, 0.001)
            let amount = Binding<Double>(
                get: { model.musicAmount(for: control) },
                set: { model.setMusicAmount($0, for: control) }
            )
            HStack {
                Text("Music Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSliderInput(value: amount, range: -span...span,
                                   defaultValue: 0, fractionDigits: 3,
                                   sliderWidth: 100, fieldWidth: 64)
            }
        }
    }

    func parameterLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            InfoTip(help)
        }
    }

    func parameterHelp(_ control: SceneInspectorEffectControl, effect: String? = nil) -> String {
        SceneHelp.parameter(effect: effect, key: control.key, title: control.title,
                            displaysDegrees: control.displaysDegrees)
    }
}
