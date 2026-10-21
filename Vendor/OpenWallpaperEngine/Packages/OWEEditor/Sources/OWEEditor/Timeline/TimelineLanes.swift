import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// Seconds to points across the timeline's width, with room at both ends for a keyframe's diamond.
struct TimelineScale: Equatable {
    var duration: Double
    var width: Double
    static let inset: Double = 12

    private var span: Double { max(width - 2 * Self.inset, 1) }

    func x(_ seconds: Double) -> Double { Self.inset + seconds / max(duration, 1e-6) * span }
    func seconds(_ x: Double) -> Double { (x - Self.inset) / span * duration }
    func x(frame: Int, fps: Double) -> Double { x(fps > 0 ? Double(frame) / fps : 0) }
    func pointsPerFrame(fps: Double) -> Double { fps > 0 ? span / max(duration, 1e-6) / fps : 1 }

    /// Ruler steps: the shortest from the list at least `minimum` points apart.
    func tickStep(minimum: Double = 64) -> Double {
        let steps: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let perSecond = span / max(duration, 1e-6)
        return steps.first { $0 * perSecond >= minimum } ?? steps[steps.count - 1]
    }
}

/// One row of the timeline: a track (its keyframes on every channel together) or one of its
/// channels.
struct TimelineRow: Identifiable, Hashable {
    let target: TimelineTarget
    /// Nil for the track's own row.
    let channel: Int?

    var id: String { "\(target.layer)/\(target.effect ?? -1)/\(target.pass ?? -1)/\(target.key)/\(channel ?? -1)" }

    static let height: Double = 24
}

/// The time ruler: ticks and times, the playhead, and scrubbing (drag anywhere on it; the
/// playhead snaps to the active clip's frames).
struct TimelineRuler: View {
    @ObservedObject var timeline: SceneTimelineEditor
    static let height: Double = 24


    private static func line(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, scale: TimelineScale, playhead: Double) {
        let height: CGFloat = size.height
        let step: Double = scale.tickStep()
        var tick: Double = 0
        while tick <= scale.duration + 1e-9 {
            let x: CGFloat = CGFloat(scale.x(tick))
            context.stroke(line(from: CGPoint(x: x, y: height - 8), to: CGPoint(x: x, y: height)),
                           with: .color(.secondary), lineWidth: 1)
            let label: Text = Text(verbatim: TimelineNames.time(tick)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
            let half: Double = tick + step / 2
            if half <= scale.duration {
                let hx: CGFloat = CGFloat(scale.x(half))
                context.stroke(line(from: CGPoint(x: hx, y: height - 4), to: CGPoint(x: hx, y: height)),
                               with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            }
            tick += step
        }
        let x: CGFloat = CGFloat(scale.x(playhead))
        var head = Path()
        head.move(to: CGPoint(x: x - 5, y: height - 10))
        head.addLine(to: CGPoint(x: x + 5, y: height - 10))
        head.addLine(to: CGPoint(x: x, y: height))
        head.closeSubpath()
        context.fill(head, with: .color(.red))
        context.stroke(line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: height)), with: .color(.red), lineWidth: 1)
    }
    var body: some View {
        GeometryReader { proxy in
            let scale = TimelineScale(duration: timeline.duration, width: proxy.size.width)
            let playhead = timeline.playhead
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                Self.draw(in: &context, size: size, scale: scale, playhead: playhead)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in scrub(to: drag.location.x, scale: scale) })
            .accessibilityElement()
            .accessibilityLabel(T("Playhead"))
            .accessibilityValue(TimelineNames.time(playhead))
            .accessibilityAdjustableAction { direction in
                guard let clip = timeline.activeClip else { return }
                let frame = timeline.playheadFrame(in: clip)
                timeline.setPlayhead(frame: direction == .increment ? frame + 1 : max(frame - 1, 0), in: clip)
            }
        }
        .frame(height: Self.height)
    }

    private func scrub(to x: Double, scale: TimelineScale) {
        let seconds = scale.seconds(x)
        if let clip = timeline.activeClip, clip.fps > 0 {
            timeline.setPlayhead((seconds * clip.fps).rounded() / clip.fps)
        } else {
            timeline.setPlayhead(seconds)
        }
    }
}

