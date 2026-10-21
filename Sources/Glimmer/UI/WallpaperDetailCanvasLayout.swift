import SwiftUI

private struct WallpaperDetailChromeTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
    var wallpaperDetailChromeTopInset: CGFloat {
        get { self[WallpaperDetailChromeTopInsetKey.self] }
        set { self[WallpaperDetailChromeTopInsetKey.self] = newValue }
    }
}

/// A bounded floating glass card. Only the settings inside scroll; the wallpaper
/// always owns the complete canvas and never changes size when settings update.
struct WallpaperDetailFloatingPanel<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @GlassState private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WallpaperFloatingContentHeight.self, value: geometry.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maxHeight, contentHeight > 0 ? contentHeight : maxHeight))
        .workshopGlassSurface(cornerRadius: 28, tint: .black.opacity(0.2))
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(WallpaperFloatingContentHeight.self) { height in
            if abs(height - contentHeight) > 0.5 { contentHeight = height }
        }
    }
}
private struct WallpaperFloatingContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct WallpaperDetailBackButton: View {
    let onBack: () -> Void
    var body: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .workshopGlassSurface(cornerRadius: 22, tint: .black.opacity(0.2), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("返回壁纸列表")
        .accessibilityIdentifier("wallpaper-details-back")
        .environment(\.colorScheme, .dark)
    }
}
