import SwiftUI

/// The Android Export mode's Export Settings: the device (or a custom size) and the status bar
/// guide, the crop's zoom, where the pointer rests, the output (Pre-Rendered's video size, frame
/// rate and length, or Dynamic's quality), then the user properties, all of them the mode's own
/// (`IsolatedSceneEditSession`). It is the Export Settings sheet's body; the selected layer's
/// adjustments are the mode's right-hand panel (`AndroidExportLayerPanel`).
struct AndroidExportSettingsView: View {
    @ObservedObject var model: AndroidExportEditorModel

    var body: some View {
        ScrollView {
            if model.isVideo { videoBody } else { sceneBody }
        }
    }

    /// A video is packed as it is: nothing to frame, bake or choose.
    private var videoBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("The video as Wallpaper Engine exports it", systemImage: "film")
                    .font(.headline)
                Text("The package holds the video file exactly as it is, its preview and a short project.json, as Wallpaper Engine's own export does. The phone fills its screen with the video, so there is nothing to set here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    private var sceneBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceSection
            Divider()
            zoomSection
            if let followsPointer = model.followsPointer {
                Divider()
                parallaxSection(followsPointer)
            }
            Divider()
            outputSection
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Only this export changes. The wallpaper on your desktop keeps its properties and edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SceneUserPropertiesView(wallpaper: model.wallpaper, scopes: [model.session.scope])
        }
        .padding()
    }

    /// WE's name for a quality button.
    static func label(_ mode: AndroidExportOptions.Mode) -> LocalizedStringKey {
        switch mode {
        case .highQuality: return "High Quality"
        case .balanced: return "Balanced"
        case .preRendered: return "High Performance"
        }
    }

    private static func pixels(_ size: SIMD2<Int>) -> String {
        let number = IntegerFormatStyle<Int>.number.grouping(.never)
        return "\(size.x.formatted(number)) × \(size.y.formatted(number))"
    }

    // MARK: Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.headline)
            AndroidDeviceComboBox(selection: model.device, onChoose: { model.choose($0) })
            if model.device == nil { customFields }
            Text("\(Self.pixels(model.screenPixels)) pixels · \(AndroidCustomSize.aspectText(model.screenPixels))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if model.device?.kind == .tablet {
                Picker("Orientation", selection: Binding(get: { model.isLandscape }, set: { model.setLandscape($0) })) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Make the wallpaper for the tablet held upright or sideways")
            }
            Toggle("Show Status Bar Guide", isOn: $model.showsStatusBarGuide)
                .help("Show where Android draws the status bar over the wallpaper")
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Width", text: Binding(get: { model.customWidth }, set: { model.setCustom(width: $0, height: model.customHeight) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                    .accessibilityLabel(Text("Width"))
                Text(verbatim: "×")
                    .foregroundStyle(.secondary)
                TextField("Height", text: Binding(get: { model.customHeight }, set: { model.setCustom(width: model.customWidth, height: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                    .accessibilityLabel(Text("Height"))
                Text("pixels")
                    .foregroundStyle(.secondary)
            }
            if let issue = model.customIssue {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Crop and pointer

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Zoom")
                .font(.headline)
            Slider(value: Binding(get: { model.zoom }, set: { model.zoom = $0 }), in: 1...LivePhotoCrop.maximumZoom) {
                Text("Zoom")
            } minimumValueLabel: {
                Text(verbatim: "1×")
            } maximumValueLabel: {
                Text(verbatim: "3×")
            }
            Text("Drag the preview to move the picture.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func parallaxSection(_ followsPointer: Bool) -> some View {
        if followsPointer {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parallax Position")
                    .font(.headline)
                HStack(alignment: .bottom, spacing: 12) {
                    LivePhotoParallaxPad(position: model.parallaxPosition, aspect: model.aspect,
                                         onChange: { model.setParallaxPosition($0) })
                        .help("Drag the dot to where the pointer rests over the wallpaper")
                    Button("Reset to Center") { model.setParallaxPosition(LivePhotoParallax.centre) }
                        .glassButtonStyle()
                        .disabled(model.parallaxPosition == LivePhotoParallax.centre)
                        .help("Put the pointer back in the middle of the wallpaper")
                }
                Text("The preview and the video show the parallax as if the pointer rested here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Parallax Position: this wallpaper doesn't follow the pointer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)
            Picker("Output", selection: Binding(get: { model.isPreRendered }, set: { preRendered in
                model.chooseMode(preRendered ? .preRendered : .balanced)
            })) {
                Text("Pre-Rendered").tag(true)
                Text("Dynamic").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Dynamic runs live on the phone, with its clock, audio and properties; Pre-Rendered is a fixed video")
            Text(model.isPreRendered
                 ? "Pre-Rendered: a fixed video loop of this version, framed as the preview shows it."
                 : "Dynamic: runs live on the phone. Clocks tick, audio-reactive layers follow the phone's sound, and the wallpaper's properties can be changed there.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if model.isPreRendered { videoSettings } else { dynamicSettings }
        }
    }

    @ViewBuilder
    private var videoSettings: some View {
        Picker("Video Size", selection: Binding(get: { model.videoSize }, set: { model.setVideoSize($0) })) {
            ForEach(AndroidVideoSize.allCases) { Text($0.title).tag($0) }
        }
        Picker("FPS", selection: $model.options.frameRate) {
            ForEach(AndroidExportOptions.frameRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        Stepper(value: Binding(get: { model.seconds }, set: { model.setSeconds($0) }), in: AndroidExportEditorModel.lengths, step: 5) {
            Text("Length: \(Duration.seconds(model.seconds).formatted(.units(allowed: [.seconds], width: .abbreviated)))")
        }
        let rate = (Double(model.bitRate) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        Text(verbatim: "\(Self.pixels(model.outputPixels)), \(model.options.frameRate) FPS, H.264, \(rate) Mbit/s")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        Text("Pre-rendering a scene wallpaper can drastically improve performance, but dynamic elements like clocks or interactive touch events will not work.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var dynamicSettings: some View {
        Picker("Quality", selection: Binding(get: { model.options.mode }, set: { model.chooseMode($0) })) {
            Text(Self.label(.highQuality)).tag(AndroidExportOptions.Mode.highQuality)
            Text(Self.label(.balanced)).tag(AndroidExportOptions.Mode.balanced)
        }
        Toggle("Pixel art optimization", isOn: $model.options.pixelArt)
        Picker("Texture Reduction", selection: $model.options.textureReduction) {
            Text("Highest Quality - (Don't reduce texture resolution)").tag(AndroidExportOptions.TextureReduction.original)
            Text("Better Performance - (Reduce textures to half their resolution)").tag(AndroidExportOptions.TextureReduction.half)
            Text("High Performance - (Reduce texture resolution by 4)").tag(AndroidExportOptions.TextureReduction.quarter)
        }
        .disabled(model.options.pixelArt)
        Label("Your layer edits are baked into the package's scene.json, and the property values you set become its project.json defaults, so the phone starts with them. The phone renders the scene itself, so the crop and the parallax position don't apply.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Android Export mode's right-hand panel: the selected layer's adjustments, on the mode's
/// isolated store, and the export's progress and results. The settings and the exports are in the
/// Export Settings sheet (the toolbar's Export Settings button).
struct AndroidExportLayerPanel<Layer: View>: View {
    @ObservedObject var model: AndroidExportEditorModel
    @ViewBuilder let layer: () -> Layer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let queue = model.queue {
                    AndroidEditorExportProgress(queue: queue, model: model)
                    Divider()
                }
                if let queue = model.batchQueue {
                    AndroidEditorBatchProgress(queue: queue, model: model)
                    Divider()
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ExportLayerAdjustments(isVideo: model.isVideo, layer: layer)
            }
            .padding()
        }
    }
}

/// The export's progress, then what it made.
private struct AndroidEditorExportProgress: View {
    @ObservedObject var queue: AndroidExportQueue
    @ObservedObject var model: AndroidExportEditorModel

    var body: some View {
        if queue.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: queue.progress) {
                    Text("Converting wallpaper")
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        } else if let batch = model.batch, !batch.outputs.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack { outputButtons(batch) }
                VStack(alignment: .leading) { outputButtons(batch) }
            }
        }
    }

    @ViewBuilder private func outputButtons(_ batch: AndroidExportBatch) -> some View {
        Button("Show in Finder") { model.showInFinder() }
            .glassButtonStyle()
        if !batch.outputs.isEmpty {
            Button {
                AndroidWiFiShareWindow.show()
            } label: {
                Label("Send Again", systemImage: "wifi")
            }
            .glassButtonStyle()
            .help("Serve the exported .mpkg over Wi-Fi again")
        }
    }
}

/// "Export More with These Settings…"'s batch, once the library's export selection started it:
/// its progress and each package's, then Send over Wi-Fi.
private struct AndroidEditorBatchProgress: View {
    @ObservedObject var queue: AndroidExportQueue
    @ObservedObject var model: AndroidExportEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export More with These Settings")
                .font(.headline)
            ExportBatchProgressView(
                progress: queue.progress, isRunning: queue.isRunning,
                rows: queue.entries.map { ExportBatchRow(id: $0.id, title: $0.item.wallpaper.project.displayTitle, status: $0.status, progress: $0.progress) },
                skipped: queue.skipped.map { (title: $0.title, reason: $0.reason) },
                accessory: { _ in EmptyView() })
                .frame(height: 220)
            if queue.isRunning {
                Button("Cancel", role: .cancel) { model.cancelBatch() }
                    .glassButtonStyle()
            } else {
                Text("The packages are in the Android exports list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        AndroidWiFiShareWindow.show()
                    } label: {
                        Label("Send over Wi-Fi…", systemImage: "wifi")
                    }
                    .glassButtonStyle()
                    .disabled(queue.batch.outputs.isEmpty)
                    Button("Done") { model.dismissBatch() }
                        .glassButtonStyle()
                }
            }
        }
    }
}

/// The Export Settings as a sheet: before an export (Cancel, and the export as the confirm
/// button), or opened from the toolbar (Done, both exports and Export More).
struct AndroidExportSettingsSheetView: View {
    @ObservedObject var model: AndroidExportEditorModel
    let sheet: AndroidEditorSheet

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Settings")
                    .font(.title2.bold())
                Text(verbatim: model.wallpaper.project.displayTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])
            AndroidExportSettingsView(model: model)
            Divider()
            VStack(spacing: 0) { footer }
                .padding()
        }
        .frame(width: 440, height: 680)
    }

    @ViewBuilder private var footer: some View {
        if sheet == .settings {
            Button {
                model.chooseMoreAfterSheet()
            } label: {
                Label("Export More with These Settings…", systemImage: "square.stack.3d.down.right")
            }
            .glassButtonStyle()
            .disabled(model.isBatchRunning)
            .help("Pick more wallpapers from your library and export them as .mpkg packages with this device, output, quality and frame rate")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        HStack {
            Spacer()
            switch sheet {
            case .settings:
                Button("Save .mpkg…") { model.confirm(.save) }
                    .glassButtonStyle()
                Button {
                    model.confirm(.wifi)
                } label: {
                    Label("Send over Wi-Fi…", systemImage: "wifi")
                }
                .glassButtonStyle()
                Button("Done") { model.sheet = nil }
                    .glassButtonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            case .confirm(let action):
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .glassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.confirm(action)
                } label: {
                    switch action {
                    case .wifi: Label("Send over Wi-Fi…", systemImage: "wifi")
                    case .save: Text("Save .mpkg…")
                    }
                }
                .glassButtonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Presents the Android Export Settings sheet while `model` asks for it;
/// `onClose` runs when the settings sheet closes. Without a model (another mode) it does nothing.
struct AndroidExportSheetHost: ViewModifier {
    let model: AndroidExportEditorModel?
    let onClose: () -> Void

    func body(content: Content) -> some View {
        if let model {
            content.modifier(AndroidExportSheetPresenter(model: model, onClose: onClose))
        } else {
            content
        }
    }
}

private struct AndroidExportSheetPresenter: ViewModifier {
    @ObservedObject var model: AndroidExportEditorModel
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.sheet, onDismiss: {
                onClose()
                model.sheetDidClose()
            }) { sheet in
                AndroidExportSettingsSheetView(model: model, sheet: sheet)
            }
    }
}
