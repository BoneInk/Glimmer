import SwiftUI

/// Settings › Performance › Caches: the space OWE's caches take, and Clear Caches
/// (`CacheMaintenance`).
struct CachesSection: View {
    @StateObject private var model = CachesSectionModel()
    @State private var confirmsClear = false

    var body: some View {
        Section {
            HStack {
                Text("Cache Size")
                Spacer()
                if let bytes = model.totalBytes {
                    Text(bytes, format: .byteCount(style: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button {
                    confirmsClear = true
                } label: {
                    Text("Clear Caches…").frame(minWidth: 100)
                }
                .disabled(model.isClearing)
                .help("Deletes the caches now, except what the wallpapers on screen use. Wallpapers load slower once while their caches are made again.")
            }
            .help("The space Open Wallpaper Engine's caches take: optimised textures, loading pictures, editor previews, video copies, translated shaders and the GPU shader cache macOS keeps for the app. Entries unused for 60 days are deleted automatically.")
        } header: {
            Label("Caches", systemImage: "internaldrive")
        }
        .settingsAnchor(SettingsAnchor.caches)
        .onAppear { model.refresh() }
        .confirmationDialog("Clear Caches?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Caches", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wallpapers will load slower once while Open Wallpaper Engine makes their caches again. What the wallpapers on screen use is kept. The GPU shader cache is cleared the next time the app starts.")
        }
    }
}
