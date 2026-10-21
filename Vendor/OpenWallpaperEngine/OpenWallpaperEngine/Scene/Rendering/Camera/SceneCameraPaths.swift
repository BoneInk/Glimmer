import simd

/// The scene's camera paths (`camera.paths`), played as `wallpaper64.exe` plays them in its camera
/// update (0x1401894a9…0x140189b07) while no camera layer is active; docs/models-plan.md §2.2.
///
/// State is WE's: the path (+0xe4), the key (+0xe8) and the time since the path started (+0xec).
/// Each frame the camera is sampled at the time, then the time advances:
///
/// - At or after key k's timestamp, with a key k + 1: every component of the eye, centre, up and
///   zoom is `p0 + (p1 − p0)·h(t)`, `h(t) = 0.5t + 1.5t² − t³` (a cubic Hermite whose tangents
///   are both (p1 − p0)/2), t the time's fraction between the two timestamps. The segment ends at
///   k + 1's timestamp.
/// - At the last key: its values; the segment "ends" at the duration minus its timestamp.
/// - Before key k's timestamp (a first key after 0): its values; the segment ends at the sum of
///   its timestamp and the next one's (0 without one). Both ends are WE's arithmetic as it is.
///
/// Once the advanced time passes the segment's end the next key takes over when there is one
/// before the duration; otherwise the next path starts at time 0, after the last the first.
struct SceneCameraPaths {
    let paths: [WESceneCameraPath]
    private(set) var pathIndex = 0
    private(set) var keyIndex = 0
    /// Seconds since the current path started.
    private(set) var time: Float = 0

    /// Paths without a key can't be played; WE would read past its key list [I: the library has none].
    init(_ paths: [WESceneCameraPath]) {
        self.paths = paths.filter { !$0.keys.isEmpty }
    }

    var isEmpty: Bool { paths.isEmpty }

    /// `h(t)` of the Hermite between two keys.
    static func hermiteWeight(_ t: Float) -> Float {
        0.5 * t + 1.5 * t * t - t * t * t
    }

    static func interpolate(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, weight: Float) -> SIMD3<Float> {
        p0 + (p1 - p0) * weight
    }

    /// This frame's camera, then the time advanced by `deltaTime`; nil without a path.
    mutating func advance(by deltaTime: Float) -> SceneCameraPose? {
        guard !paths.isEmpty else { return nil }
        let path = paths[pathIndex]
        let keys = path.keys
        let first = keys[keyIndex]
        let hasNext = keyIndex + 1 < keys.count
        var pose = Self.pose(first)
        let end: Float
        if time >= first.timestamp {
            if hasNext {
                let next = keys[keyIndex + 1]
                let span = next.timestamp - first.timestamp
                // Two keys at one time: WE divides by zero; the first key holds here instead.
                let weight = span > 0 ? Self.hermiteWeight((time - first.timestamp) / span) : 0
                pose = SceneCameraPose(eye: Self.interpolate(first.eye, next.eye, weight: weight),
                                       center: Self.interpolate(first.center, next.center, weight: weight),
                                       up: Self.interpolate(first.up, next.up, weight: weight),
                                       zoom: first.zoom + (next.zoom - first.zoom) * weight)
                end = next.timestamp
            } else {
                end = path.duration - first.timestamp
            }
        } else {
            end = (hasNext ? keys[keyIndex + 1].timestamp : 0) + first.timestamp
        }
        time += deltaTime
        if time > end {
            if hasNext, path.duration > keys[keyIndex + 1].timestamp {
                keyIndex += 1
            } else {
                pathIndex = pathIndex + 1 < paths.count ? pathIndex + 1 : 0
                keyIndex = 0
                time = 0
            }
        }
        return pose
    }

    /// `camerafade` (0x140180c1a…0x140180c8c), after this frame's advance: the path fades from
    /// and to the fade colour over its first and last half second, `1 − 2·min(t, duration − t)`;
    /// 0 elsewhere, where WE draws no fade.
    var fade: Float {
        guard !paths.isEmpty else { return 0 }
        let duration = paths[pathIndex].duration
        let remaining = duration - time
        let alpha: Float
        if 0.5 > remaining {
            alpha = 1 - 2 * remaining
        } else if remaining > duration - 0.5 {
            alpha = 1 - 2 * time
        } else {
            alpha = 0
        }
        return max(alpha, 0)
    }

    private static func pose(_ key: WESceneCameraPath.Key) -> SceneCameraPose {
        SceneCameraPose(eye: key.eye, center: key.center, up: key.up, zoom: key.zoom)
    }
}
