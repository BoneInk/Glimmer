import Foundation

/// How fast a scene's picture changes this frame (efficiency-plan-2d notes WP2-C), slowest first.
enum FrameDemand: Int, Comparable, CaseIterable {
    /// Nothing visible changed: the frame is neither encoded nor presented.
    case idle
    /// A one-off change (a property edit, a script writing a clock's text): drawn, at a low rate.
    case slow
    /// Motion that goes on by itself: time-driven shaders, timelines, video, audio, particles, and
    /// scripts that change the layers frame after frame.
    case smooth
    /// Follows the cursor (and the camera parallax it drives): the most the display and the
    /// user's frame-rate limit allow.
    case interactive

    static func < (lhs: FrameDemand, rhs: FrameDemand) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The Quality↔Efficiency slider (Settings › Performance): 5 stops, 1 the quality end, 5 the
/// efficiency end, 4 by default. It caps the rate of smooth motion and of slow content, and says
/// how far blur-like passes and upscaling may reduce their resolution. WE's quality presets set it.
struct QualityEfficiency: Equatable {
    static let stops = 1...5
    static let defaultStop = 4

    let stop: Int

    init(stop: Int = QualityEfficiency.defaultStop) {
        self.stop = min(Self.stops.upperBound, max(Self.stops.lowerBound, stop))
    }

    /// The stop a WE quality preset (`GlobalSettingsViewModel.setQuality`) sets.
    init(preset: GSQuality) {
        switch preset {
        case .ultra: self.init(stop: 1)
        case .high: self.init(stop: 2)
        case .medium: self.init(stop: 4)
        case .low: self.init(stop: 5)
        }
    }

    /// The rate smooth motion is capped at; nil for the display's (and the user's) limit.
    var smoothRateCap: Int? {
        switch stop {
        case 1: return nil
        case 2, 3: return 60
        default: return 30
        }
    }

    /// The rate slow content (and an idle scene that can change on its own) is sampled at.
    var slowRate: Int {
        switch stop {
        case 1, 2: return 30
        case 3, 4: return 15
        default: return 10
        }
    }

    /// The divisor of a blur, bloom, glow or god-ray pass's size (1 full, 2 half, 4 quarter),
    /// for `EffectResolutionPolicy` (WP3-C).
    var blurResolutionDivisor: Int {
        switch stop {
        case 1, 2: return 1
        case 3, 4: return 2
        default: return 4
        }
    }
}

/// What the frame's analysis saw, for `FramePacing.classify`.
struct FrameDemandInputs: Equatable {
    /// Some visible layer is dirty this frame.
    var anyDirty = false
    /// The union, over the dirty layers, of their dependencies that changed this frame.
    var dirtyDependencies: SceneLayerDependencies = []
    /// The cursor moved since the last frame.
    var pointerMoved = false
    /// The camera parallax moved (it eases after the cursor, and camera shake moves it too).
    var parallaxMoved = false
    /// Frame-wide stages that change on their own run (camera fade or path, volumetrics, models).
    var sceneStagesAnimate = false
    /// A visible particle system runs (particles are not layers of the analysis).
    var particlesLive = false
    /// A visible particle system has a control point on the cursor.
    var particlesFollowCursor = false

    /// Built from the layer analysis after its `update`. `sceneWide` changes set every bit of
    /// `changed`, so the cursor and parallax bits only count when they really moved.
    init(analysis: SceneLayerAnalysis, pointerMoved: Bool, parallaxMoved: Bool, particlesLive: Bool,
         particlesFollowCursor: Bool) {
        var union: SceneLayerDependencies = []
        if analysis.anyDirty {
            let changed = analysis.changed
            for (index, dirty) in analysis.dirty.enumerated() where dirty {
                union.formUnion(analysis.layers[index].dependencies.intersection(changed))
            }
        }
        if !pointerMoved { union.remove(.cursor) }
        if !parallaxMoved { union.remove(.parallax) }
        self.init(anyDirty: analysis.anyDirty, dirtyDependencies: union, pointerMoved: pointerMoved,
                  parallaxMoved: parallaxMoved, sceneStagesAnimate: analysis.sceneStagesAnimate, particlesLive: particlesLive,
                  particlesFollowCursor: particlesFollowCursor)
    }

