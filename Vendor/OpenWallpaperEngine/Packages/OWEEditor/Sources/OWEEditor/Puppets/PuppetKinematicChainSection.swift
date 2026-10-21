import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// The Physics tool's settings of a bone whose Simulation mode is "Kinematic chain", as Wallpaper
/// Engine's Edit Constraints dialog lays them out: the preset, Limb depth and Behavior, then for
/// Inverse kinematics the orientation controller and Rotate when overstretched, for Rope gravity,
/// stretch, the free endpoint, mass and friction. The chain's controllers are keyed in the
/// Animate tool, on the canvas.
struct PuppetKinematicChainSections: View {
    @ObservedObject var workspace: PuppetWorkspace
    let ik: PuppetBoneIK
    let bone: Int

    private func update(_ actionName: String = PL("Change Kinematic Chain"), coalescing: Bool = true,
                        _ change: @escaping (inout PuppetBoneIK) -> Void) {
        workspace.updateIK(of: bone, actionName, coalescing: coalescing) { value in
            guard var chain = value else { return }
            change(&chain)
            value = chain
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<PuppetBoneIK, Bool>) -> some View {
        Toggle(title, isOn: Binding<Bool>(get: { ik[keyPath: key] }, set: { (on: Bool) in update(coalescing: false) { $0[keyPath: key] = on } }))
    }

    private func slider(_ title: String, _ key: WritableKeyPath<PuppetBoneIK, Float>, _ range: ClosedRange<Float>,
                        _ fallback: Float, suffix: String = "", digits: Int = 0) -> some View {
        LabeledContent(title) {
            NumericSliderInput<Float>(value: Binding<Float>(get: { ik[keyPath: key] }, set: { (value: Float) in
                update { $0[keyPath: key] = min(max(value, range.lowerBound), range.upperBound) }
            }), range: range, defaultValue: fallback, step: 1, suffix: suffix, fractionDigits: digits, fieldWidth: 52)
        }
    }

    var body: some View {
        Section(PL("Kinematic chain")) {
            Menu(PL("Preset")) {
                Button(PL("Inverse kinematics arm/leg")) {
                    update(PL("Apply Physics Preset"), coalescing: false) { $0 = Self.applying(.arm, to: $0) }
                }
                Button(PL("Rope with 4 elements")) {
                    update(PL("Apply Physics Preset"), coalescing: false) { $0 = Self.applying(.rope, to: $0) }
                }
            }
            LabeledContent(PL("Limb depth")) {
                Stepper(value: Binding<Int>(get: { ik.limbDepth }, set: { (depth: Int) in update { $0.limbDepth = depth } }), in: 1...6) {
                    Text(verbatim: ik.limbDepth.formatted()).monospacedDigit()
                }
            }
            .help(PL("How many bones above this one the chain moves."))
            Picker(PL("Behavior"), selection: Binding<PuppetBoneIK.Behavior>(get: { ik.behavior }, set: { (behavior: PuppetBoneIK.Behavior) in
                update(coalescing: false) { $0.behavior = behavior }
            })) {
                Text(PL("Inverse kinematics")).tag(PuppetBoneIK.Behavior.inverseKinematics)
                Text(PL("Rope")).tag(PuppetBoneIK.Behavior.rope)
            }
        }
        switch ik.behavior {
        case .inverseKinematics:
            Section {
                toggle(PL("Use orientation controller"), \.orientationController)
                toggle(PL("Rotate when overstretched"), \.rotateWhenOverstretched)
                if ik.rotateWhenOverstretched {
                    slider(PL("Full rotation distance"), \.fullRotationDistance, 1...100, 25, suffix: " px")
                }
            } footer: {
                if ik.rotateWhenOverstretched {
                    Text(PL("The last bone turns to point at its IK target as the chain stretches past its length."))
                }
            }
        case .rope:
            Section {
                toggle(PL("Gravity enabled"), \.gravity)
                toggle(PL("Stretch enabled"), \.stretch)
                toggle(PL("Free endpoint"), \.freeEndpoint)
                    .disabled(ik.stretch)
                slider(PL("Mass"), \.mass, 1...2000, 20, digits: 1)
                slider(PL("Friction"), \.friction, 0...99, 20)
            }
        }
        Section {
            Text(PL("In the Animate tool, drag the IK target (◆) and the orientation controller (●) to key them."))
                .foregroundStyle(.secondary)
        }
    }

    /// A preset over the chain: its keys stay.
    static func applying(_ preset: PuppetBoneIK.Preset, to chain: PuppetBoneIK) -> PuppetBoneIK {
        var value = PuppetBoneIK(preset: preset)
        value.targetKeys = chain.targetKeys
        value.orientationKeys = chain.orientationKeys
        value.orientationRest = chain.orientationRest
        return value
    }
}
