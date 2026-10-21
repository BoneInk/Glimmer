import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// The selected bone's blend rules (Wallpaper Engine's Edit Constraints › Blend Rules;
/// docs/models-plan.md §2.15): add one toward another bone, or delete one. In the Animate tool
/// each rule's weight (0…1) is keyed at the current frame of the animation, as Wallpaper
/// Engine's "Blend rules" slider keys it.
struct PuppetBlendRulesSection: View {
    @ObservedObject var workspace: PuppetWorkspace
    let document: PuppetDocument
    let bone: Int
    /// Show the weights to key (Animate) rather than the list to edit (Skeleton).
    var keysWeights = false

    private var rules: [PuppetBlendRule] { document.bones[bone].blendRules ?? [] }

    var body: some View {
        if keysWeights {
            if !rules.isEmpty, workspace.clip != nil {
                Section(PL("Blend Rules")) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        LabeledContent {
                            NumericSliderInput<Float>(value: Binding<Float>(get: { workspace.blendRuleWeight(index) },
                                                                            set: { workspace.setBlendRuleWeight(index, to: $0) }),
                                                      range: 0...1, defaultValue: 0, step: 0.01, fractionDigits: 2, fieldWidth: 52)
                        } label: {
                            Text(verbatim: document.bones[rule.target].name)
                        }
                    }
                }
            }
        } else {
            Section {
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        Text(verbatim: document.bones[rule.target].name)
                        Spacer()
                        Button { workspace.removeBlendRule(index) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help(PL("Delete Blend Rule"))
                    }
                }
                let taken = Set(rules.map(\.target))
                Menu(PL("Add Blend Rule")) {
                    ForEach(document.blendRuleTargets(of: bone).filter { !taken.contains($0) }, id: \.self) { target in
                        Button(document.bones[target].name) { workspace.addBlendRule(target: target) }
                    }
                }
                .disabled(document.blendRuleTargets(of: bone).allSatisfy { taken.contains($0) })
            } header: {
                Text(PL("Blend Rules"))
            } footer: {
                Text(PL("A blend rule pulls this bone toward another by the weight each animation keys."))
            }
        }
    }
}