    init(anyDirty: Bool = false, dirtyDependencies: SceneLayerDependencies = [], pointerMoved: Bool = false,
         parallaxMoved: Bool = false, sceneStagesAnimate: Bool = false, particlesLive: Bool = false, particlesFollowCursor: Bool = false) {
        self.anyDirty = anyDirty
        self.dirtyDependencies = dirtyDependencies
        self.pointerMoved = pointerMoved
        self.parallaxMoved = parallaxMoved
        self.sceneStagesAnimate = sceneStagesAnimate
        self.particlesLive = particlesLive
        self.particlesFollowCursor = particlesFollowCursor
    }
}

/// Adaptive frame rate and idle skipping for one scene (efficiency-plan-2d notes WP2-C, item 9).
///
/// Each frame the renderer classifies what changed (`classify`) and asks whether to draw
/// (`record`): an idle frame is neither encoded nor presented, and the display keeps the last one.
/// The rate the displays tick at (`targetRate`) follows the fastest demand at once and falls only
/// after `rampDownDelay` of lower demand, so a pause in motion never stutters. The displays tick
/// at a divisor of their refresh rate (`cadence`), capped by the user's FPS setting, the slider
/// (`QualityEfficiency`) and the power policy (N10). Events that change the picture (a cursor
/// move, a property edit) wake it with `wake`.
///
/// Owned by the renderer: only on its render thread, like the renderer's draw.
struct FramePacing: Equatable {
    /// Lower demand must last this long before the rate falls.
    static let rampDownDelay: Double = 1
    /// The rate an idle scene that only changes on events (no clock, scripts, audio or particles)
    /// still samples at, for the changes no event announces (a pipeline landing).
    static let eventOnlyProbeRate = 5

    struct Limits: Equatable {
        /// WE's FPS setting.
        var userLimit = 30
        var policy = QualityEfficiency()
        /// The user set `userLimit` themselves: smooth motion runs at it, past the stop's cap.
        var userLimitWins = false
        /// The power policy's cap (N10: 30 at `.critical`), nil for none.
        var powerCap: Int?
    }

    var limits = Limits()
    /// The scene can change without an event: its clock drives something, scripts run, it reacts
    /// to audio, or particles run. Such a scene samples at the slow rate while idle.
    var changesOnItsOwn = true

    /// The demand the rate follows now (a new scene draws at its fastest until it settles).
    private(set) var level: FrameDemand = .interactive
    /// Since when demand has stayed below `level`, and the most it reached meanwhile.
    private var lowerSince: Double?
    private var lowerPeak: FrameDemand = .idle
    /// The last frame's changes included scripts: a script change two frames running is motion.
    private var scriptsChangedLastFrame = false

    // MARK: - Per frame

    /// The frame's demand from its analysis. Scripts count as motion only when they change the
    /// scene two frames running; a lone change (a clock's text) is slow content.
    mutating func classify(_ inputs: FrameDemandInputs) -> FrameDemand {
        let scriptsChanged = inputs.dirtyDependencies.contains(.script)
        defer { scriptsChangedLastFrame = scriptsChanged }
        if inputs.pointerMoved,
           !inputs.dirtyDependencies.isDisjoint(with: [.cursor, .parallax]) || inputs.particlesFollowCursor {
            return .interactive
        }
        if inputs.sceneStagesAnimate || inputs.particlesLive { return .smooth }
        guard inputs.anyDirty else { return .idle }
        if !inputs.dirtyDependencies.isDisjoint(with: Self.continuous) { return .smooth }
        if scriptsChanged, scriptsChangedLastFrame { return .smooth }
        return .slow
    }

    /// The dependencies that change frame after frame while they change at all. Parallax that
    /// moves with no cursor move is easing or shaking: smooth, not interactive.
    static let continuous: SceneLayerDependencies = [.time, .video, .audio, .shake, .timeline, .particles, .frameBeneath,
                                                     .parallax]

