import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// WE's Scene Options (`ui_editor_scene_options_*`), grouped and labelled as its editor groups
/// them (`wallpaperui.exe`'s scene property table): General, Bloom, Camera, Distance Fog, Height
/// Fog and Physics. Each row edits scene.json's `general` through the session's overlay, one undo
/// step per change; a setting a user property sets shows which one instead of a control.
struct SceneOptionsSection: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices

    private var isPerspective: Bool { session.outline.size == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group(L("General")) {
                colorRow("clearcolor", L("Background Color"))
                colorRow("ambientcolor", L("Ambient Color"))
                colorRow("skylightcolor", L("Sky Reflection Color"))
                toggleRow("transparentsorting", L("Transparent Object Sorting"))
            }
            group(L("Bloom")) {
                toggleRow("bloom", L("Enabled"))
                if session.generalBool("bloom") {
                    numberRow("bloomstrength", L("Strength"), range: 0...5)
                    numberRow("bloomthreshold", L("Threshold"), range: 0...1)
                    colorRow("bloomtint", L("Tint"))
                    toggleRow("hdr", L("Ultra Post-Processing (HDR)"))
                    if session.generalBool("hdr") {
                        hint(L("You should test standard and HDR bloom to ensure the wallpaper looks good for everyone."))
                        numberRow("bloomhdrstrength", L("HDR Strength"), range: 0...5)
                        numberRow("bloomhdrthreshold", L("HDR Threshold"), range: 0...5)
                        numberRow("bloomhdrfeather", L("HDR Threshold Smoothing"), range: 0...1)
                        numberRow("bloomhdrscatter", L("HDR Scatter"), range: 0...3)
                        numberRow("bloomhdriterations", L("HDR Iterations"), range: 1...12, step: 1, fractionDigits: 0)
                    }
                    hint(L("Bloom needs Post-Processing turned on in Settings › Performance; HDR bloom needs it set to Ultra."))
                }
            }
            group(L("Camera")) {
                // WE's FOV is the scene's own in a 3D scene, else the one perspective layers use.
                numberRow(isPerspective ? "fov" : "perspectiveoverridefov", L("FOV"), range: 1...179, step: 1, fractionDigits: 0)
                numberRow("nearz", L("Near Z"), range: 0.01...100, fractionDigits: 3)
                numberRow("farz", L("Far Z"), range: 100...100_000, step: 100, fractionDigits: 0)
                if !isPerspective {
                    numberRow("zoom", L("Camera Zoom"), range: 0.1...5)
                }
                toggleRow("camerashake", L("Camera Shake"))
                if session.generalBool("camerashake") {
                    numberRow("camerashakeamplitude", L("Amplitude"), range: 0...2)
                    numberRow("camerashakeroughness", L("Roughness"), range: 0...2)
                    numberRow("camerashakespeed", L("Speed"), range: 0...10)
                }
                toggleRow("cameraparallax", L("Camera Parallax"))
                if session.generalBool("cameraparallax") {
                    numberRow("cameraparallaxamount", L("Amount"), range: 0...2)
                    numberRow("cameraparallaxdelay", L("Delay"), range: 0...1)
                    numberRow("cameraparallaxmouseinfluence", L("Mouse Influence"), range: 0...1)
                }
            }
            fogGroup(L("Distance Fog"), prefix: "fogdistance")
            fogGroup(L("Height Fog"), prefix: "fogheight")
            group(L("Physics")) {
                vectorRow("gravitydirection", L("Gravity Direction"))
                numberRow("gravitystrength", L("Gravity Strength"), range: 0...10)
                toggleRow("windenabled", L("Wind Enabled"))
                if session.generalBool("windenabled") {
                    vectorRow("winddirection", L("Wind Direction"))
                    numberRow("windstrength", L("Wind Speed"), range: 0...10)
                }
            }
        }
    }

    // MARK: Groups

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
        }
    }

    private func fogGroup(_ title: String, prefix: String) -> some View {
        group(title) {
            toggleRow(prefix, L("Enabled"))
            if session.generalBool(prefix) {
                colorRow(prefix + "color", L("Color"))
                numberRow(prefix + "start", L("Start"), range: -100...100)
                numberRow(prefix + "end", L("End"), range: -100...100)
                numberRow(prefix + "startdensity", L("Start Density"), range: 0...1)
                numberRow(prefix + "enddensity", L("End Density"), range: 0...1)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    /// The setting's control, or, for one a user property sets, which property.
    private func row<Control: View>(_ name: String, _ title: String, @ViewBuilder control: () -> Control) -> some View {
        LabeledContent(title) {
            if case .userProperty(let key) = session.generalBinding(name) {
                let property = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
                Text(L("Set by the user property “\(property)”"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } else {
                control()
            }
        }
    }

    private var actionName: String { L("Change Scene Options") }

    private func toggleRow(_ name: String, _ title: String) -> some View {
        row(name, title) {
            Toggle(isOn: Binding(
                get: { session.generalBool(name) },
                set: { session.setGeneral(.bool($0), for: name, actionName: actionName) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func numberRow(_ name: String, _ title: String, range: ClosedRange<Double>, step: Double? = nil,
                           fractionDigits: Int = 2) -> some View {
        row(name, title) {
            NumericSliderInput<Double>(value: Binding<Double>(
                get: { session.generalNumber(name) },
                set: { value in
                    let stored = fractionDigits == 0 ? value.rounded() : value
                    session.setGeneral(.number(stored), for: name, actionName: actionName, coalescing: true)
                }),
                range: range, defaultValue: SceneGeneralSetting.defaults[name]?.doubleValue ?? range.lowerBound,
                step: step, fractionDigits: fractionDigits, fieldWidth: 56, clampsTypedValue: false)
        }
    }

    private func colorRow(_ name: String, _ title: String) -> some View {
        row(name, title) {
            ColorPicker(selection: Binding(
                get: {
                    let rgb = session.generalVector(name, count: 3)
                    return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                },
                set: { color in
                    let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
                    let value = SceneVector.value([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init))
                    session.setGeneral(value, for: name, actionName: actionName, coalescing: true)
                }), supportsOpacity: false) {
                EmptyView()
            }
            .labelsHidden()
        }
    }

    private func vectorRow(_ name: String, _ title: String) -> some View {
        row(name, title) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { component in
                    TextField(value: Binding<Double>(
                        get: { session.generalVector(name, count: 3)[component] },
                        set: { value in
                            var vector = session.generalVector(name, count: 3)
                            vector[component] = value
                            session.setGeneral(SceneVector.value(vector), for: name, actionName: actionName, coalescing: true)
                        }), format: .number.precision(.fractionLength(0...3))) {
                        Text(verbatim: ["X", "Y", "Z"][component])
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                }
            }
        }
    }
}

/// WE's Project Settings (`ui_editor_project_settings_modal_*`): the project's title and the
/// scene's resolution. The title goes into project.json when the wallpaper is saved as a new one
/// (or saved, for one of the user's own); the resolution is the scene's `orthogonalprojection`.
struct ProjectSettingsSection: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    @State private var title = ""

    /// project.json's own title.
    private var authoredTitle: String? {
        guard let data = services.projectJSON,
              let project = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return project["title"] as? String
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(L("Title")) {
                    TextField(text: $title) { EmptyView() }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitTitle)
                }
                if let resolution = session.projectResolution {
                    LabeledContent(L("Resolution")) {
                        HStack(spacing: 4) {
                            dimensionField(resolution, component: 0)
                            Text(verbatim: "×").foregroundStyle(.secondary)
                            dimensionField(resolution, component: 1)
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(L("Project Settings")).font(.headline)
        }
        .onAppear { title = session.projectTitle ?? authoredTitle ?? "" }
        .onChange(of: session.projectTitle) { _, edited in title = edited ?? authoredTitle ?? "" }
        .onDisappear(perform: commitTitle)
    }

    private func commitTitle() {
        session.setProjectTitle(title, authored: authoredTitle, actionName: L("Change Project Settings"))
    }

    private func dimensionField(_ resolution: SIMD2<Int>, component: Int) -> some View {
        TextField(value: Binding<Int>(
            get: { component == 0 ? resolution.x : resolution.y },
            set: { value in
                var size = resolution
                if component == 0 { size.x = value } else { size.y = value }
                session.setProjectResolution(size, actionName: L("Change Project Settings"))
            }), format: .number.grouping(.never)) {
            Text(verbatim: component == 0 ? "W" : "H")
        }
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 64)
    }
}
