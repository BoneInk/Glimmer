import Foundation

/// The render half of WE's audio spectrum: once per frame it turns the latest raw block (left 64,
/// right 64; `AudioSpectrumBlockTransform`) into the `g_AudioSpectrum*` / `registerAudioBuffers`
/// arrays. It follows `wallpaper64.exe`'s main loop (`0x140111654`–`0x140112b63`), which writes
/// the one buffer that both the shaders (`0x1400d9bc4`) and SceneScript (`0x14018e010`) read:
///
/// 1. rate = clamp(frame time, 0.0001, 0.25), the frame time scaled by the wallpaper's playback
///    rate (`AudioSpectrumClock.advanceFrame(playbackRate:)`).
/// 2. Peaks: the raw values in 16 groups of 8 (left bands 0–7, 8–15, …, then right), each group's
///    maximum raised to at least a third of the overall maximum. Silent unless the overall maximum
///    is at least 0.0001.
/// 3. Per-group gain: a level that follows the group's peak, up by at most `rate` a frame and
///    down by at most `rate / 2`; set outright once within 0.0001; reset to 1 when sound starts
///    while the first level is at most 0.0001. Values are divided by max(level, 0.001), so they are
///    normally 0…1 but can exceed 1, as WE's docs warn.
/// 4. Smoothing: s += (value − s) · min(20·rate, 1), then the output moves toward s by at most
///    min(40·rate, 1) a frame. Silence outputs zeros at once and freezes both.
/// 5. average = (left + right) / 2; 32 and 16 bands are the maximum of neighbouring pairs of the
///    next finer resolution, for left, right and average alike.
///
/// WE divides with `rcpps` (relative error below 4·10⁻⁴); this divides exactly.
struct AudioSpectrumSmoothing {
    static let groupCount = 16
    static let groupSize = 8
    static let silence: Float = 0.0001
    static let minimumLevel: Float = 0.001
    static let peakFloor: Float = 0.333

    private var levels = [Float](repeating: 0, count: groupCount)
    private var smoothed = [Float](repeating: 0, count: 2 * AudioSpectrumBlockTransform.bandCount)
    private var previous = [Float](repeating: 0, count: 2 * AudioSpectrumBlockTransform.bandCount)

    static func rate(deltaTime: Double) -> Float {
        min(max(Float(deltaTime), 0.0001), 0.25)
    }

    /// Advances one frame with the latest raw block (128 values) and returns the frame's arrays.
    mutating func advance(raw: [Float], deltaTime: Double) -> AudioSpectrumSnapshot {
        let count = 2 * AudioSpectrumBlockTransform.bandCount
        precondition(raw.count == count, "AudioSpectrumSmoothing needs 128 raw values")
        let rate = Self.rate(deltaTime: deltaTime)

        var peaks = [Float](repeating: 0, count: Self.groupCount)
        var overall: Float = 0
        for group in 0..<Self.groupCount {
            let start = group * Self.groupSize
            peaks[group] = raw[start..<(start + Self.groupSize)].reduce(0, max)
            overall = max(overall, peaks[group])
        }
        let floor = overall * Self.peakFloor
        for group in peaks.indices { peaks[group] = max(peaks[group], floor) }
        let sounding = overall >= Self.silence
        if sounding && levels[0] <= Self.silence {
            levels = [Float](repeating: 1, count: Self.groupCount)
        }
        let step = min(rate, 1)
        for group in levels.indices {
            let difference = peaks[group] - levels[group]
            if abs(difference) > Self.silence {
                levels[group] += min(step, abs(difference)) * (difference > 0 ? 1 : -0.5)
            } else {
                levels[group] = peaks[group]
            }
        }

        var output = [Float](repeating: 0, count: count)
        if sounding {
            let follow = min(rate * 20, 1)
            let rise = min(rate * 40, 1)
            let fall = max(rate * -40, -1)
            for index in 0..<count {
                let gain = 1 / max(levels[index / Self.groupSize], Self.minimumLevel)
                smoothed[index] += (raw[index] * gain - smoothed[index]) * follow
                let change = smoothed[index] - previous[index]
                output[index] = previous[index] + (change > 0 ? min(rise, change) : max(fall, change))
            }
            previous = output
        }
        return Self.snapshot(output)
    }

    /// Splits the 64-band output into WE's nine arrays.
    static func snapshot(_ output: [Float]) -> AudioSpectrumSnapshot {
        let bands = AudioSpectrumBlockTransform.bandCount
        let left64 = Array(output[0..<bands])
        let right64 = Array(output[bands..<(2 * bands)])
        let average64 = zip(left64, right64).map { ($1 + $0) * 0.5 }
        return AudioSpectrumSnapshot(
            left16: halve(halve(left64)), right16: halve(halve(right64)),
            left32: halve(left64), right32: halve(right64),
            left64: left64, right64: right64,
            average16: halve(halve(average64)), average32: halve(average64), average64: average64)
    }

    /// The maximum of each neighbouring pair.
    static func halve(_ values: [Float]) -> [Float] {
        (0..<(values.count / 2)).map { max(values[2 * $0 + 1], values[2 * $0]) }
    }
}
