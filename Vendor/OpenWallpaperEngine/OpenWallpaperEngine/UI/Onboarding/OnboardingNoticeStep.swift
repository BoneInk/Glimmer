import SwiftUI

/// The setup assistant's first step: short summaries of the Terms of Use and the Privacy Policy,
/// links to the full texts, and "I have read…". Continue enables once it's ticked.
struct OnboardingNoticeStep: View {
    @Binding var isRead: Bool
    /// Shown on its own after an update, because the documents are new or changed.
    let isUpdate: Bool

    var body: some View {
        VStack(spacing: 18) {
            OnboardingHeading(systemImage: "doc.text.fill",
                              title: "Terms of Use and Privacy Policy",
                              subtitle: isUpdate
                                ? "The Terms of Use and Privacy Policy are new or have changed. Please read them."
                                : "Before you start, please read how Open Wallpaper Engine may be used and how it treats your data.")
            ForEach(LegalDocument.allCases) { document in
                OnboardingCard {
                    LegalSummary(document: document)
                }
            }
            OnboardingCard {
                Toggle("I have read the Terms of Use and Privacy Policy", isOn: $isRead)
                    .toggleStyle(.checkbox)
                Text("You can read them again at any time in Settings › Privacy or from the Help menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
