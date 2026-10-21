import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The active track's curves, one per channel in its own colour, as the player evaluates them
/// (WE's per-frame Bézier, `TimelineCurve`). Keyframes drag in time and value; a selected
/// keyframe shows its back and front handles (WE's model: x in half-segment units, y in value
/// units), which drag the curve's shape. Dragging empty space draws a selection box.
struct TimelineCurveEditor: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var timeline: SceneTimelineEditor
    let target: TimelineTarget
    let onFocus: () -> Void

    @State private var hiddenChannels: Set<Int> = []
    @State private var gesture: CurveGesture?
    @State private var box: CGRect?
    /// The value range while a drag runs, so the view doesn't rescale under the pointer.
    @State private var frozenRange: ClosedRange<Double>?

    init(timeline: SceneTimelineEditor, target: TimelineTarget, onFocus: @escaping () -> Void) {
        self.timeline = timeline
        self.target = target
        self.onFocus = onFocus
    }

    private enum CurveGesture {
        case move(start: CGPoint)
        case handle(TimelineKeyframeRef, TimelineHandleSide)
        case box(start: CGPoint, extending: Bool)
    }

    static let colors: [Color] = [.red, .green, .blue, .orange]

    var body: some View {
        VStack(spacing: 0) {
            if let clip = timeline.clip(target) {
                channelBar(clip)
                GeometryReader { proxy in
                    plot(clip: clip, size: proxy.size)
                }
            }
        }
    }

    private func channelBar(_ clip: TimelineClip) -> some View {
        HStack(spacing: 10) {
            ForEach(clip.channels.indices, id: \.self) { channel in
                Toggle(isOn: Binding(get: { !hiddenChannels.contains(channel) },
                                     set: { if $0 { hiddenChannels.remove(channel) } else { hiddenChannels.insert(channel) } })) {
                    HStack(spacing: 4) {
                        Circle().fill(Self.colors[channel % Self.colors.count]).frame(width: 8, height: 8)
                        Text(verbatim: TimelineNames.channel(channel, of: target))
                    }
                }
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Value ↔ y within the plot, top padded.
    private struct ValueAxis {
        var range: ClosedRange<Double>
        var height: Double
        static let padding: Double = 14

        func y(_ value: Double) -> Double {
            let span = max(range.upperBound - range.lowerBound, 1e-9)
            return Self.padding + (range.upperBound - value) / span * max(height - 2 * Self.padding, 1)
        }

        func value(_ y: Double) -> Double {
            let span = max(range.upperBound - range.lowerBound, 1e-9)
            return range.upperBound - (y - Self.padding) / max(height - 2 * Self.padding, 1) * span
        }

        func valueDelta(_ dy: Double) -> Double {
            -dy / max(height - 2 * Self.padding, 1) * max(range.upperBound - range.lowerBound, 1e-9)
        }
    }

    private struct KeyMark {
        var point: CGPoint
        var ref: TimelineKeyframeRef
        var selected: Bool
    }

    private struct HandleMark {
        var key: CGPoint
        var point: CGPoint
        var ref: TimelineKeyframeRef
        var side: TimelineHandleSide
    }

    private func visibleChannels(_ clip: TimelineClip) -> [Int] {
        clip.channels.indices.filter { !hiddenChannels.contains($0) }
    }

    /// Every visible key, handle and sampled frame, padded; a flat curve gets ±1 around its value.
    private func valueRange(_ clip: TimelineClip) -> ClosedRange<Double> {
        var values: [Double] = []
        for channel in visibleChannels(clip) {
            let keyframes = clip.playerKeyframes(channel: channel)
            values += keyframes.map(\.value)
            for keyframe in clip.channels[channel] {
                for side in [TimelineHandleSide.back, .front] {
                    if let point = clip.handlePoint(channel: channel, frame: keyframe.frame, side: side) { values.append(point.y) }
                }
            }
            let stride = max(clip.length / 200, 1)
            for frame in Swift.stride(from: 0, through: clip.length, by: stride) {
                values.append(Double(TimelineCurve.sample(keyframes, at: Int32(clamping: frame))))
            }
        }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if high - low < 1e-9 { return (low - 1)...(high + 1) }
        let pad = (high - low) * 0.08
        return (low - pad)...(high + pad)
    }

    @ViewBuilder private func plot(clip: TimelineClip, size: CGSize) -> some View {
        let scale = TimelineScale(duration: timeline.duration, width: size.width)
        let axis = ValueAxis(range: frozenRange ?? valueRange(clip), height: size.height)
        let keys = keyMarks(clip: clip, scale: scale, axis: axis)
        let handles = handleMarks(clip: clip, scale: scale, axis: axis)
        let playheadX = scale.x(timeline.playhead)
        let channels = visibleChannels(clip)
        Canvas { (context: inout GraphicsContext, canvasSize: CGSize) in
            Self.drawGrid(in: &context, size: canvasSize, axis: axis)
            Self.drawCurves(in: &context, size: canvasSize, clip: clip, channels: channels, scale: scale, axis: axis)
            Self.drawMarks(in: &context, keys: keys, handles: handles, accent: accentColor)
            let headX: CGFloat = CGFloat(playheadX)
            context.stroke(Self.line(from: CGPoint(x: headX, y: 0), to: CGPoint(x: headX, y: canvasSize.height)),
                           with: .color(.red), lineWidth: 1)
            if let box {
                context.fill(Path(box), with: .color(accentColor.opacity(0.12)))
                context.stroke(Path(box), with: .color(accentColor.opacity(0.7)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in changed(drag, clip: clip, keys: keys, handles: handles, scale: scale, axis: axis) }
            .onEnded { _ in ended(keys: keys) })
    }

    private static func line(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    /// The value grid and its labels.
    private static func drawGrid(in context: inout GraphicsContext, size: CGSize, axis: ValueAxis) {
        let lower: Double = axis.range.lowerBound
        let upper: Double = axis.range.upperBound
        let step: Double = niceStep(upper - lower)
        var value: Double = (lower / step).rounded(.up) * step
        while value <= upper {
            let y: CGFloat = CGFloat(axis.y(value))
            let opacity: Double = abs(value) < step / 1000 ? 0.25 : 0.08
            context.stroke(line(from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y)),
                           with: .color(.primary.opacity(opacity)), lineWidth: 1)
            let label: Text = Text(verbatim: format(value, step: step)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: 4, y: y - 1), anchor: .bottomLeading)
            value += step
        }
    }

    /// The curves: WE's per-frame samples, joined.
    private static func drawCurves(in context: inout GraphicsContext, size: CGSize, clip: TimelineClip, channels: [Int],
                                   scale: TimelineScale, axis: ValueAxis) {
        let width: Double = max(Double(size.width), 1)
        let stride: Int = max(Int(Double(clip.length) / width), 1)
        for channel in channels {
            let keyframes = clip.playerKeyframes(channel: channel)
            let color: Color = colors[channel % colors.count]
            var path = Path()
            var started = false
            for frame in Swift.stride(from: 0, through: clip.length, by: stride) {
                let sample: Double = Double(TimelineCurve.sample(keyframes, at: Int32(clamping: frame)))
                let x: Double = scale.x(frame: frame, fps: clip.fps)
                let point = CGPoint(x: x, y: axis.y(sample))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }

    /// The selected keys' handles, then every key.
    private static func drawMarks(in context: inout GraphicsContext, keys: [KeyMark], handles: [HandleMark],
                                  accent accentColor: Color) {
        for handle in handles {
            context.stroke(line(from: handle.key, to: handle.point), with: .color(.primary.opacity(0.5)), lineWidth: 1)
            let dotRect = CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)
            let dot = Path(ellipseIn: dotRect)
            context.fill(dot, with: .color(Color(nsColor: .controlBackgroundColor)))
            context.stroke(dot, with: .color(accentColor), lineWidth: 1.5)
        }
        for key in keys {
            let mark: Path = TimelineLanes.diamond(at: key.point, radius: 5)
            let color: Color = colors[key.ref.channel % colors.count]
            context.fill(mark, with: key.selected ? .color(accentColor) : .color(color))
            context.stroke(mark, with: .color(key.selected ? .white : .black.opacity(0.4)), lineWidth: 1)
        }
    }

    private func keyMarks(clip: TimelineClip, scale: TimelineScale, axis: ValueAxis) -> [KeyMark] {
        visibleChannels(clip).flatMap { channel in
            clip.channels[channel].map { keyframe in
                let ref = TimelineKeyframeRef(target: target, channel: channel, frame: keyframe.frame)
                return KeyMark(point: CGPoint(x: scale.x(frame: keyframe.frame, fps: clip.fps), y: axis.y(keyframe.value)),
                               ref: ref, selected: timeline.isSelected(ref))
            }
        }
    }

    /// The handles of the selected keyframes: the front one where a segment follows, the back
    /// one where one precedes.
    private func handleMarks(clip: TimelineClip, scale: TimelineScale, axis: ValueAxis) -> [HandleMark] {
        var marks: [HandleMark] = []
        for channel in visibleChannels(clip) {
            let keyframes = clip.channels[channel]
            for (index, keyframe) in keyframes.enumerated() where !keyframe.step {
                let ref = TimelineKeyframeRef(target: target, channel: channel, frame: keyframe.frame)
                guard timeline.isSelected(ref) else { continue }
                let key = CGPoint(x: scale.x(frame: keyframe.frame, fps: clip.fps), y: axis.y(keyframe.value))
                var sides: [TimelineHandleSide] = []
                if index > 0 { sides.append(.back) }
                if index < keyframes.count - 1 { sides.append(.front) }
                for side in sides {
                    guard let point = clip.handlePoint(channel: channel, frame: keyframe.frame, side: side) else { continue }
                    let x = scale.x(clip.fps > 0 ? point.x / clip.fps : 0)
                    marks.append(HandleMark(key: key, point: CGPoint(x: x, y: axis.y(point.y)), ref: ref, side: side))
                }
            }
        }
        return marks
    }

    private func changed(_ drag: DragGesture.Value, clip: TimelineClip, keys: [KeyMark], handles: [HandleMark],
                         scale: TimelineScale, axis: ValueAxis) {
        let modifiers = NSEvent.modifierFlags
        let extending = modifiers.contains(.shift) || modifiers.contains(.command)
        if gesture == nil {
            onFocus()
            frozenRange = axis.range
            timeline.focused = target
            let start = drag.startLocation
            func distance(_ point: CGPoint) -> Double { Double(hypot(point.x - start.x, point.y - start.y)) }
            if let handle = handles.filter({ distance($0.point) <= 6 }).min(by: { distance($0.point) < distance($1.point) }) {
                gesture = .handle(handle.ref, handle.side)
            } else if let key = keys.filter({ distance($0.point) <= 7 }).min(by: { distance($0.point) < distance($1.point) }) {
                if extending {
                    timeline.toggleSelection([key.ref])
                } else if !timeline.selection.contains(key.ref) {
                    timeline.select([key.ref])
                }
                gesture = .move(start: start)
            } else {
                gesture = .box(start: start, extending: extending)
            }
        }
        switch gesture {
        case let .move(start)?:
            guard !timeline.selection.isEmpty else { return }
            let dx: Double = Double(drag.location.x - start.x)
            let dy: Double = Double(drag.location.y - start.y)
            let frames: Int = Int((dx / max(scale.pointsPerFrame(fps: clip.fps), 1e-6)).rounded())
            // ⌥ moves in time only.
            let value: Double = modifiers.contains(.option) ? 0 : axis.valueDelta(dy)
            timeline.previewMove(byFrames: frames, value: value)
        case let .handle(ref, side)?:
            let frame: Double = scale.seconds(Double(drag.location.x)) * clip.fps
            let value: Double = axis.value(Double(drag.location.y))
            timeline.previewHandle(ref, side: side, to: SIMD2<Double>(frame, value))
        case let .box(start, _)?:
            box = CGRect(x: min(start.x, drag.location.x), y: min(start.y, drag.location.y),
                         width: abs(drag.location.x - start.x), height: abs(drag.location.y - start.y))
        case nil:
            break
        }
    }

    private func ended(keys: [KeyMark]) {
        defer {
            gesture = nil
            box = nil
            frozenRange = nil
        }
        switch gesture {
        case .move?:
            timeline.commitPreview(actionName: T("Move Keyframes"))
        case .handle?:
            timeline.commitPreview(actionName: T("Change Curve"))
        case let .box(_, extending)?:
            if let box, box.width >= 2 || box.height >= 2 {
                timeline.select(Set(keys.filter { box.insetBy(dx: -2, dy: -2).contains($0.point) }.map(\.ref)), extending: extending)
            } else if !extending {
                timeline.selection = []
            }
        case nil:
            break
        }
    }

    /// 1, 2 or 5 × a power of ten, giving about four grid lines.
    static func niceStep(_ span: Double) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / 4
        let power = pow(10, (log10(raw)).rounded(.down))
        for multiple in [1.0, 2, 5, 10] where multiple * power >= raw { return multiple * power }
        return 10 * power
    }

    static func format(_ value: Double, step: Double) -> String {
        let digits = max(0, min(6, Int(-(log10(step)).rounded(.down))))
        return String(format: "%.\(digits)f", abs(value) < step / 1000 ? 0 : value)
    }
}
