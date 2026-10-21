import SwiftUI

/// An ⓘ that reads as clickable and behaves that way: click for a selectable popover, hover for
/// the standard tooltip.
public struct InfoTip: View {
    private let text: String
    @State private var isPresented = false
    @Environment(\.appAccentColor) private var accentColor

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(isPresented ? accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}
