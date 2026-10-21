import SwiftUI

/// Shows whether a Steam Web API key is stored (masked) with Replace and Remove, or a field to
/// enter one. A new key is checked with Steam before it is saved.
struct SteamWebAPIKeyView: View {
    @StateObject private var viewModel = SteamWebAPIKeyViewModel()
    var onSaved: () -> Void = {}

    private static let keyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isEditing {
                entry
            } else if let masked = viewModel.maskedKey {
                HStack {
                    Label("Key set", systemImage: "key.fill")
                    Text(masked)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace…") { viewModel.beginReplacing() }
                    Button("Remove", role: .destructive) { viewModel.remove() }
                }
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                // `Link` opens the page in the default browser.
                Link(destination: Self.keyPage) {
                    Label("Get your key on Steam", systemImage: "arrow.up.right.square")
                }
                .help(Self.keyPage.absoluteString)
                Text("On Steam's page, enter any domain name, e.g. \"localhost\".",
                     comment: "Steam's API key page asks for a domain name")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
        .frame(maxWidth: 460)
        .onAppear { viewModel.reload() }
    }

    private var entry: some View {
        HStack {
            SecureField("Steam Web API Key", text: $viewModel.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if viewModel.isValidating {
                ProgressView().controlSize(.small)
            }
            Button("Check & Save", action: save)
                .glassButtonStyle(.prominent)
                .disabled(!viewModel.canSubmit)
            if viewModel.isKeySet {
                Button("Cancel") { viewModel.cancelReplacing() }
            }
        }
    }

    private func save() {
        Task {
            if await viewModel.submit() { onSaved() }
        }
    }
}
