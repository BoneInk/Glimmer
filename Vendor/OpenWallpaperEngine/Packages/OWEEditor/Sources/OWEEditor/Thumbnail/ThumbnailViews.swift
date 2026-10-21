import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The thumbnail's text, from its own catalog (`Resources/Thumbnail.xcstrings`).
let TH = EditorText(table: "Thumbnail")

extension GIFRecordingFormat {
    /// As WE's snapshot tool lists a format: "256×256, 25 FPS, 2 seconds, dithering enabled".
    var title: String {
        let resolution = "\(side)×\(side)"
        let rate = framesPerSecond.formatted()
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.second]
        formatter.unitsStyle = .full
        let length = formatter.string(from: TimeInterval(seconds)) ?? seconds.formatted()
        return dithered ? TH("\(resolution), \(rate) FPS, \(length), dithering enabled")
            : TH("\(resolution), \(rate) FPS, \(length), dithering disabled")
    }
}

/// The toolbar's Thumbnail menu: Take Snapshot, Record GIF and its format, and going back to the
/// wallpaper's own thumbnail.
struct ThumbnailMenu: View {
    @ObservedObject var thumbnail: EditorThumbnail

    var body: some View {
        Menu {
            Button(TH("Take Snapshot")) { Task { await thumbnail.takeSnapshot() } }
            Button(TH("Record GIF")) { Task { await thumbnail.recordGIF() } }
            Picker(TH("GIF Format"), selection: $thumbnail.gifFormat) {
                ForEach(GIFRecordingFormat.all) { format in
                    Text(format.title).tag(format)
                }
            }
            if thumbnail.chosen != nil {
                Divider()
                Button(TH("Keep the Original Thumbnail")) { thumbnail.keepOriginal() }
            }
        } label: {
            Label(TH("Thumbnail"), systemImage: "photo.on.rectangle")
        }
        .help(TH("Make the library’s thumbnail from the canvas"))
        .disabled(thumbnail.isBusy)
    }
}

/// While a thumbnail is made, its progress; then the result with Use and Discard.
struct ThumbnailSheet: View {
    @ObservedObject var thumbnail: EditorThumbnail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending = thumbnail.pending {
                Text(TH("New Thumbnail")).font(.headline)
                AnimatedThumbnail(data: pending.data)
                    .frame(width: 256, height: 256)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
                Text(Self.details(pending))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Text(thumbnail.savesInPlace
                     ? TH("File › Save writes it into the wallpaper, and the library shows it.")
                     : TH("Save as New Wallpaper gives the new wallpaper this thumbnail. The original keeps its own."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(TH("Discard"), role: .cancel) { thumbnail.discard() }
                        .keyboardShortcut(.cancelAction)
                    Button(TH("Use")) { thumbnail.use() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                switch thumbnail.phase {
                case .recording(let progress):
                    Text(TH("Recording GIF…")).font(.headline)
                    ProgressView(value: progress)
                case .encoding, .idle:
                    Text(TH("Encoding…")).font(.headline)
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .interactiveDismissDisabled()
    }

    /// "256×256, 812 KB".
    static func details(_ thumbnail: WallpaperThumbnail) -> String {
        let resolution = "\(thumbnail.side)×\(thumbnail.side)"
        let size = ByteCountFormatter.string(fromByteCount: Int64(thumbnail.data.count), countStyle: .file)
        return TH("\(resolution), \(size)")
    }
}

/// A GIF that plays (SwiftUI's `Image` shows only its first frame), or a still.
private struct AnimatedThumbnail: NSViewRepresentable {
    let data: Data

    final class Coordinator {
        var shown: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.shown != data else { return }
        context.coordinator.shown = data
        view.image = NSImage(data: data)
    }
}

/// Presents `ThumbnailSheet` while a thumbnail is made or waits for Use or Discard, and hands a
/// failure to the window's banner.
struct ThumbnailSheetHost: ViewModifier {
    @ObservedObject var thumbnail: EditorThumbnail
    let showProblem: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { thumbnail.isBusy || thumbnail.pending != nil },
                                        set: { if !$0 { thumbnail.discard() } })) {
                ThumbnailSheet(thumbnail: thumbnail)
            }
            .onChange(of: thumbnail.problem) { _, problem in
                guard let problem else { return }
                thumbnail.problem = nil
                showProblem(problem)
            }
    }
}
