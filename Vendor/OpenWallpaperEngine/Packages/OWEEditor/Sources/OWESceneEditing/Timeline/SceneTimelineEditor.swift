import Combine
import Foundation

/// The editor's timeline (editor-plan notes P4): the playhead, playback, the keyframe selection
/// and clipboard, and every timeline edit, each one undo step in the session's undo manager.
///
/// Clips come from the overlay's timeline edits, else from scene.json; edits are stored in the
/// overlay (`SceneTimelineEdits`) and reach the canvas through its reload. While the timeline is
/// active, the canvas's scene clock is held and every timeline shows the playhead's time
/// (`onCanvasTime`); deactivating resumes the scene. Animated fields show their value at the
/// playhead in the inspector and on the canvas, and an edit of one sets its keyframe there
/// (`SceneAnimatedFields`).
@MainActor
public final class SceneTimelineEditor: ObservableObject {
    public let session: SceneEditSession
    public let index: TimelineSceneIndex

    /// The timeline panel is shown: the canvas follows the playhead with its scene clock held.
    @Published public var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { pause() }
            pushCanvasTime()
        }
    }
    /// Seconds from the timelines' start.
    @Published public private(set) var playhead: Double = 0
    @Published public private(set) var isPlaying = false
    /// Playback starts over at the end instead of stopping there.
    @Published public var loops = true
    @Published public var selection: Set<TimelineKeyframeRef> = []
    /// The track the clip options, the curve editor and pasting act on.
    @Published public var focused: TimelineTarget?
    /// Clips as a drag in progress shapes them, drawn until it ends and commits them.
    @Published public private(set) var preview: [TimelineTarget: TimelineClip] = [:]
    /// The frames the selection moved by in the drag in progress.
    @Published public private(set) var previewFrameDelta = 0
    /// Whether a drag is drawing a preview, which Escape cancels.
    public var isPreviewing: Bool { !preview.isEmpty }
    /// Set when the drag in progress was cancelled: the rest of it previews and commits nothing.
    private var isDragCancelled = false

    /// Shows a time on the canvas (seconds, its scene clock held) or, with nil, resumes it.
    public var onCanvasTime: ((Double?) -> Void)?
    /// Playback's clock, in seconds (tests set their own).
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// What Copy took: keyframes with their frame relative to the earliest one.
    public struct ClipboardItem: Hashable, Sendable {
        public var target: TimelineTarget
        public var channel: Int
        public var offset: Int
        public var keyframe: TimelineKeyframe
    }
    public private(set) var clipboard: [ClipboardItem] = []

    private var timer: Timer?
    private var lastTick: TimeInterval?
    private var observers: [AnyCancellable] = []

    public init(session: SceneEditSession, index: TimelineSceneIndex) {
        self.session = session
        self.index = index
        session.animatedFields = self
        // An undo or redo can take keyframes away under the selection, and moves the canvas.
        observers.append(session.$overlay.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.overlayDidChange() } }
        })
        observers.append(session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    private func overlayDidChange() {
        selection = selection.filter { clip($0.target)?.keyframe(channel: $0.channel, frame: $0.frame) != nil }
        pushCanvasTime()
    }

    // MARK: Reading

    /// The property's timeline as the canvas plays it: a drag's preview, the overlay's edit, else
    /// scene.json's; nil when it has none.
    public func clip(_ target: TimelineTarget) -> TimelineClip? {
        if let preview = preview[target] { return preview }
        return committedClip(target)
    }

    func committedClip(_ target: TimelineTarget) -> TimelineClip? {
        if let track = session.overlay.timelines?.track(target) { return track.clip }
        return index.authoredClip(target)
    }

    /// The property's value without its timeline (a `relative` timeline's base).
    public func staticValue(_ target: TimelineTarget) -> SceneJSONValue? {
        if let effect = target.effect {
            if target.pass ?? 0 == 0, let edited = session.overlay.effectConstant(target.key, effect: effect, of: target.layer) {
                return edited
            }
            return index.property(target)?.staticValue
        }
        return session.staticValue(target.key, of: target.layer) ?? SceneTimelineEdits.defaultValue(of: target.key)
    }

    /// The animated properties the timeline lists: the selected layer's, or with nothing
    /// selected, every layer's.
    public var tracks: [TimelineTarget] {
        let layers = session.selection.map { [$0] } ?? index.layers
        return layers.flatMap { layer in index.properties(of: layer).map(\.target).filter { clip($0) != nil } }
    }

    /// What a new track can animate on `layer`: properties without a timeline that no user
    /// property sets.
    public func addableProperties(of layer: Int) -> [TimelineSceneIndex.Property] {
        index.properties(of: layer).filter { !$0.isUserBound && clip($0.target) == nil }
    }

    /// The focused track, else the first listed.
    public var activeTarget: TimelineTarget? {
        let tracks = self.tracks
        if let focused, tracks.contains(focused) { return focused }
        return tracks.first
    }

    public var activeClip: TimelineClip? { activeTarget.flatMap(clip) }

    /// The span the ruler shows: the longest listed clip, at least a second.
    public var duration: Double {
        max(tracks.compactMap { clip($0)?.duration }.max() ?? 0, 1)
    }

    /// The whole frame of `clip` nearest the playhead.
    public func playheadFrame(in clip: TimelineClip) -> Int {
        max(Int((playhead * clip.fps).rounded()), 0)
    }

    /// The property's components at the playhead, its timeline applied: nil without a timeline.
    public func values(_ target: TimelineTarget) -> [Float]? {
        guard let clip = clip(target), !clip.isEmpty else { return nil }
        return clip.values(atPlayhead: playhead, staticValue: staticValue(target))
    }

    public enum KeyState: Sendable {
        /// No timeline.
        case none
        /// Animated, no keyframe at the playhead.
        case animated
        /// A keyframe at the playhead on every channel (`partial`: on some).
        case keyed(partial: Bool)
    }

    /// What the property's keyframe button shows.
    public func keyState(_ target: TimelineTarget) -> KeyState {
        guard let clip = clip(target) else { return .none }
        let frame = playheadFrame(in: clip)
        let keyed = clip.channels.indices.filter { clip.keyframe(channel: $0, frame: frame) != nil }.count
        if keyed == 0 { return .animated }
        return .keyed(partial: keyed < clip.channels.count)
    }

    public func isSelected(_ ref: TimelineKeyframeRef) -> Bool {
        var original = ref
        original.frame -= previewFrameDelta
        return selection.contains(original)
    }

    // MARK: Transport

    public func setPlayhead(_ seconds: Double) {
        let time = min(max(seconds.isFinite ? seconds : 0, 0), duration)
        guard time != playhead else { return }
        playhead = time
        pushCanvasTime()
    }

    /// Moves the playhead to `clip`'s frame `frame`.
    public func setPlayhead(frame: Int, in clip: TimelineClip) {
        guard clip.fps > 0 else { return }
        setPlayhead(Double(frame) / clip.fps)
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard !isPlaying else { return }
        if !isActive { isActive = true }
        if playhead >= duration { setPlayhead(0) }
        isPlaying = true
        lastTick = now()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func pause() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        isPlaying = false
    }

    /// One playback step: the playhead moves by the time since the last, starting over at the
    /// end when looping, else stopping there.
    public func tick() {
        guard isPlaying else { return }
        let time = now()
        let delta = max(time - (lastTick ?? time), 0)
        lastTick = time
        var next = playhead + delta
        let end = duration
        if next >= end {
            if loops {
                next = next.truncatingRemainder(dividingBy: end)
            } else {
                next = end
                pause()
            }
        }
        playhead = next
        pushCanvasTime()
    }

    /// The canvas shows the playhead while the timeline is active, and plays on its own otherwise.
    public func pushCanvasTime() {
        onCanvasTime?(isActive ? playhead : nil)
    }

    // MARK: Committing

    /// Commits the clips (nil: no timeline) as one undo step. A clip equal to scene.json's drops
    /// the edit, so the layer no longer counts as edited.
    public func commit(_ clips: [TimelineTarget: TimelineClip?], actionName: String, coalescingKey: String? = nil) {
        guard !clips.isEmpty else { return }
        session.edit(actionName: actionName, coalescingKey: coalescingKey) { overlay in
            overlay.timelines = Self.edits(overlay.timelines, setting: clips, index: index)
        }
    }

    static func edits(_ edits: SceneTimelineEdits?, setting clips: [TimelineTarget: TimelineClip?],
                      index: TimelineSceneIndex) -> SceneTimelineEdits? {
        var edits = edits ?? SceneTimelineEdits()
        for (target, clip) in clips {
            if clip == index.authoredClip(target) {
                edits.drop(target)
            } else {
                edits.set(clip, for: target)
            }
        }
        return edits.isEmpty ? nil : edits
    }

    /// Changes one clip (its options, a keyframe) as one undo step.
    public func change(_ target: TimelineTarget, actionName: String, coalescingKey: String? = nil,
                       _ change: (inout TimelineClip) -> Void) {
        guard var clip = committedClip(target) else { return }
        change(&clip)
        commit([target: clip], actionName: actionName, coalescingKey: coalescingKey)
    }

    // MARK: Keyframes

    /// A new keyframe at the playhead on every channel, at the property's value there; a new
    /// timeline (the active clip's fps and length, else 30 fps and 5 s) when it has none.
    public func addKeyframe(_ target: TimelineTarget, actionName: String) {
        guard let property = index.property(target), !property.isUserBound else { return }
        let values = currentComponents(target, channelCount: property.channelCount)
        var clip = committedClip(target) ?? newClip(channelCount: property.channelCount)
        let frame = playheadFrame(in: clip)
        for channel in clip.channels.indices {
            let value = channel < values.count ? values[channel] : 0
            clip.setKeyframe(channel: channel, frame: frame, value: keyframeValue(value, channel: channel, clip: clip, target: target))
        }
        commit([target: clip], actionName: actionName)
        focused = target
        selection = Set(clip.channels.indices.map { TimelineKeyframeRef(target: target, channel: $0, frame: frame) })
    }

    /// The keyframe button: removes the keyframes at the playhead when every channel has one,
    /// else adds them.
    public func toggleKeyframe(_ target: TimelineTarget, addName: String, removeName: String) {
        if case .keyed(partial: false) = keyState(target), var clip = committedClip(target) {
            let frame = playheadFrame(in: clip)
            for channel in clip.channels.indices { clip.removeKeyframe(channel: channel, frame: frame) }
            selection = selection.filter { !($0.target == target && $0.frame == frame) }
            commit([target: clip], actionName: removeName)
        } else {
            addKeyframe(target, actionName: addName)
        }
        if !isActive { isActive = true }
    }

    func newClip(channelCount: Int) -> TimelineClip {
        if let active = activeClip {
            return TimelineClip(channelCount: channelCount, fps: active.fps, length: active.length, mode: active.mode)
        }
        return TimelineClip(channelCount: channelCount)
    }

    /// The property's components as the canvas shows them now: its timeline at the playhead,
    /// else its static value (WE's default for a field the layer doesn't write).
    func currentComponents(_ target: TimelineTarget, channelCount: Int) -> [Double] {
        if let values = values(target) { return values.map(Double.init) }
        return SceneVector.components(staticValue(target), fallback: Array(repeating: 0, count: channelCount))
    }

    /// The stored value that shows `value`: a `relative` timeline stores offsets from the static value.
    func keyframeValue(_ value: Double, channel: Int, clip: TimelineClip, target: TimelineTarget) -> Double {
        guard clip.relative, channel < 3, case .string(let text)? = staticValue(target),
              let offsets = TimelineClip.relativeOffsets(text) else { return value }
        return value - offsets[channel]
    }

    /// Removes the timeline: the property keeps its static value.
    public func removeTrack(_ target: TimelineTarget, actionName: String) {
        commit([target: TimelineClip?.none], actionName: actionName)
        selection = selection.filter { $0.target != target }
        if focused == target { focused = nil }
    }

    /// Adds a timeline with one keyframe at the playhead.
    public func addTrack(_ target: TimelineTarget, actionName: String) {
        addKeyframe(target, actionName: actionName)
    }

    /// Sets a keyframe's value (the value field, a curve drag).
    public func setValue(_ value: Double, of ref: TimelineKeyframeRef, actionName: String) {
        change(ref.target, actionName: actionName, coalescingKey: "timeline-value") {
            $0.setKeyframe(channel: ref.channel, frame: ref.frame, value: value)
        }
    }

    /// Moves one keyframe to another frame (the frame field).
    public func setFrame(_ frame: Int, of ref: TimelineKeyframeRef, actionName: String) {
        guard frame != ref.frame else { return }
        let target = max(frame, 0)
        change(ref.target, actionName: actionName) { $0.moveKeyframes([ref.channel: [ref.frame]], by: target - ref.frame) }
        if selection.remove(ref) != nil {
            selection.insert(TimelineKeyframeRef(target: ref.target, channel: ref.channel, frame: target))
        }
    }

    /// The selection by track and channel.
    func selectedFrames() -> [TimelineTarget: [Int: Set<Int>]] {
        var frames: [TimelineTarget: [Int: Set<Int>]] = [:]
        for ref in selection { frames[ref.target, default: [:]][ref.channel, default: []].insert(ref.frame) }
        return frames
    }

    public func deleteSelection(actionName: String) {
        guard !selection.isEmpty else { return }
        var clips: [TimelineTarget: TimelineClip?] = [:]
        for (target, channels) in selectedFrames() {
            guard var clip = committedClip(target) else { continue }
            for (channel, frames) in channels { for frame in frames { clip.removeKeyframe(channel: channel, frame: frame) } }
            clips[target] = clip
        }
        selection = []
        commit(clips, actionName: actionName)
    }

    /// A drag of the selection: `frames` later and `value` higher, drawn as a preview.
    public func previewMove(byFrames frames: Int, value: Double = 0) {
        guard !isDragCancelled else { return }
        var clips: [TimelineTarget: TimelineClip] = [:]
        let selected = selectedFrames()
        // One delta for every track, as far as frame 0 lets the earliest keyframe go.
        let earliest = selection.map(\.frame).min() ?? 0
        let delta = max(frames, -earliest)
        for (target, channels) in selected {
            guard var clip = committedClip(target) else { continue }
            clip.moveKeyframes(channels, by: delta, valueDelta: value)
            clips[target] = clip
        }
        preview = clips
        previewFrameDelta = delta
    }

    /// A drag of one handle of a selected keyframe to `point` (frame, value), drawn as a preview.
    public func previewHandle(_ ref: TimelineKeyframeRef, side: TimelineHandleSide, to point: SIMD2<Double>) {
        guard !isDragCancelled, var clip = committedClip(ref.target) else { return }
        clip.setHandle(channel: ref.channel, frame: ref.frame, side: side, to: point)
        preview = [ref.target: clip]
        previewFrameDelta = 0
    }

    /// Ends a drag: commits its preview as one undo step, the selection moved with it.
    public func commitPreview(actionName: String) {
        let clips = preview, delta = previewFrameDelta
        preview = [:]
        previewFrameDelta = 0
        guard !isDragCancelled else {
            isDragCancelled = false
            return
        }
        guard !clips.isEmpty, clips.contains(where: { committedClip($0.key) != $0.value }) else { return }
        if delta != 0 {
            selection = Set(selection.map { TimelineKeyframeRef(target: $0.target, channel: $0.channel, frame: $0.frame + delta) })
        }
        commit(clips.mapValues { Optional($0) }, actionName: actionName)
    }

    /// Escape during a drag: drops its preview, and the rest of the drag does nothing; the drag's
    /// end (`commitPreview`) commits nothing and the next drag works again.
    public func cancelPreview() {
        guard isPreviewing else { return }
        isDragCancelled = true
        preview = [:]
        previewFrameDelta = 0
    }

    /// Gives the selected keyframes (or, with none, the active track's at the playhead) an ease.
    public func applyEase(_ ease: TimelineEase, actionName: String) {
        var frames = selectedFrames()
        if frames.isEmpty, let target = activeTarget, let clip = clip(target) {
            let frame = playheadFrame(in: clip)
            frames[target] = Dictionary(uniqueKeysWithValues: clip.channels.indices.map { ($0, Set([frame])) })
        }
        var clips: [TimelineTarget: TimelineClip?] = [:]
        for (target, channels) in frames {
            guard var clip = committedClip(target) else { continue }
            clip.applyEase(ease, to: channels)
            clips[target] = clip
        }
        commit(clips, actionName: actionName)
    }

    /// The ease every selected keyframe has, if they share one.
    public var selectionEase: TimelineEase? {
        let eases = Set(selection.map { clip($0.target)?.ease(channel: $0.channel, frame: $0.frame) })
        return eases.count == 1 ? eases.first ?? nil : nil
    }

    // MARK: Selection

    public func select(_ refs: Set<TimelineKeyframeRef>, extending: Bool = false) {
        selection = extending ? selection.union(refs) : refs
        if let first = refs.first { focused = first.target }
    }

    public func toggleSelection(_ refs: Set<TimelineKeyframeRef>) {
        if refs.isSubset(of: selection) { selection.subtract(refs) } else { selection.formUnion(refs) }
    }

    /// Every keyframe of the listed tracks.
    public func selectAll() {
        selection = Set(tracks.flatMap { target -> [TimelineKeyframeRef] in
            guard let clip = clip(target) else { return [] }
            return clip.channels.enumerated().flatMap { channel, keyframes in
                keyframes.map { TimelineKeyframeRef(target: target, channel: channel, frame: $0.frame) }
            }
        })
    }

    // MARK: Clipboard

    public func copySelection() {
        let earliest = selection.map(\.frame).min() ?? 0
        clipboard = selection.compactMap { ref in
            clip(ref.target)?.keyframe(channel: ref.channel, frame: ref.frame).map {
                ClipboardItem(target: ref.target, channel: ref.channel, offset: ref.frame - earliest, keyframe: $0)
            }
        }
        .sorted { ($0.target, $0.channel, $0.offset) < ($1.target, $1.channel, $1.offset) }
    }

    public func cutSelection(actionName: String) {
        copySelection()
        deleteSelection(actionName: actionName)
    }

    public var canPaste: Bool { !clipboard.isEmpty }

    /// Pastes at the playhead: onto the tracks the keyframes came from, or, when they came from
    /// one track, onto the focused one (its channels that exist). A track without a timeline gets one.
    public func paste(actionName: String) {
        guard !clipboard.isEmpty else { return }
        let sources = Set(clipboard.map(\.target))
        var destination: (TimelineTarget) -> TimelineTarget = { $0 }
        if sources.count == 1, let focused, index.property(focused) != nil, !sources.contains(focused) {
            destination = { _ in focused }
        }
        var clips: [TimelineTarget: TimelineClip] = [:]
        var pasted = Set<TimelineKeyframeRef>()
        for item in clipboard {
            let target = destination(item.target)
            guard let property = index.property(target), !property.isUserBound else { continue }
            var clip = clips[target] ?? committedClip(target) ?? newClip(channelCount: property.channelCount)
            guard clip.channels.indices.contains(item.channel) else { continue }
            var keyframe = item.keyframe
            keyframe.frame = playheadFrame(in: clip) + item.offset
            clip.insert(keyframe, channel: item.channel)
            clips[target] = clip
            pasted.insert(TimelineKeyframeRef(target: target, channel: item.channel, frame: keyframe.frame))
        }
        commit(clips.mapValues { Optional($0) }, actionName: actionName)
        selection = pasted
    }
}

