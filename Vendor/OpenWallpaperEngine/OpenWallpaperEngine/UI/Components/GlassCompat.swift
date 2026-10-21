import SwiftUI

/// Liquid Glass where macOS 26 has it, today's look before. Every glass-only API the app uses goes
/// through here, so views don't repeat availability checks inside their modifier chains.

/// How a button looks: the window's main action, or an ordinary one.
enum GlassButtonKind {
    /// Glass tinted with the accent colour; `.borderedProminent` before macOS 26.
    case prominent
    /// Clear glass; `.bordered` before macOS 26.
    case standard
}

extension View {
    /// A glass button on macOS 26; a bordered one before.
    @ViewBuilder
    func glassButtonStyle(_ kind: GlassButtonKind = .standard) -> some View {
        if #available(macOS 26, *) {
            switch kind {
            case .prominent: buttonStyle(.glassProminent)
            case .standard: buttonStyle(.glass)
            }
        } else {
            switch kind {
            case .prominent: buttonStyle(.borderedProminent)
            case .standard: buttonStyle(.bordered)
            }
        }
    }

    /// For a button that sits on a glass background: borderless on macOS 26 (no glass on glass),
    /// bordered before.
    @ViewBuilder
    func borderlessOnGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.borderless)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Glass in `shape` on macOS 26; `fallback` applied to the view before.
    ///
    /// `padding` insets the content inside the glass only, so the fallback keeps today's spacing.
    /// `interactive` makes the glass react to the pointer, for a control drawn by hand.
    @ViewBuilder
    func glassBackground<S: Shape, Fallback: View>(
        in shape: S,
        padding: EdgeInsets = EdgeInsets(),
        interactive: Bool = false,
        @ViewBuilder fallback: (Self) -> Fallback
    ) -> some View {
        if #available(macOS 26, *) {
            self.padding(padding)
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            fallback(self)
        }
    }
}

/// Groups nearby glass so it samples the backdrop once and blends as one piece; a plain container
/// before macOS 26.
struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
