import SwiftUI

/// Discrete floating surfaces. Apply after layout and padding so the native
/// material samples the actual bounds, leaving the wallpaper visible in the gaps.
extension View {
    func workshopGlassSurface(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        GlassStyleReader { style in
            self.modifier(WorkspaceGlassSurface(reduceTransparency: style.reduceTransparency,
                cornerRadius: cornerRadius, tint: tint, interactive: interactive))
        }
    }
    func workshopNavigationSurface(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        workshopGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive)
    }
}

/// Routed screens share the wallpaper backdrop at the workspace root. Keeping
/// their normal background clear prevents repeated washes from hiding it.
struct WorkshopAtmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.windowGlassReduceTransparencyOverride) private var reviewReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || reviewReduceTransparency }

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The badge reports only the coordinator's public status, never cached contents.
struct WorkshopConnectionBadge: View {
    let account: SteamAccountManager
    private var presentation: WorkshopAccountPresentation { .init(account:account) }

    var body: some View {
        Label(presentation.title, systemImage: presentation.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(presentation.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension WorkshopAccountPresentation {
    var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .attention: return .orange
        case .positive: return .green
        case .error: return .red
        }
    }
}
