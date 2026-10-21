import Foundation

/// The capture half of WE's audio spectrum: blocks of PCM in, 64 raw band values per channel out.
/// It follows `wallpaper64.exe`'s capture thread (`0x1400d02b0`, set up by `0x1400cf120` from the
/// audio processor constructed at `0x1400c0c80`):
///
/// - Block length L = int(max(sampleRate / 44100, 1) · 64 · 30): 1920 samples at 44.1 kHz, 2089
///   at 48 kHz. Blocks don't overlap. The capture packet that completes a block is not carried
///   over: WE drops the rest of that WASAPI packet.
/// - Each sample s becomes the complex value (127 + 127·s) + i / (127 + 127·s), and one forward
///   DFT of length L runs per channel. (The imaginary part adds nothing audible; it is WE's.)
/// - For bin b in 1..<N, N = int(10 · 64) = 640 (so bins up to 640 · 23 Hz ≈ 14.7 kHz):
///   - power p = re² + im², or 0 when not finite;
///   - t = (b − 1) / (N − 1); band = int(t^0.25 · 64) mod 64 (t < 1, so the modulo never
///     wraps), but at most one past the previous bin's band, so the lowest 16 bands get a bin each;
///   - weight w = 0.501 − 0.499 · cos(π·t), rising from 0.002 at the bottom to 1 at the top;
///   - band value = the maximum over its bins of √(w·p).
/// - Values are scaled by the input volume (WE's "Recording volume", `audioinputvolume`, 0…200,
///   default 50 → 1) · 0.001 · N / (L/2).
///
/// Left then right, 64 each. A mono source passes the same samples for both.
///
/// WE's "Recording threshold" (`audioinputthreshold`, 0…10, default 0 = off) gates the capture
/// before the DFT (`0x1400d1a15`…`0x1400d1ae5`): the setting × 0.001 is a sample amplitude (so 10
/// is −40 dBFS). When it is above `Float.ulpOfOne` and the highest first-channel sample of a capture
/// packet, max(0, max(s)), the raw signed value rather than its magnitude, is below it, WE publishes
/// an all-zero spectrum and drops the block being collected (`0x1400d1f25`). Audio-thread only.
final class AudioSpectrumBlockTransform {
    static let bandCount = 64
    /// DFT bins scanned: WE's 10 (at `processor + 0xf8`) × 64.
    static let binCount = 640
    /// `processor + 0xf4`: the block length factor at 44.1 kHz, × 64.
    static let blockFactor: Float = 30
    static let bandExponent: Float = 0.25
    static let weightAlpha: Float = 0.501
    static let sampleOffset: Float = 127

    let blockLength: Int
    /// `audioinputvolume` × 0.02 (`inputVolume(setting:)`).
    var inputVolume: Float = 1
    /// `audioinputthreshold` × 0.001 (`threshold(setting:)`): the sample level a packet must reach.
    var threshold: Float = 0

    /// The gate's sample level for WE's threshold setting (0…10).
    static func threshold(setting: Double) -> Float { Float(max(setting, 0)) * 0.001 }

    /// WE's "Recording volume" default (`audioinputvolume` 50, a scale of 1).
    static let defaultVolumeSetting: Double = 50
    /// The band scale for WE's "Recording volume" setting (0…200 in its slider): × 0.02, so the
    /// default 50 is 1 and 200 boosts four times.
    static func inputVolume(setting: Double) -> Float { Float(max(setting, 0)) * 0.02 }

    private let dft: BluesteinDFT
    private let bandOfBin: [Int]
    private let weightOfBin: [Float]
    private var left: [Float]
    private var right: [Float]
    private var fill = 0
    private var real: [Float]
    private var imaginary: [Float]
    private var power = [Float](repeating: 0, count: AudioSpectrumBlockTransform.binCount)

    init?(sampleRate: Double) {
        let length = Self.blockLength(sampleRate: sampleRate)
        guard length > Self.binCount, let dft = BluesteinDFT(length: length, bins: Self.binCount) else { return nil }
        blockLength = length
        self.dft = dft
        bandOfBin = Self.bandMap()
        weightOfBin = Self.weights()
        left = [Float](repeating: 0, count: length)
        right = [Float](repeating: 0, count: length)
        real = [Float](repeating: 0, count: length)
        imaginary = [Float](repeating: 0, count: length)
    }

    static func blockLength(sampleRate: Double) -> Int {
        let ratio = max(Float(sampleRate) / 44_100, 1)
        return Int(ratio * 64 * blockFactor)
    }

    /// The band of every bin 1..<`binCount` (index 0 is unused and 0).
    static func bandMap() -> [Int] {
        var bands = [Int](repeating: 0, count: binCount)
        let last = Float(binCount - 1)
        var previous = 0
        for bin in 1..<binCount {
            let t = Float(bin - 1) / last
            let band = Int(pow(t, bandExponent) * Float(bandCount)) % bandCount
            previous = min(band, previous + 1)
            bands[bin] = previous
        }
        return bands
    }

    /// The weight of every bin 1..<`binCount`.
    static func weights() -> [Float] {
        var weights = [Float](repeating: 0, count: binCount)
        let step = 1 / Float(binCount - 1)
        let beta = 1 - weightAlpha
        for bin in 1..<binCount {
            weights[bin] = weightAlpha - cos(Float(bin - 1) * Float.pi * step) * beta
        }
        return weights
    }

    func reset() {
        fill = 0
    }

    /// Appends one capture buffer. Returns the 128 raw values (left 64, right 64) when it completes
    /// a block; the rest of that buffer is dropped. A buffer below `threshold` returns 128 zeros
    /// and drops the block collected so far.
    func append(left newLeft: UnsafeBufferPointer<Float>, right newRight: UnsafeBufferPointer<Float>) -> [Float]? {
        let count = min(newLeft.count, newRight.count)
        guard count > 0 else { return nil }
        if threshold > Float.ulpOfOne {
            var peak: Float = 0
            for index in 0..<count where newLeft[index] > peak { peak = newLeft[index] }
            if threshold > peak {
                fill = 0
                return [Float](repeating: 0, count: 2 * Self.bandCount)
            }
        }
        let taken = min(count, blockLength - fill)
        for index in 0..<taken {
            left[fill + index] = newLeft[index]
            right[fill + index] = newRight[index]
        }
        fill += taken
        guard fill == blockLength else { return nil }
        fill = 0
        return spectrum(left: left, right: right)
    }

    /// The raw values of one full block (`blockLength` samples per channel).
    func spectrum(left: [Float], right: [Float]) -> [Float] {
        var values = [Float](repeating: 0, count: 2 * Self.bandCount)
        bands(of: left, into: &values, offset: 0)
        bands(of: right, into: &values, offset: Self.bandCount)
        let scale = inputVolume * 0.001 * (Float(Self.binCount) / (Float(blockLength) * 0.5))
        for index in values.indices { values[index] *= scale }
        return values
    }

    private func bands(of samples: [Float], into values: inout [Float], offset: Int) {
        for n in 0..<blockLength {
            let value = samples[n] * Self.sampleOffset + Self.sampleOffset
            real[n] = value
            imaginary[n] = 1 / value
        }
        dft.powerSpectrum(real: real, imaginary: imaginary, into: &power)
        for bin in 1..<Self.binCount {
            let binPower = power[bin].isFinite ? power[bin] : 0
            let magnitude = (weightOfBin[bin] * binPower).squareRoot()
            let slot = offset + bandOfBin[bin]
            values[slot] = max(values[slot], magnitude)
        }
    }
}
