import AppKit
import SwiftUI

/// Settings › Plugins › Depth Map Generation: install, update or remove the depth model the app
/// pins (`DepthMapModelPin`). Nothing is installed until the user asks.
struct DepthMapPluginSection: View {
    @StateObject private var installer = DepthMapPluginInstaller()
    @State private var removeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Depth Map Generation")
                Spacer()
                status
            }
            Text("Generates depth maps for depth parallax in Scene Edit / Export and the Wallpaper Editor, on this Mac, with Depth Anything V2 Small (Apache License 2.0). The model is downloaded on demand from Apple’s Core ML release on Hugging Face and checked against the version this app expects.",
                 tableName: "DepthMaps", comment: "Settings › Plugins: what Depth Map Generation is")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Loaded only while generating, and released after five minutes without use.",
                 tableName: "DepthMaps", comment: "Settings › Plugins: when the depth model takes memory")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let version = installer.installedVersion {
                row("Version", Text(verbatim: version).font(.caption.monospaced()))
            }
            if let size = installer.installedSize {
                row("Size", Text(size.formatted(.byteCount(style: .file))))
            } else {
                row("Download size", Text(installer.pin.downloadSize.formatted(.byteCount(style: .file))))
            }
            progress
            buttons
            if let removeError {
                Label(removeError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .onAppear { installer.refresh() }
    }

    @ViewBuilder private var status: some View {
        if installer.isCurrent {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if installer.needsUpdate {
            Label("Update available", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
        } else {
            Text("Not installed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var progress: some View {
        switch installer.phase {
        case .downloading(let fraction):
            HStack {
                if let fraction {
                    ProgressView(value: fraction) { Text("Downloading…") }
                } else {
                    ProgressView { Text("Downloading…") }
                }
                Button("Cancel") { installer.cancel() }
            }
        case .compiling:
            ProgressView { Text("Preparing the model for this Mac…", tableName: "DepthMaps", comment: "Settings › Plugins: the depth model is being compiled") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle, .installed:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        if !installer.isBusy {
            HStack {
                if installer.needsUpdate {
                    Button("Update") { installer.update() }
                        .help(Text("Downloads the depth model this release of the app uses and removes older ones.",
                                   tableName: "DepthMaps", comment: "Settings › Plugins: Update button help"))
                } else if !installer.isCurrent {
                    Button("Install") { installer.install() }
                        .help(Text("Downloads the depth model from Apple’s Core ML release on Hugging Face.",
                                   tableName: "DepthMaps", comment: "Settings › Plugins: Install button help"))
                }
                if installer.installedSize != nil {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([installer.activeInstall ?? installer.root])
                    }
                    Button("Remove", role: .destructive) { remove() }
                        .help(Text("Moves the depth model to the Trash. Depth maps already made keep working.",
                                   tableName: "DepthMaps", comment: "Settings › Plugins: Remove button help"))
                }
                Spacer()
            }
        }
    }

    private func remove() {
        do {
            try installer.remove()
            removeError = nil
        } catch {
            OWELog.error(.app, "Can't move the depth model to the Trash: \(error)")
            removeError = error.localizedDescription
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            value
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// The depth model's credit and licence, for the About window.
struct DepthMapPluginCredit: View {
    var body: some View {
        Link(destination: DepthMapModelPin.pageURL) {
            Text("Depth Anything V2 Small, Core ML by Apple: Apache License 2.0", tableName: "DepthMaps",
                 comment: "About window: credit and licence of the depth model the Depth Map Generation plugin downloads")
        }
    }
}
