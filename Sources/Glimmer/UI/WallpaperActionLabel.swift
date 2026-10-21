import SwiftUI

/// Keeps the button's intrinsic size unchanged while its operation is running.
struct WallpaperActionLabel: View {
    let title: String
    let symbol: String
    let busy: Bool

    var body: some View {
        Label("正在设置…", systemImage: symbol)
            .hidden()
            .overlay {
                HStack(spacing: 6) {
                    ZStack {
                        Image(systemName: symbol).opacity(busy ? 0 : 1)
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 18, height: 16)
                    Text(busy ? "正在设置…" : title)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busy ? "正在设置…" : title)
    }
}
