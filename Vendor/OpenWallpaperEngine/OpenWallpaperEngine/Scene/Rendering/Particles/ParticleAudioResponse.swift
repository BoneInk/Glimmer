import simd

/// A particle element's audio response (`audioprocessing…`): how loud a band of the spectrum is,
/// mapped to 0…1. WE applies it to emitters' rate, `turbulentvelocityrandom`'s speed and the
/// speeds of `turbulence` and `vortex`.
struct ParticleAudioResponse: Equatable {
    enum Channel: Int { case left = 1, right, both }

    let channel: Channel
    /// Inclusive bin indices into the 16-bin spectrum.
    let firstBin: Int
    let lastBin: Int
    let bounds: SIMD2<Float>
    let exponent: Float

    /// Nil for mode 0 (off) or an unknown mode.
    init?(mode: Int?, exponent: Double?, bounds: SIMD2<Float>?, frequencyStart: Int?, frequencyEnd: Int?) {
        guard let mode, let channel = Channel(rawValue: mode) else { return nil }
        self.channel = channel
        firstBin = max(frequencyStart ?? 0, 0)
        lastBin = max(frequencyEnd ?? 1, firstBin)
        self.bounds = bounds ?? SIMD2(0.8, 1)
        self.exponent = Float(exponent ?? 2)
    }

    /// The response to `spectrum`: the band's loudest bin, smoothstepped between `bounds` and
    /// raised to `exponent`.
    func response(_ spectrum: AudioSpectrumSnapshot) -> Float {
        let left = spectrum.left16, right = spectrum.right16
        var level: Float = 0
        for bin in firstBin...lastBin {
            let l = bin < left.count ? left[bin] : 0
            let r = bin < right.count ? right[bin] : 0
            switch channel {
            case .left: level = max(level, l)
            case .right: level = max(level, r)
            case .both: level = max(level, (l + r) * 0.5)
            }
        }
        let range = bounds.y - bounds.x
        let t = range != 0 ? min(max((level - bounds.x) / range, 0), 1) : (level >= bounds.x ? 1 : 0)
        let smooth = t * t * (3 - 2 * t)
        return min(max(pow(smooth, exponent), 0), 1)
    }
}

extension ParticleAudioResponse {
    private static func bounds(_ value: WEFlexValue?) -> SIMD2<Float>? {
        guard let value else { return nil }
        let v = value.vectorValue
        return SIMD2(Float(v.0), Float(v.1))
    }

    init?(_ emitter: WEParticleEmitter) {
        self.init(mode: emitter.audioprocessingmode, exponent: emitter.audioprocessingexponent,
                  bounds: Self.bounds(emitter.audioprocessingbounds),
                  frequencyStart: emitter.audioprocessingfrequencystart, frequencyEnd: emitter.audioprocessingfrequencyend)
    }

    init?(_ initializer: WEParticleInitializer) {
        self.init(mode: initializer.audioprocessingmode, exponent: initializer.audioprocessingexponent,
                  bounds: Self.bounds(initializer.audioprocessingbounds),
                  frequencyStart: initializer.audioprocessingfrequencystart,
                  frequencyEnd: initializer.audioprocessingfrequencyend)
    }

    init?(_ element: WEParticleOperator) {
        self.init(mode: element.audioprocessingmode, exponent: element.audioprocessingexponent,
                  bounds: Self.bounds(element.audioprocessingbounds),
                  frequencyStart: element.audioprocessingfrequencystart, frequencyEnd: element.audioprocessingfrequencyend)
    }
}
