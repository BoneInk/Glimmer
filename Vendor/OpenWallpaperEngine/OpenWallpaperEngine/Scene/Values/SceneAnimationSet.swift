import Foundation

/// Every property timeline of one wallpaper instance, keyed by site (owner and property key), with
/// WE's per-frame evaluation (docs/timeline-plan.md §2.1, `0x140172370`…`0x1401726f3`):
///
/// 1. For each animation in registration order, its clock owner is its parent, else itself (one
///    level: a parent's own parent doesn't matter to the child).
/// 2. The owner's clock advances once per frame, by `delta × owner.rate` (the rate is 1 until a
///    script writes it); the events it crosses fire, as the owner's.
/// 3. The animation samples **its own** channels on the owner's clock, every frame, paused or not.
///
/// Script calls (`IAnimation`) act on the named animation's own clock and rate, so on a linked
/// child they change nothing visible, as in WE. Texture animations live in `textures`.
///
/// Two displays of one wallpaper each own a set. Confined to the thread that drives the instance's
/// frames (not shared, not locked).
final class SceneAnimationSet {
    private struct Entry {
        let site: SceneAnimationSite
        var timeline: SceneTimelineAnimation
        /// The index of the animation whose clock this one samples (`options.parent`), if linked.
        var parent: Int?
        /// The script wrapper's `rate` (`+0xf8` → `+0xd0`).
        var rate: Float = 1
        /// The frame counter of this clock's last advance: a clock moves at most once per frame.
        var advanced: UInt64 = 0
        /// The last value sampled (`advance(by:)` or `refresh()`): `c0`…`c3`, 0 past the last.
        var value = SIMD4<Float>.zero
        /// The clock owner's time `value` was sampled at (its bit pattern): the value is a function
        /// of that time alone, so a clock that didn't move (paused, finished, rate 0) isn't
        /// sampled again. Nil until the first sample, and after a relink.
        var sampledAt: UInt32?
    }

    private let wallpaperID: String
    private var entries: [Entry] = []
    private var indices: [SceneAnimationSite: Int] = [:]
    /// Every animated site, in registration (evaluation) order: `index(of:)` counts in it.
    private(set) var sites: [SceneAnimationSite] = []
    /// The last `replayedFrames` deltas, by frame counter modulo their count (`deltas(since:)`).
    private var recentDeltas = [Float](repeating: 0, count: SceneAnimationSet.replayedFrames)
    /// Events a replayed advance (`restore`) crossed, handed out with the next frame's.
    private var replayedEvents: [SceneAnimationEvent] = []
    /// How many frames late a script frame's calls can come back and still be replayed.
    static let replayedFrames = 8
    /// Sites whose value wasn't finite, reported once.
    private var reportedNonFinite = Set<SceneAnimationSite>()
    /// Counts `advance(by:)` calls: WE's engine frame counter (`[engine+0x144]`).
    private(set) var frameCounter: UInt64 = 0
    /// The texture clocks and layer overrides of the same instance.
    let textures = SceneTextureAnimations()

    init(wallpaperID: String) {
        self.wallpaperID = wallpaperID
    }

    /// Every animated property of `document` (`scene.json`), linked and sampled at time 0.
    convenience init(document: SceneJSON, wallpaperID: String) {
        self.init(wallpaperID: wallpaperID)
        SceneAnimationHolders.holders(in: document).forEach { add($0) }
        relink()
        refresh()
    }

    // MARK: - Building

    /// Adds the animated properties of a layer that arrived after load (`createLayer`, an asset's
    /// objects), linked within their owners and sampled at time 0.
    func addObject(_ fields: [String: SceneJSON], id: Int) {
        SceneAnimationHolders.holders(ofObject: fields, id: id).forEach { add($0) }
        relink()
        refresh()
    }

