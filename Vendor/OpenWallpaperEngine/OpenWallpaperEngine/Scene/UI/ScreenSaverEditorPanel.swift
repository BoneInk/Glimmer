import SwiftUI

/// The Screen Saver mode's right-hand panel: the note that the screen saver is drawn live, Set as
/// Screen Saver, the selected layer's adjustments and the user properties, all of them the mode's own
/// (`ScreenSaverEditorModel`, `IsolatedSceneEditSession`).
struct ScreenSaverEditorPanel<Layer: View>: View {
    @ObservedObject var model: ScreenSaverEditorModel
    /// The selected layer's adjustments (Scene Edit / Export's own controls, on the isolated store).
    @ViewBuilder let layer: () -> Layer

    init(model: ScreenSaverEditorModel, @ViewBuilder layer: @escaping () -> Layer) {
        self.model = model
        self.layer = layer
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                liveNote
                pickSection
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Layer Adjustments")
                        .font(.headline)
                    Text("Turn layers on or off in the list on the left. The screen saver keeps these choices for this wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    layer()
                }
                Divider()
                Text("Only the screen saver changes. The wallpaper on your desktop keeps its properties and edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SceneUserPropertiesView(wallpaper: model.wallpaper, scopes: [model.session.scope])
            }
            .padding()
        }
    }

    /// Always shown: what the screen saver draws.
    private var liveNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("The screen saver is live", systemImage: "play.circle.fill")
                .font(.subheadline.bold())
            Text("While the screen saver runs, Open Wallpaper Engine draws this version of the wallpaper live: clocks, dates, media info and audio-reactive parts move as they do on the desktop, and its sound stays off.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pickSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.setAsScreenSaver()
            } label: {
                Label("Set as Screen Saver", systemImage: "display")
            }
            .glassButtonStyle(.prominent)
            .help("Make this version of the wallpaper the screen saver")
            if model.isScreenSaver {
                Text("This wallpaper is your screen saver.")
                    .font(.caption)
                HStack {
                    Button("Stop Using as Screen Saver") { model.stopUsingAsScreenSaver() }
                        .help("Go back to making the screen saver from your desktop wallpaper")
                    Button("Open Screen Saver Settings…") { ScreenSaverInstaller.current.openSettings() }
                }
            }
        }
    }
}
