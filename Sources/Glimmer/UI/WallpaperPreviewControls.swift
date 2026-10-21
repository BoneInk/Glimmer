import SwiftUI

/// The same compact transport controls are used by every wallpaper preview.
struct WallpaperPreviewControls: View {
    @Binding var paused: Bool
    var muted: Binding<Bool>? = nil
    var loops: Binding<Bool>? = nil
    var canTogglePause = true

    var body: some View {
        HStack(spacing: 8) {
            Button { paused.toggle() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .frame(width: 24, height: 24)
            }
            .disabled(!canTogglePause)
            .help(paused ? "播放预览" : "暂停预览")
            .accessibilityLabel(paused ? "播放预览" : "暂停预览")
            .accessibilityIdentifier("wallpaper-preview-play-pause")
            if let muted {
                Button { muted.wrappedValue.toggle() } label: {
                    Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24, height: 24)
                }
                .help(muted.wrappedValue ? "开启预览声音" : "预览静音")
                .accessibilityLabel(muted.wrappedValue ? "开启预览声音" : "预览静音")
                .accessibilityValue(muted.wrappedValue ? "已静音" : "有声音")
                .accessibilityIdentifier("wallpaper-preview-mute")
            }
            if let loops {
                Button { loops.wrappedValue.toggle() } label: {
                    Image(systemName: "repeat")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(loops.wrappedValue ? Color.accentColor : Color.primary)
                }
                .help("循环播放")
                .accessibilityLabel("循环播放")
                .accessibilityValue(loops.wrappedValue ? "已开启" : "已关闭")
                .accessibilityIdentifier("wallpaper-preview-loop")
            }
        }
        .font(.callout.weight(.medium))
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
    }
}
