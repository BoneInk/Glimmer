import SwiftUI

/// "Updated to X": the notes of every version since the one the user last saw (`WhatsNew`).
struct WhatsNewView: View {
    let version: String
    let entries: [WhatsNew.Entry]
    let onDismiss: () -> Void

    private static func releaseURL(_ version: String) -> URL {
        URL(string: "https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases/tag/v\(version)")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Updated to \(version)", comment: "What's New title; %@ is a version such as 1.0.1")
                    .font(.title2.bold())
            } icon: {
                Image(systemName: "sparkles")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entries, id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            if entries.count > 1 {
                                Text(verbatim: entry.version).font(.headline)
                            }
                            if let notes = entry.notes {
                                Text(Self.formatted(notes))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No release notes are available offline for this version.")
                                    .foregroundStyle(.secondary)
                            }
                            Link("Full changelog", destination: Self.releaseURL(entry.version))
                                .font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("You can turn release notes off in Settings › Updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }

    /// Markdown from the changelog (bold, links, code), shown line by line.
    private static func formatted(_ notes: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Plain text when the notes aren't valid Markdown (optional formatting).
        return (try? AttributedString(markdown: notes, options: options)) ?? AttributedString(notes)
    }
}
