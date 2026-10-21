import SwiftUI

/// Shown by the effect and particle browsers while WE's assets aren't installed: they list WE's
/// effects and particle systems, so there is nothing to add yet. Opens the app's assets setup.
struct EditorAssetsPrompt: View {
    let message: String
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button(L("Install Wallpaper Engine Assets…"), action: openSetup)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
