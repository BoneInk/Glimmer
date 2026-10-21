import SwiftUI

/// The Screen Saver mode's panel for a video wallpaper (`VideoScreenSaverModel`): the video is the
/// screen saver as it is, so the panel only sets it, or goes back to the desktop's wallpaper.
struct VideoScreenSaverPanel: View {
    @ObservedObject var model: VideoScreenSaverModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("The screen saver plays this video", systemImage: "film")
                    .font(.headline)
                Text("The screen saver plays this video live, as your desktop shows it, without sound. Nothing is recorded or copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isScreenSaver {
                    Text("This video is your screen saver.")
                        .font(.caption)
                    HStack {
                        Button("Stop Using as Screen Saver") { model.stopUsingAsScreenSaver() }
                            .glassButtonStyle()
                            .help("Go back to making the screen saver from your desktop wallpaper")
                        Button("Open Screen Saver Settings…") { ScreenSaverInstaller.current.openSettings() }
                            .glassButtonStyle()
                    }
                } else {
                    Button {
                        model.setAsScreenSaver()
                    } label: {
                        Label("Set as Screen Saver", systemImage: "play.rectangle")
                    }
                    .glassButtonStyle(.prominent)
                    .help("Make this video the screen saver")
                }
            }
            .padding()
        }
    }
}

/// The Screen Saver mode's preview for a video wallpaper: the video looping in a frame of the main
/// display's shape, filled as the saver fills it.
struct VideoScreenSaverPreview: View {
    let wallpaper: WEWallpaper

    private var aspect: Double {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16.0 / 9.0 }
        return frame.width / frame.height
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = LockScreenPreview.frameSize(fitting: geometry.size, aspect: aspect)
            ZStack {
                Color.black
                LoopingVideoFileView(url: wallpaper.mediaURL)
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.6), lineWidth: 3)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityLabel(Text("Screen saver preview"))
        }
        .padding(24)
    }
}
