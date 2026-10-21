import SwiftUI

/// The Screen Saver mode's preview: the mode's private instance live (`IsolatedSceneView`), as the
/// screen saver draws it, in a frame of the main display's shape, filled as the saver fills it.
struct ScreenSaverEditorPreview: View {
    @ObservedObject var model: ScreenSaverEditorModel

    private var aspect: Double {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16.0 / 9.0 }
        return frame.width / frame.height
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = LockScreenPreview.frameSize(fitting: geometry.size, aspect: aspect)
            ZStack {
                Color.black
                if !model.session.isEnded {
                    IsolatedSceneView(session: model.session)
                        .allowsHitTesting(false)
                }
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
