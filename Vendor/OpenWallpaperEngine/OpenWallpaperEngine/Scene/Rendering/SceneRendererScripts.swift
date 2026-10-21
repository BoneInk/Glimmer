import Foundation
import simd

/// The renderer's side of SceneScript (docs/scenescript-plan.md WP11): owns the wallpaper
/// instance's `SceneScriptWallpaper`, runs a script frame before each draw (`submit`, then
/// `finishFrame`), keeps the state its last frame left, and answers the
/// renderer's questions about it (is an object visible, where is it, what does its text say, in
/// which order is it drawn). Main thread, like the renderer.
final class SceneRendererScripts {
    /// The app-wide script services; nil runs no scripts (tests that don't need them).
    let services: SceneScriptServices?
    /// The display this renderer draws on (`localStorage` `'screen'`, logs).
    let screenID: String
    /// Told once, on the main thread, when the watchdog stopped this wallpaper's scripts.
    var onHalt: ((SceneScriptError?) -> Void)?

    private(set) var wallpaper: SceneScriptWallpaper?
    private(set) var state = SceneScriptFrameState()
    /// The render thread's share of the scripts' cost: taking their state and handing them the
    /// frame, in milliseconds of CPU time, every frame (bounded), for measurements.
    private(set) var bridgeMilliseconds: [Double] = []
    private var content: SceneScriptSceneContent?
    /// Base (authored or user-bound) `visible` of every object, by id.
    private var baseVisibility: [String: Bool] = [:]
    /// Objects' parents, for visibility.
    private var parents: [String: String] = [:]
    /// User-bound effects' `visible` since the content was built, by object id and effect index
    /// (`applyUserVisibility`); an effect not in it keeps its plan's.
    private var userEffectVisibility: [String: [Int: Bool]] = [:]
    /// Bumped by every `applyUserVisibility`, so effect chains kept as static are drawn again.
    private(set) var userVisibilityRevision = 0
    private var lastScreenSize: SIMD2<Double>?
    /// Whether the last `submit` started a script frame (`finishFrame` waits only for that).
    private var frameSubmitted = false
    /// How long a draw waits for its script frame (`SceneScriptWallpaper.Timing.frameWait`; tests
    /// on a loaded machine wait longer).
    var frameWait = SceneScriptWallpaper.Timing.frameWait
    /// The renderer's builder for created objects, handed to each new `SceneScriptWallpaper`.
    var prepareCreated: SceneScriptWallpaper.PrepareCreated?
    /// The Wallpaper Editor's Stop Preview: content set while it holds runs no scripts (fields keep
    /// their authored values); the next content after it ends starts them again.
    var isSuspended = false

    init(services: SceneScriptServices?, screenID: String) {
        self.services = services
        self.screenID = screenID
    }

    // MARK: - Content

    /// Runs the scripts of new content: keeps the running scripts when the content was rebuilt
    /// from the same document (a user property changed a layer; scripts go on, as in WE), starts
    /// new ones otherwise. Nil stops them.
    func setContent(_ content: SceneScriptSceneContent?, visibility: [String: Bool], parents: [String: String]) {
        baseVisibility = visibility
        self.parents = parents
        userEffectVisibility = [:]
        if !isSuspended, let wallpaper, let content, wallpaper.identity.wallpaperID == content.wallpaperID,
           wallpaper.documentSignature == content.documentSignature {
            self.content = content
            return
        }
        stop()
        self.content = content
        guard let content, let services, !isSuspended else { return }
        do {
            let started = try SceneScriptWallpaper(content: content, services: services, screenID: screenID,
                                                   prepareCreated: prepareCreated)
            started?.onHalt = { [weak self] error in self?.onHalt?(error) }
            wallpaper = started
        } catch {
            OWELog.error(.script, "\(content.wallpaperID): scripts are off: \(error)")
        }
    }

    /// Stops the scripts (their `destroy()` runs on the script thread) and forgets their state.
    func stop() {
        wallpaper?.tearDown()
        wallpaper = nil
        content = nil
        state = SceneScriptFrameState()
        lastScreenSize = nil
    }

    /// Builds an object a script created, through the loader. Off the main thread.
    var makeLayer: (([String: SceneJSON]) -> SceneScriptCreatedObject?)? { content?.makeLayer }

    // MARK: - Frame

    /// The state the scripts' last finished frame left, and the structural changes since.
    func beginFrame() -> [SceneScriptRenderEvent] {
        guard let wallpaper else { return [] }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let taken = wallpaper.take()
        if let latest = taken.state { state = latest }
        record(since: start)
        return taken.events
    }

    /// Adds render-thread CPU time since `start` to this frame's bridge cost (`bridgeMilliseconds`).
    func record(since start: UInt64, newFrame: Bool = true) {
        let milliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        if newFrame {
            if bridgeMilliseconds.count >= SceneScriptWallpaper.Timing.recentLimit { bridgeMilliseconds.removeFirst() }
            bridgeMilliseconds.append(milliseconds)
        } else if !bridgeMilliseconds.isEmpty {
            bridgeMilliseconds[bridgeMilliseconds.count - 1] += milliseconds
        }
    }

    /// Hands this frame's inputs to the scripts and starts their next frame, unless the last one is
    /// still running. The first display size is the environment's; a later change is a `resizeScreen`.
    func submit(_ input: SceneScriptFrameInput) {
        guard let wallpaper else { return }
        let size = input.environment.screenResolution
        if let lastScreenSize, lastScreenSize != size { wallpaper.screenDidResize(width: size.x, height: size.y) }
        lastScreenSize = size
        frameSubmitted = wallpaper.submit(input)
    }

