import SwiftUI

/// The SteamCMD install from Valve: its progress while it runs, otherwise the Install SteamCMD
/// button, which retries after a failure and shows why it failed. Used by the Workshop page, the
/// Assets settings and the first-run sheet (`compact`).
struct SteamCmdSetupView: View {
    @ObservedObject var installer: SteamCmdInstaller
    /// Only the progress line, and nothing when idle.
    var compact = false

    var body: some View {
        if installer.isBusy {
            progress
        } else if !compact {
            VStack(spacing: 8) {
                Button {
                    installer.install()
                } label: {
                    Label(isRetry ? "Try Again" : "Install SteamCMD", systemImage: "arrow.down.circle")
                }
                .glassButtonStyle(.prominent)
                .help("Downloads SteamCMD from Valve")
                if case .failed(let message) = installer.phase {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var isRetry: Bool {
        if case .failed = installer.phase { return true }
        return false
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setting up SteamCMD from Valve for Workshop downloads…")
                .font(compact ? .caption : .callout)
            HStack {
                if case .downloading(let fraction?) = installer.phase {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !compact {
                    Button("Cancel") { installer.cancel() }
                }
            }
            Text(stepText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
    }

    private var stepText: LocalizedStringKey {
        switch installer.phase {
        case .downloading(let fraction?):
            let percent: String = fraction.formatted(.percent.precision(.fractionLength(0)))
            return "Downloading from Valve… \(percent)"
        case .extracting: return "Extracting…"
        case .updating: return "SteamCMD is updating itself…"
        default: return "Downloading from Valve…"
        }
    }
}
