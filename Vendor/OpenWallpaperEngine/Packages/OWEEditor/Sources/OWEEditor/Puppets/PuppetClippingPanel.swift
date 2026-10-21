import OWEInspectorKit
import OWESceneEditing
import SwiftUI

/// Puppet Warp › Clipping Masks (WE's panel, capture 532c): the limbs, Assign and Remove Clipping
/// Mask and Additive blending for the selected one, and its mask's Paint Clipping Mask, Name,
/// Invert mask and Hide mask geometry; the brush while a mask is painted.
struct PuppetClippingPanel: View {
    @ObservedObject var workspace: PuppetWorkspace
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        if let painting = workspace.clippingPainting {
            PuppetClippingBrushSection(workspace: workspace, painting: painting)
        } else {
            limbsSection
            if let limb = workspace.selectedLimb {
                limbSection(limb)
                if let mask = workspace.selectedLimbMask { maskSection(mask) }
            }
            if workspace.document?.hasIncorrectlyNestedClippingMask == true {
                Section {
                    Label(PL("A clipping mask is nested within a mask it clips: Wallpaper Engine ignores the nesting."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let problem = workspace.clippingProblem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }

    /// WE's "Limb <n>", counted from 1.
    static func limbTitle(_ limb: Int) -> String {
        let number = limb + 1
        return PL("Limb \(number)")
    }

    private var limbsSection: some View {
        Section(PL("Limbs")) {
            let clipping = workspace.clipping
            if clipping.limbs.isEmpty {
                Text(PL("The puppet has no mesh.")).foregroundStyle(.secondary)
            }
            ForEach(clipping.limbs.indices, id: \.self) { limb in
                Button {
                    workspace.selectedLimb = limb
                } label: {
                    HStack {
                        Text(Self.limbTitle(limb))
                        Spacer()
                        if let id = clipping.limbs[limb]?.mask, let mask = clipping.mask(id) {
                            Label(mask.title, systemImage: "scissors").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .background(workspace.selectedLimb == limb ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder private func limbSection(_ limb: Int) -> some View {
        let clipping = workspace.clipping
        Section(Self.limbTitle(limb)) {
            Menu(PL("Assign Clipping Mask")) {
                Button(PL("New Clipping Mask…")) {
                    newName = PL("Clipping Mask")
                    isNaming = true
                }
                if !clipping.masks.isEmpty { Divider() }
                ForEach(clipping.masks) { mask in
                    Button(mask.title) { workspace.assignClippingMask(mask.id) }
                }
            }
            .alert(PL("New Clipping Mask"), isPresented: $isNaming) {
                TextField(PL("Name"), text: $newName)
                Button(PL("OK")) { workspace.assignNewClippingMask(named: newName) }
                Button(PL("Cancel"), role: .cancel) {}
            } message: {
                Text(PL("Enter new clipping mask name:"))
            }
            if let entry = clipping.limbs.indices.contains(limb) ? clipping.limbs[limb] : nil {
                Button(PL("Remove Clipping Mask"), role: .destructive) { workspace.removeClippingMask() }
                Toggle(PL("Additive blending"), isOn: Binding(get: { entry.additive }, set: { workspace.setClippingAdditive($0) }))
            }
        }
    }

    @ViewBuilder private func maskSection(_ mask: PuppetClipping.Mask) -> some View {
        Section(PL("Clipping Mask")) {
            Button(PL("Paint Clipping Mask")) { workspace.startPaintingClippingMask(mask.id) }
                .disabled(workspace.assets?.saveMask == nil)
            TextField(PL("Name"), text: Binding(get: { mask.name }, set: { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                workspace.updateClippingMask(mask.id) { $0.name = trimmed }
            }))
            Toggle(PL("Invert mask"), isOn: Binding(get: { mask.invert }, set: { value in
                workspace.updateClippingMask(mask.id) { $0.invert = value }
            }))
            Toggle(PL("Hide mask geometry"), isOn: Binding(get: { mask.hidesMaskGeometry }, set: { value in
                workspace.updateClippingMask(mask.id) { $0.hidesMaskGeometry = value }
            }))
            if mask.texture.isEmpty {
                Text(PL("Paint the mask over the limbs this one may show over.")).foregroundStyle(.secondary)
            }
        }
    }
}

/// The brush while a clipping mask is painted on the puppet's canvas.
private struct PuppetClippingBrushSection: View {
    @ObservedObject var workspace: PuppetWorkspace
    @ObservedObject var painting: MaskPainting

    var body: some View {
        Section(PL("Paint “\(painting.title)”")) {
            Picker(PL("Mode"), selection: $painting.mode) {
                Text(PL("Draw")).tag(MaskPainting.Mode.paint)
                Text(PL("Erase")).tag(MaskPainting.Mode.erase)
            }
            .pickerStyle(.segmented)
            LabeledContent(PL("Size")) {
                NumericSliderInput(value: $painting.brushSize, range: 1...max(2, Double(max(workspace.imageSize.x, workspace.imageSize.y)) / 2),
                                   defaultValue: 40, step: 1, suffix: " px", fractionDigits: 0, fieldWidth: 52)
            }
            LabeledContent(PL("Hardness")) {
                NumericSliderInput(value: Binding(get: { 1 - painting.softness }, set: { painting.softness = 1 - $0 }), range: 0...1,
                                   defaultValue: 0.5, displayScale: 100, suffix: "%", fractionDigits: 0, fieldWidth: 52)
            }
            LabeledContent(PL("Opacity")) {
                NumericSliderInput(value: $painting.strength, range: 0.02...1, defaultValue: 1, displayScale: 100, suffix: "%",
                                   fractionDigits: 0, fieldWidth: 52)
            }
            Button { painting.undoStroke() } label: { Label(PL("Undo Stroke"), systemImage: "arrow.uturn.backward") }
                .disabled(!painting.canUndoStroke)
            HStack {
                Spacer()
                Button(PL("Cancel")) { workspace.cancelPaintingClippingMask() }
                Button(PL("OK")) { workspace.finishPaintingClippingMask() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

extension PuppetClipping.Mask {
    /// The name, or WE's default for a mask read without one.
    var title: String { name.isEmpty ? PL("Clipping Mask") : name }
}