    /// Removes every animation of layer `id` (its fields, overrides, effects and materials) and its
    /// texture animation. A link to a removed parent is cleared (`0x1401774b4`).
    func removeObject(_ id: Int) {
        textures.removeObject(id)
        guard entries.contains(where: { $0.site.owner.objectID == id }) else { return }
        entries.removeAll { $0.site.owner.objectID == id }
        indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.site, $0.offset) })
        sites = entries.map(\.site)
        relink()
    }

    /// Builds a site's timeline from its bound value. A malformed `animation` is logged and left
    /// out: the property keeps its other sources.
    private func add(_ holder: SceneAnimationHolders.Holder) {
        guard let json = holder.fields["animation"] else { return }
        guard indices[holder.site] == nil else {
            OWELog.error(.scene, "\(wallpaperID): \(holder.site) is animated twice; keeping the first")
            return
        }
        do {
            let timeline = try SceneTimelineAnimation(json: json, staticValue: holder.fields["value"])
            indices[holder.site] = entries.count
            entries.append(Entry(site: holder.site, timeline: timeline))
            sites.append(holder.site)
        } catch {
            OWELog.error(.scene, "\(wallpaperID): the animation of \(holder.site) is not used: \(error)")
        }
    }

    /// WE's link (`0x1401769dd`…`0x140176a51`): the parent is the animation of the same owner whose
    /// property key is the child's `parent.key`.
    private func relink() {
        for index in entries.indices {
            let child = entries[index]
            entries[index].parent = child.timeline.parentKey.flatMap {
                indices[SceneAnimationSite(owner: child.site.owner, key: $0)]
            }
            entries[index].sampledAt = nil
            if let key = child.timeline.parentKey, entries[index].parent == nil {
                OWELog.debug(.scene, "\(wallpaperID): \(child.site) follows '\(key)', which isn't animated here")
            }
        }
    }

    // MARK: - Frame

    /// One frame (plan P1: after media, before timers and `update`): advances every clock owner
    /// once by `delta × rate`, samples every site on its owner's clock (`value(of:)`,
    /// `components(at:)`) and returns the events crossed. `delta` is the frame's scene delta
    /// (`SceneClock`), in seconds.
    @discardableResult
    func advance(by delta: Float) -> SceneAnimationFrame {
        frameCounter &+= 1
        recentDeltas[Int(frameCounter % UInt64(Self.replayedFrames))] = delta
        var frame = SceneAnimationFrame(events: replayedEvents)
        replayedEvents.removeAll()
        textures.advanceOverrides(delta: delta)
        for index in entries.indices {
            let owner = entries[index].parent ?? index
            if entries[owner].advanced != frameCounter {
                entries[owner].advanced = frameCounter
                let step = delta * entries[owner].rate
                let site = entries[owner].site
                for event in entries[owner].timeline.clock.advance(by: step) {
                    frame.events.append(SceneAnimationEvent(site: site, name: event.name, frame: event.frame))
                }
            }
            sample(index)
        }
        return frame
    }

    /// The Wallpaper Editor's playhead (editor-plan notes P4), in place of an advance: every
    /// clock owner stands where its mode puts `seconds` (`SceneTimelineClock.scrub`) and every
    /// site is sampled there. No clock advances and no event fires; the frame counter moves, as a
    /// frame's does.
    func scrub(to seconds: Float) {
        frameCounter &+= 1
        recentDeltas[Int(frameCounter % UInt64(Self.replayedFrames))] = 0
        replayedEvents.removeAll()
        for index in entries.indices where entries[index].parent == nil {
            entries[index].timeline.clock.scrub(to: seconds)
        }
        for index in entries.indices { sample(index) }
    }

    /// Samples every site again without moving any clock (after script calls, or at load).
    func refresh() {
        for index in entries.indices {
            entries[index].sampledAt = nil
            sample(index)
        }
    }

    private func sample(_ index: Int) {
        let owner = entries[index].parent ?? index
        let time = entries[owner].timeline.clock.time.bitPattern
        guard entries[index].sampledAt != time else { return }
        entries[index].value = entries[index].timeline.components(on: entries[owner].timeline.clock)
        entries[index].sampledAt = time
    }

    // MARK: - Reads

    func contains(_ site: SceneAnimationSite) -> Bool { indices[site] != nil }

    /// Where `site` sits in `sites`, for `components(at:)`; valid until an object is added or
    /// removed.
    func index(of site: SceneAnimationSite) -> Int? { indices[site] }

    /// The site's value as last sampled: one component per channel (at most four, `c0`…`c3`).
    func value(of site: SceneAnimationSite) -> [Float]? {
        guard let index = indices[site] else { return nil }
        let count = min(entries[index].timeline.channels.count, 4)
        return (0..<count).map { entries[index].value[$0] }
    }

    /// The value at `index` (in `sites`) as last sampled, 0 past its last channel.
    func components(at index: Int) -> SIMD4<Float> { entries[index].value }

    /// What the renderer draws of the value at `index`: nil while a component isn't finite. WE's
    /// maths keeps a NaN or infinite time (`setFrame(NaN)`, `rate = Infinity`) for good, and
    /// scripts see it, but the GPU never gets it: the property draws its static or user-bound
    /// value instead until the clock is finite again (`stop()`, `setFrame(0)`; test-risks TF6).
    func drawnComponents(at index: Int) -> SIMD4<Float>? {
        let value = entries[index].value
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
            if reportedNonFinite.insert(entries[index].site).inserted {
                OWELog.info(.scene, "\(wallpaperID): the timeline of \(entries[index].site) left a value that isn't finite; drawing its static value")
            }
            return nil
        }
        return value
    }

    /// `value(of:)` as the renderer draws it (`drawnComponents(at:)`).
    func drawnValue(of site: SceneAnimationSite) -> [Float]? {
        guard let index = indices[site], drawnComponents(at: index) != nil else { return nil }
        return value(of: site)
    }

    /// How many channels the timeline at `index` has (`c0`…), at most four.
    func channelCount(at index: Int) -> Int { min(entries[index].timeline.channels.count, 4) }

    /// The site's clock owner: its parent when linked, else itself.
    func clockOwner(of site: SceneAnimationSite) -> SceneAnimationSite? {
        indices[site].map { entries[entries[$0].parent ?? $0].site }
    }

    /// The `IAnimation` state of the site's own animation.
    func state(of site: SceneAnimationSite) -> SceneAnimationState? {
        indices[site].map(state(at:))
    }

    /// The `IAnimation` state of the animation at `index` (in `sites`).
    func state(at index: Int) -> SceneAnimationState {
        let clock = entries[index].timeline.clock
        return SceneAnimationState(name: entries[index].timeline.name, fps: clock.fps, frameCount: clock.length,
                                   duration: clock.duration, rate: entries[index].rate, time: clock.time,
                                   flags: clock.flags, frame: clock.frame, value: entries[index].value)
    }

    /// `getAnimation(name)`: the first animation of `owner` whose `options.name` is `name`; with no
    /// owner (`thisScene.getAnimation`), the first of any owner, in registration order.
    func site(named name: String, owner: SceneAnimationOwner? = nil) -> SceneAnimationSite? {
        entries.first { $0.timeline.name == name && (owner == nil || $0.site.owner == owner) }?.site
    }

    // MARK: - Script control

    /// Applies an `IAnimation` call to the site's own clock. False when the site isn't animated.
    @discardableResult
    func perform(_ control: SceneAnimationControl, on site: SceneAnimationSite) -> Bool {
        guard let index = indices[site] else { return false }
        switch control {
        case .play: entries[index].timeline.clock.play()
        case .pause: entries[index].timeline.clock.pause()
        case .stop: entries[index].timeline.clock.stop()
        case .setFrame(let frame): entries[index].timeline.clock.setFrame(frame)
        case .setRate(let rate): entries[index].rate = rate
        }
        return true
    }

    /// Takes the state a script frame left (the JS side applies WE's rules to the animation buffer
    /// in call order; the host reads a dirty slot back afterwards): the clock's time, its run-time
    /// bits (`paused`, `finished`, `reversed`; the mode bits are kept) and the rate.
    ///
    /// `seenAt` is the frame counter the script frame saw. A script frame that overran the draw's
    /// wait comes back after later advances; those are replayed on the restored clock (by their
    /// deltas × the restored rate, their events handed out with the next frame's) and the site
    /// and the children on its clock are sampled again, so the calls act as if they had come
    /// back in time and no advance is lost. False when the site isn't animated.
    @discardableResult
    func restore(_ site: SceneAnimationSite, time: Float, flags: SceneTimelineClock.Flags, rate: Float,
                 seenAt: UInt64? = nil) -> Bool {
        guard let index = indices[site] else { return false }
        let runtime: SceneTimelineClock.Flags = [.paused, .finished, .reversed]
        entries[index].timeline.clock.time = time
        entries[index].timeline.clock.flags = entries[index].timeline.clock.flags.subtracting(runtime)
            .union(flags.intersection(runtime))
        entries[index].rate = rate
        // A linked child's own clock never moves (§2.5): nothing to replay.
        guard let seenAt, entries[index].parent == nil else { return true }
        let missed = deltas(since: seenAt)
        guard !missed.isEmpty else { return true }
        for delta in missed {
            for event in entries[index].timeline.clock.advance(by: delta * rate) {
                replayedEvents.append(SceneAnimationEvent(site: site, name: event.name, frame: event.frame))
            }
        }
        for other in entries.indices where other == index || entries[other].parent == index { sample(other) }
        return true
    }

    /// The delta of the last `advance(by:)`.
    var lastDelta: Float { recentDeltas[Int(frameCounter % UInt64(Self.replayedFrames))] }

    /// The deltas of the advances after frame `frame`, oldest first: at most `replayedFrames`
    /// (a script frame later than that loses the older ones, logged).
    func deltas(since frame: UInt64) -> [Float] {
        guard frameCounter > frame else { return [] }
        let missed = frameCounter - frame
        if missed > UInt64(Self.replayedFrames) {
            OWELog.debug(.scene, "\(wallpaperID): script calls came back \(missed) frames late; replaying the last \(Self.replayedFrames)")
        }
        let count = Int(min(missed, UInt64(Self.replayedFrames)))
        return ((frameCounter - UInt64(count) + 1)...frameCounter).map {
            recentDeltas[Int($0 % UInt64(Self.replayedFrames))]
        }
    }

    // MARK: - Textures

    /// The sprite frame an effect or material binding the animated `texture` draws this frame
    /// (`SceneTextureAnimations.boundFrame`). `delta` is the engine frame time.
    func boundTextureFrame(texture: String, frameTimes: () -> [Float], delta: Float) -> Int32 {
        textures.boundFrame(texture: texture, frameTimes: frameTimes, tick: frameCounter, delta: delta)
    }

    /// The sprite frame layer `id` draws this frame: its texture's shared clock (advanced once per
    /// `advance(by:)` by whichever layer draws it first) or the script's override (advanced by
    /// `advance(by:)`). `delta` is the engine frame time.
    func drawnTextureFrame(object id: Int, delta: Float) -> Int32? {
        textures.drawnFrame(object: id, tick: frameCounter, delta: delta)
    }
}
