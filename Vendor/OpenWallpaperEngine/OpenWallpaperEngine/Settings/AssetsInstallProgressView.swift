import SwiftUI

/// The assets install as it runs: download progress, the copy, or why it failed; when idle, only
/// the last update check that found nothing to download. Used by Settings › Assets and the setup assistant.
struct AssetsInstallProgressView: View {
    @ObservedObject var assets: WallpaperEngineAssetsService
    /// Where "Log In" goes after a failure for want of a Steam login; the Workshop tab by default.
    var logIn: () -> Void = { AppDelegate.shared.openSteamLogin() }

    var body: some View {
        switch assets.phase {
        case .idle:
            if let notice = assets.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .downloading(let text, let progress):
            VStack(alignment: .leading, spacing: 6) {
                if let progress {
                    ProgressView(value: progress.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(text)
                    Spacer()
                    if let done = progress?.downloadedBytes, let total = progress?.totalBytes, total > 0 {
                        let doneText: String = done.formatted(.byteCount(style: .file))
                        let totalText: String = total.formatted(.byteCount(style: .file))
                        Text("\(doneText) of \(totalText)", comment: "Download progress: bytes done of bytes in total")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .copying:
            HStack {
                ProgressView().controlSize(.small)
                Text("Copying assets…")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if case .notLoggedIn = assets.lastFailure {
                    Button("Log In…", action: logIn)
                }
            }
        }
    }
}
