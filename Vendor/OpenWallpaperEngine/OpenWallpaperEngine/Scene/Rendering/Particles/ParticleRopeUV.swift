import simd

/// How a `rope` lays its texture along the particles, and a `ropetrail`'s scrolling: the renderer's
/// `uvscale` (1), `uvsmoothing` (true, read only without scrolling) and `uvscrolling` (false),
/// parsed at `wallpaper64.exe` 0x1401d8db0 / 0x1401c0c90 (`[definition+0x18]` = 1 / uvscale, system
/// flags 0x20000 rope scrolling, 0x40000 smoothing, 0x80000 ropetrail scrolling).
///
/// A rope's segment records carry its point count and each point's place along it, which
/// `genericropeparticle.vert` turns into `v = 1 − place / (count − 1)`. WE's rope builder
/// (0x14023099e…0x140230a84) writes them from what the rope should hold:
///
/// - expected points E = rate × lifetime, from the first emitter with a rate and the first
///   `lifetimerandom`'s middle (the parser keeps both, 0x1401c6ac8 / 0x1401c72e5), with the
///   instance overrides; while the rope fills (E above its points) the rate is capped at the
///   frame-rate limit.
/// - scrolling: the count is E − 1 and every place is shifted by the particles that died so far, so
///   the texture moves with the particles.
/// - otherwise the count is the points, but with smoothing, once the rope holds E − 1 points or more,
///   the count is E − 1 and the places shift by `saturate((lifetime − oldest age) × rate) − 1`, so
///   the texture slides as the oldest point nears its death instead of jumping.
/// - the count is then divided by `uvscale`, which repeats the texture along the rope.
struct ParticleRopeUV: Equatable {
    /// 1 / `uvscale`.
    var inverseScale: Float = 1
    var smoothing = true
    var scrolling = false
    /// The first emitter's rate that isn't 0, and the first `lifetimerandom`'s middle; 0 without.
    var rate: Float = 0
    var lifetime: Float = 0

    init() {}

    init(_ renderer: WEParticleRenderer?, rate: Float, lifetime: Float) {
        let scale = Float(renderer?.uvscale ?? 1)
        inverseScale = scale != 0 ? 1 / scale : 1
        scrolling = renderer?.uvscrolling ?? false
        smoothing = scrolling ? false : (renderer?.uvsmoothing ?? true)
        self.rate = rate
        self.lifetime = lifetime
    }

    /// A strand's point count and the shift of its places (`ParticleRopeSegmentInstance.end.w` and
    /// `previous.w` − index), for `points` points whose oldest is `oldestAge` seconds old, when
    /// `died` particles died so far. `rateScale` and `lifetimeScale` are the instance overrides;
    /// `frameRateLimit` the setting (`ParticleFrameInputs.frameRateLimit`).
    func layout(points: Int, oldestAge: Float, died: UInt32, rateScale: Float, lifetimeScale: Float,
                frameRateLimit: Int) -> (count: Float, shift: Float) {
        let alive = Float(points)
        var rate = self.rate * rateScale
        let lifetime = self.lifetime * lifetimeScale
        if rate * lifetime > alive { rate = min(Float(frameRateLimit), rate) }
        let expected = rate * lifetime
        var count = alive, shift: Float = 0
        if scrolling {
            count = expected - 1
            shift = Float(died)
        } else if expected > 0, alive >= expected - 1, smoothing {
            count = expected - 1
            shift = min(max((lifetime - oldestAge) * rate, 0), 1) - 1
        }
        return (count * inverseScale, shift)
    }
}
