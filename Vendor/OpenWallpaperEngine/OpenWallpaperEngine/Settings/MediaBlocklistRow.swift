import AppKit
import SwiftUI

/// Settings › Optimizations › Audio › Media blocklist: WE's `settings_media_blocklist_*` dialog.
/// It names the app of the current media session with Block, and lists the blocked apps, each
/// with Unblock. A blocked app's sessions reach no wallpaper (`MacMediaSessionSource`).
struct MediaBlocklistRow: View {
    @Binding var blocklist: [String]
    let source: MacMediaSessionSource
    @State private var current: String?
    @State private var subscription: Int?

    var body: some View {
        DisclosureGroup("Media blocklist") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current media session:")
                    if let current {
                        appLabel(current)
                    } else {
                        Text("No media playing.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Block") {
                    guard let current, !blocklist.contains(current) else { return }
                    blocklist.append(current)
                }
                .disabled(current == nil || current.map(blocklist.contains) == true)
            }
            ForEach(blocklist, id: \.self) { bundleIdentifier in
                HStack {
                    appLabel(bundleIdentifier)
                    Spacer()
                    Button("Unblock") { blocklist.removeAll { $0 == bundleIdentifier } }
                }
            }
        }
        .help("Wallpapers don't see what a blocked app plays: no title, artist or album cover.")
        .onAppear {
            // Subscribing keeps the source reading the session while the page shows. Updates arrive
            // with the source's lock held, so the player is read afterwards, on the main actor.
            subscription = source.subscribe { _ in
                Task { @MainActor in current = source.currentSessionPlayer }
            }
        }
        .onDisappear {
            if let subscription { source.unsubscribe(subscription) }
            subscription = nil
        }
    }

    /// The app's icon and name, with its bundle id below; the bundle id alone for an app that
    /// isn't installed.
    private func appLabel(_ bundleIdentifier: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        return HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier)
                    .lineLimit(1)
                if url != nil {
                    Text(verbatim: bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
