import AppKit
import SwiftUI

/// Settings › Plugins › Chromium web engine: install, update or remove the optional CEF build the
/// app pins. Nothing is installed until the user asks.
struct ChromiumEngineSection: View {
    /// The Plugins page's, which the Screen Saver section installs through too.
    @ObservedObject var installer: ChromiumEngineInstaller
    @State private var removeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chromium web engine")
                Spacer()
                status
            }
            Text("An optional Chromium engine for web wallpapers, downloaded on demand from the official CEF builds and checked against the version this app expects. It runs in its own process.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A Chromium page costs far more memory than WebKit's (`WebEngineRouting`).
            Text("Used only for wallpapers that need it")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let version = installer.installedVersion {
                row("Version", Text(verbatim: version).font(.caption.monospaced()))
            }
            if let size = installer.installedSize {
                row("Size", Text(size.formatted(.byteCount(style: .file))))
            } else if let pin = installer.pin {
                row("Download size", Text(pin.downloadSize.formatted(.byteCount(style: .file))))
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
        case .verifying:
            ProgressView { Text("Verifying…") }
        case .unpacking:
            ProgressView { Text("Unpacking…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle, .installed:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        if !installer.isBusy {
            HStack {
                if installer.pin == nil {
                    Text("Not available for this Mac.").foregroundStyle(.secondary)
                } else if installer.needsUpdate {
                    Button("Update") { installer.update() }
                        .help("Downloads the Chromium engine version this release of the app uses and removes older ones.")
                } else if !installer.isCurrent {
                    Button("Install") { installer.install() }
                        .help("Downloads the Chromium engine from the official CEF builds.")
                }
                if installer.installedSize != nil {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([installer.activeInstall ?? installer.root])
                    }
                    Button("Remove", role: .destructive) { remove() }
                        .help("Moves the Chromium engine and its data to the Trash.")
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
            OWELog.error(.web, "Can't move the Chromium engine to the Trash: \(error)")
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
