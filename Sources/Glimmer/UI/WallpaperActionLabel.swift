import SwiftUI

/// Keeps the button's intrinsic size unchanged while its operation is running.
struct WallpaperActionLabel: View {
    let title: String
    let symbol: String
    let busy: Bool
    var busyTitle = "正在设置…"

    var body: some View {
        Color.clear
            .frame(width: 100, height: 18)
            .overlay(alignment: .center) {
                HStack(spacing: 6) {
                    ZStack {
                        Image(systemName: symbol).opacity(busy ? 0 : 1)
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 18, height: 16)
                    Text(busy ? busyTitle : title).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busy ? busyTitle : title)
    }
}