/// The keyframe lanes: each row's keyframes on the time axis. Click selects (Shift or ⌘ adds and
/// removes), dragging a selected keyframe moves the selection by whole frames, dragging on empty
/// space draws a selection box.
struct TimelineLanes: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var timeline: SceneTimelineEditor
    let rows: [TimelineRow]
    let onFocus: () -> Void

    @State private var gesture: LaneGesture?
    @State private var box: CGRect?

    init(timeline: SceneTimelineEditor, rows: [TimelineRow], onFocus: @escaping () -> Void) {
        self.timeline = timeline
        self.rows = rows
        self.onFocus = onFocus
    }

    private enum LaneGesture {
        case move(start: CGPoint, pointsPerFrame: Double)
        case box(start: CGPoint, extending: Bool)
    }

    /// One keyframe as drawn: where, which keyframes it stands for, and how.
    struct Mark {
        var point: CGPoint
        var refs: Set<TimelineKeyframeRef>
        var selected: Bool
        var hold: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = TimelineScale(duration: timeline.duration, width: proxy.size.width)
            let marks = makeMarks(scale: scale)
            let spans = makeSpans(scale: scale)
            let playheadX = scale.x(timeline.playhead)
            let focusedRows = Set(rows.indices.filter { rows[$0].target == timeline.activeTarget })
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                for index in rows.indices {
                    let y: CGFloat = CGFloat(Double(index) * TimelineRow.height)
                    let band = CGRect(x: 0, y: y, width: size.width, height: CGFloat(TimelineRow.height))
                    if focusedRows.contains(index) {
                        context.fill(Path(band), with: .color(accentColor.opacity(0.08)))
                    } else if index % 2 == 1 {
                        context.fill(Path(band), with: .color(.primary.opacity(0.03)))
                    }
                }
                for span in spans {
                    context.stroke(Path { $0.move(to: span.0); $0.addLine(to: span.1) },
                                   with: .color(.secondary.opacity(0.5)), lineWidth: 2)
                }
                for mark in marks {
                    let path = mark.hold ? Self.square(at: mark.point) : Self.diamond(at: mark.point)
                    context.fill(path, with: mark.selected ? .color(accentColor) : .color(Color(nsColor: .controlBackgroundColor)))
                    context.stroke(path, with: mark.selected ? .color(accentColor) : .color(.primary.opacity(0.75)), lineWidth: 1)
                }
                let headX: CGFloat = CGFloat(playheadX)
                var head = Path()
                head.move(to: CGPoint(x: headX, y: 0))
                head.addLine(to: CGPoint(x: headX, y: size.height))
                context.stroke(head, with: .color(.red), lineWidth: 1)
                if let box {
                    context.fill(Path(box), with: .color(accentColor.opacity(0.12)))
                    context.stroke(Path(box), with: .color(accentColor.opacity(0.7)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in changed(drag, marks: marks, scale: scale) }
                .onEnded { drag in ended(drag, marks: marks) })
        }
        .frame(height: CGFloat(max(Double(rows.count) * TimelineRow.height, TimelineRow.height)))
    }

    static func diamond(at point: CGPoint, radius: Double = 5.5) -> Path {
        let r: CGFloat = CGFloat(radius)
        let x: CGFloat = point.x, y: CGFloat = point.y
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - r))
        path.addLine(to: CGPoint(x: x + r, y: y))
        path.addLine(to: CGPoint(x: x, y: y + r))
        path.addLine(to: CGPoint(x: x - r, y: y))
        path.closeSubpath()
        return path
    }

    static func square(at point: CGPoint, radius: Double = 4.5) -> Path {
        let r: CGFloat = CGFloat(radius)
        return Path(CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    }

    private func makeMarks(scale: TimelineScale) -> [Mark] {
        var marks: [Mark] = []
        for (index, row) in rows.enumerated() {
            guard let clip = timeline.clip(row.target) else { continue }
            let y: Double = (Double(index) + 0.5) * TimelineRow.height
            let channels = row.channel.map { [$0] } ?? Array(clip.channels.indices)
            var byFrame: [Int: (refs: Set<TimelineKeyframeRef>, hold: Bool)] = [:]
            for channel in channels where clip.channels.indices.contains(channel) {
                for keyframe in clip.channels[channel] {
                    let ref = TimelineKeyframeRef(target: row.target, channel: channel, frame: keyframe.frame)
                    byFrame[keyframe.frame, default: ([], keyframe.step)].refs.insert(ref)
                }
            }
            for (frame, entry) in byFrame {
                marks.append(Mark(point: CGPoint(x: scale.x(frame: frame, fps: clip.fps), y: y), refs: entry.refs,
                                  selected: entry.refs.contains { timeline.isSelected($0) }, hold: entry.hold))
            }
        }
        return marks
    }

    /// Each track row's animated stretch, first keyframe to last.
    private func makeSpans(scale: TimelineScale) -> [(CGPoint, CGPoint)] {
        rows.enumerated().compactMap { index, row in
            guard let clip = timeline.clip(row.target) else { return nil }
            let frames = row.channel.map { clip.channels.indices.contains($0) ? clip.channels[$0].map(\.frame) : [] } ?? clip.keyframeFrames
            guard let first = frames.min(), let last = frames.max(), last > first else { return nil }
            let y: Double = (Double(index) + 0.5) * TimelineRow.height
            let start = CGPoint(x: scale.x(frame: first, fps: clip.fps), y: y)
            let end = CGPoint(x: scale.x(frame: last, fps: clip.fps), y: y)
            return (start, end)
        }
    }

    private func hit(_ point: CGPoint, marks: [Mark]) -> Mark? {
        let halfRow: CGFloat = CGFloat(TimelineRow.height / 2)
        let near: [Mark] = marks.filter { (mark: Mark) -> Bool in
            let dy: CGFloat = abs(mark.point.y - point.y)
            let dx: CGFloat = abs(mark.point.x - point.x)
            return dy < halfRow && dx <= 7
        }
        return near.min { (a: Mark, b: Mark) -> Bool in abs(a.point.x - point.x) < abs(b.point.x - point.x) }
    }

    private func changed(_ drag: DragGesture.Value, marks: [Mark], scale: TimelineScale) {
        let modifiers = NSEvent.modifierFlags
        let extending = modifiers.contains(.shift) || modifiers.contains(.command)
        if gesture == nil {
            onFocus()
            if let mark = hit(drag.startLocation, marks: marks) {
                if extending {
                    timeline.toggleSelection(mark.refs)
                } else if !mark.refs.contains(where: { timeline.selection.contains($0) }) {
                    timeline.select(mark.refs)
                }
                if let target = mark.refs.first?.target { timeline.focused = target }
                let fps = mark.refs.first.flatMap { timeline.clip($0.target)?.fps } ?? 30
                gesture = .move(start: drag.startLocation, pointsPerFrame: scale.pointsPerFrame(fps: fps))
            } else {
                gesture = .box(start: drag.startLocation, extending: extending)
                let row: Int = Int(Double(drag.startLocation.y) / TimelineRow.height)
                if rows.indices.contains(row) { timeline.focused = rows[row].target }
            }
        }
        switch gesture {
        case let .move(start, pointsPerFrame)?:
            guard !timeline.selection.isEmpty else { return }
            let dx: Double = Double(drag.location.x - start.x)
            let frames: Int = Int((dx / max(pointsPerFrame, 1e-6)).rounded())
            timeline.previewMove(byFrames: frames)
        case let .box(start, _)?:
            box = CGRect(x: min(start.x, drag.location.x), y: min(start.y, drag.location.y),
                         width: abs(drag.location.x - start.x), height: abs(drag.location.y - start.y))
        case nil:
            break
        }
    }

    private func ended(_ drag: DragGesture.Value, marks: [Mark]) {
        defer {
            gesture = nil
            box = nil
        }
        switch gesture {
        case .move?:
            timeline.commitPreview(actionName: T("Move Keyframes"))
        case let .box(_, extending)?:
            let refs = Set(marks.filter { box?.insetBy(dx: -2, dy: -2).contains($0.point) == true }.flatMap(\.refs))
            if box.map({ $0.width < 2 && $0.height < 2 }) ?? true {
                if !extending { timeline.selection = [] }
            } else {
                timeline.select(refs, extending: extending)
            }
        case nil:
            break
        }
    }
}