// MARK: - Animated fields

extension SceneTimelineEditor: SceneAnimatedFields {
    public func value(_ field: String, of layerID: Int) -> SceneJSONValue? {
        guard isActive else { return nil }
        let target = TimelineTarget.field(field, of: layerID)
        guard let values = values(target) else { return nil }
        let base = SceneVector.components(staticValue(target))
        if values.count == 1, base.count <= 1 { return .number(Double(values[0])) }
        var components = base
        for (channel, value) in values.enumerated() {
            if channel < components.count { components[channel] = Double(value) } else { components.append(Double(value)) }
        }
        return SceneVector.value(components)
    }

    public func overlay(setting value: SceneJSONValue, for field: String, of layerID: Int,
                        in overlay: SceneEditOverlay) -> SceneEditOverlay? {
        guard isActive else { return nil }
        let target = TimelineTarget.field(field, of: layerID)
        let components = SceneVector.components(value)
        guard var clip = committedClip(target), !clip.isEmpty, !components.isEmpty else { return nil }
        let frame = playheadFrame(in: clip)
        let current = values(target) ?? []
        for channel in clip.channels.indices where channel < components.count {
            // Only the channels the edit changed get a keyframe (a Position X edit leaves Y's curve).
            let unchanged = channel < current.count && abs(Double(current[channel]) - components[channel]) <= 1e-6 * max(1, abs(components[channel]))
            if unchanged, clip.keyframe(channel: channel, frame: frame) == nil { continue }
            clip.setKeyframe(channel: channel, frame: frame,
                             value: keyframeValue(components[channel], channel: channel, clip: clip, target: target))
        }
        var next = overlay
        next.timelines = Self.edits(next.timelines, setting: [target: clip], index: index)
        return next
    }
}
