import AppKit
import SwiftUI
import OWEInspectorKit
import UniformTypeIdentifiers
import OWESceneEditing

/// The timeline under the canvas (editor-plan notes P4): transport and time on top, the
/// animated properties of the selected layer (every layer's with none selected) on the left, their
/// keyframes on a time ruler or, in Curves, the focused track's curves. Space plays and pauses,
/// ←/→ step a frame, Delete removes keyframes, ⌘C/⌘X/⌘V copy, cut and paste at the playhead,
/// ⌘A selects every keyframe, Escape cancels a drag or clears the selection.
struct TimelinePanel: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var timeline: SceneTimelineEditor
    @ObservedObject var session: SceneEditSession
    @State private var expanded: Set<TimelineTarget> = []
    @State private var showsCurves = false
    @State private var isShowingClipOptions = false
    @FocusState private var isFocused: Bool

    static let headerWidth: Double = 230

    init(timeline: SceneTimelineEditor, session: SceneEditSession) {
        self.timeline = timeline
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if timeline.tracks.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    addTrackMenu
                        .frame(width: Self.headerWidth, height: TimelineRuler.height, alignment: .leading)
                    Divider()
                    TimelineRuler(timeline: timeline)
                }
                Divider()
                if showsCurves, let target = timeline.activeTarget {
                    HStack(spacing: 0) {
                        curveTrackList
                            .frame(width: Self.headerWidth)
                        Divider()
                        TimelineCurveEditor(timeline: timeline, target: target) { isFocused = true }
                    }
                } else {
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(rows) { row in header(row) }
                            }
                            .frame(width: Self.headerWidth)
                            Divider()
                            TimelineLanes(timeline: timeline, rows: rows) { isFocused = true }
                        }
                    }
                }
            }
        }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onCopyCommand { copy() }
        .onCutCommand { cut() }
        .onPasteCommand(of: [.plainText]) { _ in timeline.paste(actionName: T("Paste Keyframes")) }
        .onDeleteCommand { timeline.deleteSelection(actionName: T("Delete Keyframes")) }
        .contextMenu { editMenu }
    }

    // MARK: Rows

    private var listsEveryLayer: Bool { session.selection == nil }

    private var rows: [TimelineRow] {
        timeline.tracks.flatMap { target -> [TimelineRow] in
            var rows = [TimelineRow(target: target, channel: nil)]
            if expanded.contains(target), let clip = timeline.clip(target), clip.channels.count > 1 {
                rows += clip.channels.indices.map { TimelineRow(target: target, channel: $0) }
            }
            return rows
        }
    }

    @ViewBuilder private func header(_ row: TimelineRow) -> some View {
        let isActive = row.target == timeline.activeTarget
        HStack(spacing: 4) {
            if let channel = row.channel {
                Text(verbatim: TimelineNames.channel(channel, of: row.target))
                    .foregroundStyle(TimelineCurveEditor.colors[channel % TimelineCurveEditor.colors.count])
                    .padding(.leading, 26)
                Spacer(minLength: 4)
                if let value = timeline.values(row.target)?.timelineElement(at: channel) {
                    Text(verbatim: Self.format(Double(value))).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                let channels = timeline.clip(row.target)?.channels.count ?? 1
                Button {
                    if expanded.contains(row.target) { expanded.remove(row.target) } else { expanded.insert(row.target) }
                } label: {
                    Image(systemName: expanded.contains(row.target) ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .opacity(channels > 1 ? 1 : 0)
                .disabled(channels < 2)
                Text(verbatim: TimelineNames.track(row.target, outline: session.outline, withLayer: listsEveryLayer))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer(minLength: 4)
                KeyframeDiamond(timeline: timeline, target: row.target)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: TimelineRow.height)
        .background(isActive ? accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            timeline.focused = row.target
            isFocused = true
        }
        .contextMenu {
            Button(T("Remove Animation"), role: .destructive) {
                timeline.removeTrack(row.target, actionName: T("Remove Animation"))
            }
        }
    }

    /// In Curves: the tracks to pick the one whose curves show.
    private var curveTrackList: some View {
        List(selection: Binding(get: { timeline.activeTarget }, set: { timeline.focused = $0 })) {
            ForEach(timeline.tracks, id: \.self) { target in
                Text(verbatim: TimelineNames.track(target, outline: session.outline, withLayer: listsEveryLayer))
                    .lineLimit(1)
                    .tag(target)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(T("No animated properties")).font(.headline)
            Text(T("Add a keyframe with the diamond next to a property in the inspector, or add a track here."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            addTrackMenu.fixedSize()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    @ViewBuilder private var transportButtons: some View {
        Button { stepToKeyframe(forward: false) } label: {
            Label(T("Go to Previous Keyframe"), systemImage: "backward.end.fill")
        }
        .help(T("Go to Previous Keyframe"))
        Button { timeline.togglePlayback() } label: {
            Label(timeline.isPlaying ? T("Pause") : T("Play"), systemImage: timeline.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18)
        }
        .help(timeline.isPlaying ? T("Pause") : T("Play"))
        Button { stepToKeyframe(forward: true) } label: {
            Label(T("Go to Next Keyframe"), systemImage: "forward.end.fill")
        }
        .help(T("Go to Next Keyframe"))
        Toggle(isOn: $timeline.loops) {
            Label(T("Loop Playback"), systemImage: "repeat")
        }
        .toggleStyle(.button)
        .help(T("Loop Playback"))
    }

    private var playheadReadout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: TimelineNames.time(timeline.playhead)).font(.body.monospacedDigit())
            if let clip = timeline.activeClip {
                let number = timeline.playheadFrame(in: clip)
                Text(T("Frame \(number)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            transportButtons
            playheadReadout

            keyframeFields
            Spacer(minLength: 8)
            Text(T("The scene is paused while the timeline is open"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            easeMenu
            Picker(selection: $showsCurves) {
                Text(T("Keyframes")).tag(false)
                Text(T("Curves")).tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                isShowingClipOptions = true
            } label: {
                Label(T("Clip Options"), systemImage: "slider.horizontal.3")
            }
            .help(T("Clip Options"))
            .disabled(timeline.activeTarget == nil)
            .popover(isPresented: $isShowingClipOptions, arrowEdge: .top) {
                if let target = timeline.activeTarget {
                    TimelineClipOptionsView(timeline: timeline, target: target,
                                            title: TimelineNames.track(target, outline: session.outline, withLayer: true))
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Frame and value of the one selected keyframe.
    @ViewBuilder private var keyframeFields: some View {
        if timeline.selection.count == 1, let ref = timeline.selection.first,
           let keyframe = timeline.clip(ref.target)?.keyframe(channel: ref.channel, frame: ref.frame) {
            HStack(spacing: 6) {
                Text(T("Frame")).foregroundStyle(.secondary)
                TextField(value: Binding(get: { keyframe.frame },
                                         set: { timeline.setFrame($0, of: ref, actionName: T("Change Keyframe")) }),
                          format: .number) { Text(T("Frame")) }
                    .labelsHidden()
                    .frame(width: 52)
                Text(T("Value")).foregroundStyle(.secondary)
                TextField(value: Binding(get: { keyframe.value },
                                         set: { timeline.setValue($0, of: ref, actionName: T("Change Keyframe")) }),
                          format: .number.precision(.fractionLength(0...4))) { Text(T("Value")) }
                    .labelsHidden()
                    .frame(width: 72)
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout)
        }
    }

    private var easeMenu: some View {
        Menu {
            ForEach(TimelineEase.allCases, id: \.self) { ease in
                Button {
                    timeline.applyEase(ease, actionName: T("Change Ease"))
                } label: {
                    if timeline.selectionEase == ease {
                        Label(ease.title, systemImage: "checkmark")
                    } else {
                        Text(ease.title)
                    }
                }
            }
        } label: {
            Label(T("Ease"), systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(T("Ease"))
        .disabled(timeline.tracks.isEmpty)
    }

    private var addTrackMenu: some View {
        let layer = session.selection
        let properties = layer.map { timeline.addableProperties(of: $0) } ?? []
        return Menu {
            ForEach(properties, id: \.target) { property in
                Button(TimelineNames.property(property.target, outline: session.outline)) {
                    timeline.addTrack(property.target, actionName: T("Add Track"))
                }
            }
        } label: {
            Label(T("Add Track"), systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .disabled(properties.isEmpty)
        .help(layer == nil ? T("Select a layer to add a track") : T("Add Track"))
    }

    @ViewBuilder private var editMenu: some View {
        Button(T("Copy")) { _ = copy() }.disabled(timeline.selection.isEmpty)
        Button(T("Cut")) { _ = cut() }
        .disabled(timeline.selection.isEmpty)
        Button(T("Paste")) { timeline.paste(actionName: T("Paste Keyframes")) }.disabled(!timeline.canPaste)
        Button(T("Delete")) { timeline.deleteSelection(actionName: T("Delete Keyframes")) }.disabled(timeline.selection.isEmpty)
        Divider()
        Button(T("Select All")) { timeline.selectAll() }
        Divider()
        ForEach(TimelineEase.allCases, id: \.self) { ease in
            Button(ease.title) { timeline.applyEase(ease, actionName: T("Change Ease")) }
        }
    }

    // MARK: Keys and commands

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            if press.characters.lowercased() == "a" {
                timeline.selectAll()
                return .handled
            }
            return .ignored
        }
        switch press.key {
        case .space:
            timeline.togglePlayback()
        case .leftArrow, .rightArrow:
            guard let clip = timeline.activeClip else { return .ignored }
            let frame = timeline.playheadFrame(in: clip)
            timeline.setPlayhead(frame: press.key == .rightArrow ? frame + 1 : max(frame - 1, 0), in: clip)
        case .delete, .deleteForward:
            timeline.deleteSelection(actionName: T("Delete Keyframes"))
        case .escape:
            // Cancels a drag in progress, else clears the selection.
            if timeline.isPreviewing { timeline.cancelPreview() } else { timeline.selection = [] }
        default:
            return .ignored
        }
        return .handled
    }

    /// Copies the selection to the timeline's clipboard, and to the pasteboard as WE's keyframe
    /// JSON (the `c0`… lists of the copied keyframes), so Paste is offered.
    private func copy() -> [NSItemProvider] {
        timeline.copySelection()
        return pasteboardItems()
    }

    /// Copies the selection as `copy()` does, then deletes it as one undo step.
    private func cut() -> [NSItemProvider] {
        timeline.cutSelection(actionName: T("Cut Keyframes"))
        return pasteboardItems()
    }

    /// The timeline's clipboard as WE's keyframe JSON for the pasteboard.
    private func pasteboardItems() -> [NSItemProvider] {
        guard !timeline.clipboard.isEmpty else { return [] }
        var channels: [String: SceneJSONValue] = [:]
        for item in timeline.clipboard {
            var clip = TimelineClip(channelCount: item.channel + 1)
            clip.channels[item.channel] = [item.keyframe]
            if case .array(let keys)? = clip.json["c\(item.channel)"] {
                if case .array(let existing)? = channels["c\(item.channel)"] {
                    channels["c\(item.channel)"] = .array(existing + keys)
                } else {
                    channels["c\(item.channel)"] = .array(keys)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SceneJSONValue.object(channels)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }

    private func stepToKeyframe(forward: Bool) {
        guard let target = timeline.activeTarget, let clip = timeline.clip(target) else { return }
        let frame = timeline.playheadFrame(in: clip)
        let frames = clip.keyframeFrames
        let next = forward ? frames.first(where: { $0 > frame }) : frames.last(where: { $0 < frame })
        if let next { timeline.setPlayhead(frame: next, in: clip) }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private extension Array {
    func timelineElement(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
