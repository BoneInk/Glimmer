import SwiftUI
import OWESceneEditing

/// WE's image importer ("Import Image …"): the texture's format, Pixel Art Optimization, No Mip
/// Maps, Clamp UVs, Crop transparent area with its padding, a normal map, and for several images
/// Import as image sequence with its frame duration. WE's defaults keep a PNG or JPEG as it is.
struct ImportOptionsSheet: View {
    let pending: PendingImageImport
    let actions: LayerActions
    @Environment(\.dismiss) private var dismiss
    @State private var options = TextureImportOptions()
    @State private var asSequence = false

    private var names: [String] { pending.urls.map(\.lastPathComponent) }
    private var isAnimated: Bool { pending.urls.contains { $0.pathExtension.lowercased() == "gif" } || asSequence }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pending.urls.count == 1 ? L("Import Image “\(names[0])”") : L("Import Images"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(14)
            Divider()
            Form {
                if pending.urls.count > 1 {
                    Section {
                        Toggle(L("Import as image sequence"), isOn: $asSequence)
                        if asSequence {
                            LabeledContent(L("Frame duration")) {
                                HStack(spacing: 4) {
                                    TextField("", value: $options.frameDuration, format: .number.precision(.fractionLength(0...3)))
                                        .frame(width: 70)
                                        .multilineTextAlignment(.trailing)
                                    Text(L("seconds")).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text(names.prefix(5).joined(separator: ", ") + (names.count > 5 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Section {
                    Picker(L("Format"), selection: $options.format) {
                        ForEach(TextureImportOptions.Format.allCases, id: \.self) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .disabled(isAnimated)
                    Toggle(L("Pixel Art Optimization (Disable Bilinear Filtering)"), isOn: $options.pixelArt)
                    Toggle(L("No Mip Maps"), isOn: $options.noMipmaps)
                        .disabled(isAnimated)
                    Toggle(L("Clamp UVs"), isOn: $options.clampUVs)
                }
                if !isAnimated {
                    Section {
                        Toggle(L("Crop transparent area"), isOn: $options.cropTransparency)
                        if options.cropTransparency {
                            Stepper(value: $options.cropPadding, in: 0...512) {
                                LabeledContent(L("Padding"), value: options.cropPadding.formatted())
                            }
                        }
                    } footer: {
                        if options.cropTransparency {
                            Text(L("The transparent area is cropped and the layer made that much smaller, which draws faster."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent(L("Normal Map")) {
                        HStack {
                            Text(options.normalMap?.lastPathComponent ?? L("None"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if options.normalMap != nil {
                                Button(L("Remove Normal Map")) { options.normalMap = nil }
                            }
                            Button(L("Select Normal Map…")) {
                                options.normalMap = EditorFilePicker.choose(.mask).first ?? options.normalMap
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Import")) {
                    dismiss()
                    actions.importImages(pending.urls, options: options, asSequence: asSequence, at: pending.point)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420)
    }
}

extension TextureImportOptions.Format {
    /// WE's importer's names for its formats.
    var title: String {
        switch self {
        case .rgba8888: return L("High Quality - Uncompressed (RGBA 8888)")
        case .dxt5: return L("Good Performance - Minor Compression (DXT5)")
        case .dxt1: return L("High Performance - Medium Compression (DXT1)")
        case .rg88: return L("High Quality - Uncompressed Dual Channel (RG 88)")
        case .r8: return L("High Quality - Uncompressed Single Channel (R 8)")
        }
    }
}
