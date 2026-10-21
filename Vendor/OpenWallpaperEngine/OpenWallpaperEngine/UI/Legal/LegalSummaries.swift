import SwiftUI

/// Short summaries of the Terms of Use and the Privacy Policy, for the notice and Settings ›
/// Privacy. The full texts are the documents themselves (`LegalDocument`).
struct LegalSummary: View {
    let document: LegalDocument

    private var points: [LocalizedStringKey] {
        switch document {
        case .termsOfUse:
            return [
                "Open Wallpaper Engine is free, open-source software under the GPL-3.0 licence, provided as is, without warranty.",
                "Workshop features need your own Steam account that owns Wallpaper Engine. Wallpapers belong to their creators; respect their rights and Valve's terms.",
                "Open Wallpaper Engine is not affiliated with Wallpaper Engine, Valve or Steam.",
            ]
        case .privacyPolicy:
            return [
                "Everything stays on your Mac. There are no servers, accounts, analytics or tracking.",
                "The app contacts Valve (Steam and SteamCMD), GitHub (app updates) and, when you install an optional plugin, its publisher. Web wallpapers and URLs you add load their own online content.",
                "Your Steam Web API key and account name stay in your keychain. Your password is never stored.",
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(document.title)
                    .font(.headline)
                Spacer()
                Button("Read Full Text") { LegalDocumentWindow.show(document) }
                    .buttonStyle(.link)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                    Text(point).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
