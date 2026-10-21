import SwiftUI

// 设置组件共用的视觉辅助，与主界面使用同一套玻璃和辅助功能策略。
//
// - 使用 macOS 26+ 系统 Liquid Glass（`glassEffect`）；「降低透明度」开启时降级为实心背景。
// - 控件均为原生 SwiftUI 控件，自带键盘导航与 VoiceOver 支持。

/// 玻璃设置卡片：标题 + 可选副标题 + 内容。
struct GWSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        GlassStyleReader { style in
            style.panelBackground(cornerRadius: 20)
        }
    }
}

/// 状态胶囊标签（暂停原因、当前项、缺失标记等）。
struct GWStatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
            .accessibilityElement(children: .combine)
    }
}