    /// Records `demand` at `now` (seconds) and returns whether the frame is drawn. The rate rises
    /// to a higher demand at once, and falls to the most that was asked for over the last
    /// `rampDownDelay` once that long has passed below `level`.
    @discardableResult
    mutating func record(_ demand: FrameDemand, at now: Double) -> Bool {
        raise(to: demand, at: now)
        return demand != .idle
    }

    /// Something that changes the picture happened (`demand`): the rate goes to it at once, so the
    /// next tick comes within one refresh at `.interactive`.
    mutating func wake(_ demand: FrameDemand, at now: Double) {
        raise(to: demand, at: now)
    }

    private mutating func raise(to demand: FrameDemand, at now: Double) {
        if demand >= level {
            level = demand
            lowerSince = nil
            lowerPeak = .idle
            return
        }
        guard let since = lowerSince else {
            lowerSince = now
            lowerPeak = demand
            return
        }
        lowerPeak = max(lowerPeak, demand)
        if now - since >= Self.rampDownDelay {
            level = lowerPeak
            // The next step down needs another quiet second.
            lowerSince = level > demand ? now : nil
            lowerPeak = demand
        }
    }

    // MARK: - Rates

    /// The rate the displays should tick at now, before each display rounds it to its cadence.
    var targetRate: Int { rate(for: level) }

    /// The rate `demand` asks for, within the limits.
    func rate(for demand: FrameDemand) -> Int {
        let user = max(1, limits.userLimit)
        var rate: Int
        switch demand {
        case .interactive: rate = user
        case .smooth: rate = limits.userLimitWins ? user : min(user, limits.policy.smoothRateCap ?? user)
        case .slow: rate = min(user, limits.policy.slowRate)
        case .idle: rate = min(user, changesOnItsOwn ? limits.policy.slowRate : Self.eventOnlyProbeRate)
        }
        if let cap = limits.powerCap { rate = min(rate, cap) }
        return max(1, rate)
    }

    /// The rate a display of `refreshRate` Hz ticks at for `target`: its refresh divided by the
    /// smallest whole divisor that doesn't exceed `target`, so every frame lasts the same number of
    /// refreshes (`CADisplayLink` cadence).
    static func cadence(_ target: Int, refreshRate: Int) -> Int {
        guard refreshRate > 0 else { return max(1, target) }
        guard target < refreshRate else { return refreshRate }
        let divisor = (refreshRate + max(1, target) - 1) / max(1, target)
        return max(1, refreshRate / divisor)
    }
}

extension FramePacing.Limits {
    /// The display's refresh bounds an unlimited FPS setting (`cadence`); this stands for it.
    static let unlimitedRate = 1000

    /// The user's FPS setting and slider stop, moved towards efficiency by thermal state and Low
    /// Power Mode (N10: `PowerPolicy.effectiveStop`, and 30 fps at `.critical`). An FPS the user
    /// set themselves wins over the stop's smooth-motion cap unless power moves the stop.
    init(_ settings: GlobalSettings, power: PowerPolicy) {
        self.init(userLimit: settings.fps >= GlobalSettings.unlimitedFPS ? Self.unlimitedRate : Int(settings.fps.rounded()),
                  policy: QualityEfficiency(stop: power.effectiveStop(settings.qualityEfficiency)),
                  userLimitWins: settings.fpsSetByUser && power.efficiencySteps == 0,
                  powerCap: power.frameRateCap)
    }
}

extension FramePacing {
    /// Whether a scene can change with no event: a layer follows the clock, audio, video, a
    /// timeline or scripts, frame-wide stages animate, particles run, or the camera shakes.
    static func changesOnItsOwn(_ analysis: SceneLayerAnalysis, particles: Bool, cameraShake: Bool) -> Bool {
        let selfDriven: SceneLayerDependencies = [.time, .audio, .video, .timeline, .script]
        return particles || cameraShake || analysis.sceneStagesAnimate
            || analysis.layers.contains { !$0.dependencies.isDisjoint(with: selfDriven) }
    }
}
