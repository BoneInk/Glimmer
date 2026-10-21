import SwiftUI

/// 视觉样式辅助：系统 Liquid Glass 控件 + 辅助功能降级。
///
/// - 使用 macOS 26+ 的系统 `glassEffect` / `.glass` / `.glassProminent`，不伪造毛玻璃。
/// - 「降低透明度」开启时，玻璃替换为实心背景，保证可读性。
/// - 「减少动态效果」开启时，关闭卡片缩放/过渡动画。
struct GlassStyle {
    var reduceTransparency: Bool
    var reduceMotion: Bool

    /// All floating panels use the same material, tint, edge and shadow.
    func panelBackground(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .modifier(WorkspaceGlassSurface(reduceTransparency: reduceTransparency,
                cornerRadius: cornerRadius, tint: tint, interactive: false))
    }

    /// 悬浮控件（按钮、徽标）背景。
    @ViewBuilder
    func controlBackground(capsule: Bool = true) -> some View {
        if capsule {
            if reduceTransparency {
                Capsule(style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
            } else {
                Capsule(style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            }
        } else {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            }
        }
    }

    /// Readable sections within a glass panel; avoid a second refractive layer.
    func groupedBackground(cornerRadius: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.18))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(reduceTransparency ? 0.12 : 0.07), lineWidth: 0.5)
            }
    }

    var cardAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22)
    }

    var stateTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }
}

/// 读取系统辅助功能环境值并生成样式。
struct GlassStyleReader<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowGlassReduceTransparencyOverride) private var reviewReduceTransparency
    @Environment(\.windowGlassReduceMotionOverride) private var reviewReduceMotion

    let content: (GlassStyle) -> Content

    var body: some View {
        content(GlassStyle(reduceTransparency: reduceTransparency || reviewReduceTransparency, reduceMotion: reduceMotion || reviewReduceMotion))
    }
}

/// Shared by navigation, search and content panels so the same wallpaper is
/// sampled with identical material parameters on both sides of the workspace.
struct WorkspaceGlassSurface: ViewModifier {
    let reduceTransparency: Bool
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .glassEffect(Glass.regular.tint(tint)
                    .interactive(interactive), in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        }
    }
}
