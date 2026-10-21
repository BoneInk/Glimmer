import AppKit
import SwiftUI

/// A quiet, appearance-adaptive backdrop for secondary windows and sheets.
/// Artwork and media belong inside their own content surfaces.
struct PopupSurfaceBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}
