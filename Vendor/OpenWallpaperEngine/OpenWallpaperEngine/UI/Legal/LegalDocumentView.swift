import AppKit
import OWEInspectorKit
import SwiftUI

/// A bundled legal document, read offline: its Markdown drawn block by block (headings,
/// paragraphs, lists, the summary box and tables), with a link to the online copy.
struct LegalDocumentView: View {
    @Environment(\.appAccentColor) private var accentColor
    let document: LegalDocument

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let text = document.text() {
                        ForEach(Array(LegalMarkdown.blocks(of: text).enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    } else {
                        Text("This document isn't included in this copy of the app. Read it online instead.")
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Link(destination: document.onlineURL) {
                    Label("Open on the Website", systemImage: "arrow.up.right.square")
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private func view(for block: LegalMarkdown.Block) -> some View {
        if case .quote(let blocks) = block {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                    leaf(inner)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else {
            leaf(block)
        }
    }

    /// A block outside a quote (the documents don't nest quotes).
    @ViewBuilder
    private func leaf(_ block: LegalMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(Self.inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote:
            EmptyView()
        case .table(let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .font(index == 0 ? .callout.bold() : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
        case .rule:
            Divider()
        }
    }

    /// Bold, italics, code and links, as Markdown inline syntax.
    private static func inline(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(text)
        }
    }
}

/// The legal documents' windows, one per document.
@MainActor
enum LegalDocumentWindow {
    private static var windows: [LegalDocument: NSWindow] = [:]

    static func show(_ document: LegalDocument) {
        if let window = windows[document] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: document.title)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LegalDocumentView(document: document).appAccentTint())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[document] = window
    }
}
