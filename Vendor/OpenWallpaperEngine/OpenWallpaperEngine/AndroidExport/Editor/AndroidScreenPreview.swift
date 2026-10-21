import SwiftUI

/// The Android Export mode's preview: the private instance's live scene through the crop, framed
/// as the chosen device's screen (its aspect, a phone's rounder corners), with the status bar's
/// safe area over it. Dragging moves the picture and pinching zooms it, as in the iPhone & iPad
/// Export (`LockScreenPreview`, whose layout and pinning it shares).
struct AndroidScreenPreview: View {
    @ObservedObject var model: AndroidExportEditorModel
    @State private var dragStart: SIMD2<Double>?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let window = model.crop.cropRect
            let layout = LockScreenPreview.layout(window: window, sceneSize: model.sceneSize, in: geometry.size)
            screen(frame: layout.frame, window: window, scale: layout.scale)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .padding(24)
    }

    private func screen(frame: CGSize, window: CGRect, scale: CGFloat) -> some View {
        let kind = model.device?.kind ?? .phone
        let corner = min(frame.width, frame.height) * (kind == .tablet ? 0.04 : 0.09)
        return ZStack(alignment: .topLeading) {
            Color.black
            if model.isVideo {
                // The phone fills its screen with the video, centred: the default crop.
                let layout = LockScreenPreview.Layout(window: window, sceneSize: model.sceneSize, scale: scale)
                LockScreenPreview.pinned(LoopingVideoFileView(url: model.wallpaper.mediaURL, gravity: .resize),
                                         size: layout.sceneViewSize, at: layout.sceneViewOffset, in: frame)
                    .allowsHitTesting(false)
            } else if !model.session.isEnded {
                let layout = LockScreenPreview.Layout(window: window, sceneSize: model.sceneSize, scale: scale)
                LockScreenPreview.pinned(IsolatedSceneView(session: model.session, presentation: model.presentation,
                                                           onContent: { [weak model = self.model] in model?.sceneLoaded($0) }),
                                         size: layout.sceneViewSize, at: layout.sceneViewOffset, in: frame)
                    .allowsHitTesting(false)
            }
            if model.showsStatusBarGuide {
                AndroidStatusBarGuide(height: AndroidStatusBarGuide.height(for: kind, screen: frame), size: frame)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.secondary.opacity(0.6), lineWidth: 4)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .onChanged { value in
                let start = dragStart ?? model.crop.center
                if dragStart == nil { dragStart = start }
                let moved = SIMD2(Double(value.translation.width), Double(value.translation.height)) / Double(scale)
                model.pan(by: start - moved - model.crop.center)
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? model.zoom
                if zoomStart == nil { zoomStart = start }
                model.zoom = start * value.magnification
            }
            .onEnded { _ in zoomStart = nil })
        .help(model.isVideo ? Text("The phone fills its screen with the video") : Text("Drag to move the picture; pinch to zoom"))
        .accessibilityLabel(Text("Android screen preview"))
    }
}

/// The status bar's safe area: a faint band across the top with the time and the status icons,
/// where Android draws over the wallpaper.
struct AndroidStatusBarGuide: View {
    let height: CGFloat
    let size: CGSize

    /// Android's status bar is 24 dp; a phone's screen is about 411 dp across and a tablet's
    /// about 800, so the bar is that share of the screen's shorter side.
    static func height(for kind: AndroidDeviceKind, screen: CGSize) -> CGFloat {
        min(screen.width, screen.height) * (kind == .tablet ? 24.0 / 800 : 24.0 / 411)
    }

    var body: some View {
        let font = Font.system(size: max(height * 0.5, 1), weight: .medium)
        VStack(spacing: 0) {
            HStack(spacing: height * 0.25) {
                Text(Date.now, format: .dateTime.hour().minute())
                Spacer(minLength: 0)
                Image(systemName: "wifi")
                Image(systemName: "cellularbars")
                Image(systemName: "battery.75percent")
            }
            .font(font)
            .padding(.horizontal, height * 0.8)
            .frame(height: height)
            .background(.black.opacity(0.25))
            Rectangle()
                .fill(.white.opacity(0.45))
                .frame(height: 1)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white.opacity(0.8))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
