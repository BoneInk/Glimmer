import SwiftUI

/// A dev build's thread guard count in the main window's corner. It never takes focus or blocks
/// the window; clicking it opens the list in Settings › Diagnostics.
struct ThreadGuardIndicator: View {
    @ObservedObject private var monitor = ThreadGuardMonitor.shared

    var body: some View {
        if monitor.total > 0 {
            Button {
                AppDelegate.shared.openSettings(.diagnostics, anchor: SettingsAnchor.threadGuards)
            } label: {
                Label("Thread guard: \(monitor.total) violations — see Diagnostics",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
        }
    }
}