    /// Waits, at most `wait` seconds, for the script frame `submit` started, then takes its state
    /// like `beginFrame`. A frame that overruns is taken by a later draw; a skipped one (the last
    /// is still running, e.g. a hung script) isn't waited for.
    func finishFrame(waitingUpTo wait: TimeInterval) -> [SceneScriptRenderEvent] {
        guard let wallpaper else { return [] }
        if frameSubmitted {
            frameSubmitted = false
            wallpaper.waitForSubmittedFrame(timeout: wait)
        }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let taken = wallpaper.take()
        if let latest = taken.state { state = latest }
        record(since: start, newFrame: false)
        return taken.events
    }

    /// `applyUserProperties` for changed user properties.
    func userPropertiesDidChange(_ names: Set<String>) {
        wallpaper?.userPropertiesDidChange(names)
    }

    var isRunning: Bool { wallpaper != nil }

    // MARK: - Reads

    /// What scripts left in object `id`, if they touched it.
    func object(_ id: String) -> SceneScriptObjectState? {
        guard !state.objects.isEmpty, let key = Int(id) else { return nil }
        return state.objects[key]
    }

    /// Whether object `id` is drawn: its own `visible` (a script's, else its base) and every
    /// parent's (WE hides a hidden object's children).
    func isVisible(_ id: String, base: Bool? = nil) -> Bool {
        var current: String? = id
        var visited = Set<String>()
        while let object = current, visited.insert(object).inserted {
            let own = self.object(object)?.flag(.visible) ?? (object == id ? base : nil) ?? baseVisibility[object] ?? true
            if !own { return false }
            current = parents[object]
        }
        return true
    }

    /// `ILayer.setParent`: object `id`'s visibility follows `parent` (nil: its own alone).
    func setParent(_ parent: String?, for id: String) {
        parents[id] = parent
    }

    /// Records the base `visible` of an object scripts created.
    func setBaseVisibility(_ visible: Bool, for id: String) {
        baseVisibility[id] = visible
    }

    func baseVisible(_ id: String) -> Bool { baseVisibility[id] ?? true }

    /// The user's visibility of the scene's objects and effects after a property change
    /// (`SceneUserVisibility.resolve`): objects' base `visible` and bound effects' `visible`,
    /// without a content rebuild.
    func applyUserVisibility(objects: [String: Bool], effects: [String: [Int: Bool]]) {
        baseVisibility.merge(objects) { _, new in new }
        userEffectVisibility = effects
        userVisibilityRevision &+= 1
    }

    /// A text layer's configuration with what scripts set (`SceneMetalText.scripted(by:)`), its
    /// string and its `pointsize`.
    func text(_ text: SceneMetalText, of id: String) -> (text: SceneMetalText, value: String, pointSize: Float?) {
        guard let object = object(id) else { return (text, text.value, nil) }
        let pointSize = object.scalar(.pointsize).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (text.scripted(by: object), object.strings[.text] ?? text.value, pointSize)
    }

    /// The effect graph's view of a layer's effects this frame: which are hidden (a script's
    /// `visible`, else the user's, else the plan's) and the constants scripts set. The revision
    /// changes whenever either does.
    func effects(_ plans: [SceneEffectPlan], of id: String) -> (hidden: Set<Int>, writes: [Int: [SceneScriptConstantWrite]], revision: Int) {
        let object = object(id)
        let user = userEffectVisibility[id]
        var hidden = Set<Int>()
        for (index, plan) in plans.enumerated()
        where !(object?.effectVisible[plan.effectIndex] ?? user?[plan.effectIndex] ?? plan.visible) {
            hidden.insert(index)
        }
        // Both only grow, so their sum changes whenever either does.
        return (hidden, object?.constants ?? [:], (object?.effectRevision ?? 0) &+ userVisibilityRevision)
    }

    // MARK: - Draw order

    /// Layers in draw order and, for each, the particle systems to draw before it (the
    /// `before` argument of the renderer's particle batches: every system whose authored order is
    /// below it). Without script changes to the order, the scene's own.
    /// `layers` are (id, authored order); `systems` are (object id, authored order).
    static func drawOrder(layers: [(id: String, order: Int)], systems: [(id: String?, order: Int)],
                          scriptOrder: [Int]?) -> (sequence: [Int], barriers: [Int]) {
        guard let scriptOrder else {
            let sequence = layers.indices.sorted { (layers[$0].order, $0) < (layers[$1].order, $1) }
            return (sequence, sequence.map { layers[$0].order })
        }
        var position: [String: Int] = [:]
        for (index, id) in scriptOrder.enumerated() { position[String(id)] = index }
        func place(_ id: String?, _ order: Int) -> Int { id.flatMap { position[$0] } ?? order }
        let sequence = layers.indices.sorted {
            (place(layers[$0].id, layers[$0].order), $0) < (place(layers[$1].id, layers[$1].order), $1)
        }
        let placedSystems = systems.map { (place($0.id, $0.order), $0.order) }.sorted { $0.0 < $1.0 }
        var barriers: [Int] = []
        var next = 0
        var barrier = Int.min
        for index in sequence {
            let at = place(layers[index].id, layers[index].order)
            while next < placedSystems.count, placedSystems[next].0 < at {
                barrier = max(barrier, placedSystems[next].1 + 1)
                next += 1
            }
            barriers.append(barrier)
        }
        return (sequence, barriers)
    }
}
