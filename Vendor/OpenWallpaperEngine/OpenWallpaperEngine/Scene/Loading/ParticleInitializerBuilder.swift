import Foundation
import simd

/// Compiles an `initializer` json element into its record (`ParticleInitializer`), with WE's
/// defaults: each one's filler function in `wallpaper64.exe` is cited. Record layouts are
/// documented on `runInitializers` in `ParticleProgram.h`.
enum ParticleInitializerBuilder {
    static func make(_ element: WEParticleInitializer, defaults d: ParticleDefaults, path: String) -> ParticleInitializer? {
        let flags = UInt32(truncatingIfNeeded: max(element.flags ?? 0, 0))
        func f(_ value: Double?, _ fallback: Float) -> Float { value.map(Float.init) ?? fallback }
        func v(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> { ParticleDefaults.vector(value, fallback) }
        func v(_ value: String?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            value.map { let p = $0.parseVector3(); return SIMD3(Float(p.0), Float(p.1), Float(p.2)) } ?? fallback
        }
        /// min, max, exponent of a scalar random.
        func scalar(_ kind: ParticleInitializerKind, _ low: Float, _ high: Float) -> ParticleInitializer {
            ParticleInitializer(kind, a: SIMD4(ParticleDefaults.scalar(element.min, low), ParticleDefaults.scalar(element.max, high),
                                               f(element.exponent, 1), 0))
        }
        /// min, max of a vector random with the exponent in `a.w`; a bare number is (0, 0, n)
        /// for the rotations (0x1401c8d67).
        func vector(_ kind: ParticleInitializerKind, _ low: SIMD3<Float>, _ high: SIMD3<Float>,
                    numberIsZ: Bool) -> ParticleInitializer {
            func value(_ field: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                if numberIsZ, case .number(let n)? = field { return SIMD3(0, 0, Float(n)) }
                return v(field, fallback)
            }
            return ParticleInitializer(kind, a: SIMD4(value(element.min, low), f(element.exponent, 1)),
                                       b: SIMD4(value(element.max, high), 0))
        }
        switch element.name?.lowercased() {
        case "lifetimerandom":
            // 0x1401b9c40: 0…1.
            return scalar(.lifetimeRandom, 0, 1)
        case "sizerandom":
            // 0x1401b9e70: 5…50 (2D) / 0.001…1.
            return scalar(.sizeRandom, d.pick(5, 0.001), d.pick(50, 1))
        case "alpharandom":
            // 0x1401baa10: 0.05…1.
            return scalar(.alphaRandom, 0.05, 1)
        case "colorrandom":
            // 0x1401ba110: "0 0 0"…"255 255 255", divided by 255 when parsed (0x1401c7601).
            return ParticleInitializer(.colorRandom, a: SIMD4(v(element.min, .zero) / 255, f(element.exponent, 1)),
                                       b: SIMD4(v(element.max, SIMD3(repeating: 255)) / 255, 0))
        case "hsvcolorrandom":
            // 0x1401ba3e0: hue 0…1 in 6 steps, saturation 0.5…1, value 0.5…1.
            let hueMin = f(element.huemin, 0), hueMax = f(element.huemax, 1)
            let steps = Float(max(element.huesteps ?? 6, 0))
            var step: Float = 0
            if steps > 1 {
                // 0x1401c79de: a full circle doesn't repeat its first hue at the end.
                var range = hueMax - hueMin
                if range == 0 { range = 1 }
                var divisions = steps - 1
                if abs(fmod(range, 1)) < 1.0 / 360 { divisions += 1 }
                step = range / divisions
            }
            return ParticleInitializer(.hsvColorRandom, a: SIMD4(hueMin, step, steps, 0),
                                       b: SIMD4(f(element.saturationmin, 0.5), f(element.saturationmax, 1),
                                                f(element.valuemin, 0.5), f(element.valuemax, 1)))
        case "colorlist":
            // 0x1401ba740: colours ["1 1 1"] (0…1), no noise; an empty list is red. WE keeps the whole
            // list (a vector the pick at 0x14023b86b indexes); its editor offers 1…10 colours.
            let colors = (element.colors ?? ["1 1 1"]).map { string -> SIMD4<Float> in
                let rgb = string.parseVector3()
                return SIMD4(hsv(SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))), 0)
            }
            let list = colors.isEmpty ? [SIMD4<Float>(0, 1, 1, 0)] : colors
            let padded = list + Array(repeating: list[0], count: max(4 - list.count, 0))
            var initializer = ParticleInitializer(.colorList, a: SIMD4(Float(list.count), f(element.huenoise, 0),
                                                                       f(element.saturationnoise, 0), f(element.valuenoise, 0)),
                                                  b: padded[0], c: padded[1], d: padded[2], e: padded[3])
            initializer.moreColors = Array(list.dropFirst(4))
            return initializer
        case "velocityrandom":
            // 0x1401bac50: "-32 -32 0"…"32 32 0" (2D) / "-1 -1 -1"…"1 1 1".
            return vector(.velocityRandom, d.pick(SIMD3(-32, -32, 0), SIMD3(-1, -1, -1)),
                          d.pick(SIMD3(32, 32, 0), SIMD3(1, 1, 1)), numberIsZ: false)
        case "inheritcontrolpointvelocity":
            // 0x1401bad80: 0.1…0.2.
            return ParticleInitializer(.inheritControlPointVelocity, controlPoints: UInt32(min(max(element.controlpoint ?? 0, 0), 7)),
                                       a: SIMD4(ParticleDefaults.scalar(element.min, 0.1), ParticleDefaults.scalar(element.max, 0.2), 0, 0))
        case "turbulentvelocityrandom":
            // 0x1401bb030: speed 100…250 (2D) / 0.5…1, phase 0…0.1, timescale 1, scale 1, offset 0,
            // forward "0 1 0", right "0 0 1".
            var initializer = ParticleInitializer(
                .turbulentVelocityRandom,
                a: SIMD4(ParticleDefaults.scalar(element.speedmin, d.pick(100, 0.5)),
                         ParticleDefaults.scalar(element.speedmax, d.pick(250, 1)), f(element.phasemin, 0), f(element.phasemax, 0.1)),
                b: SIMD4(f(element.timescale, 1), f(element.scale, 1), f(element.offset, 0), 0),
                c: SIMD4(v(element.forward, SIMD3(0, 1, 0)), 0), d: SIMD4(v(element.right, SIMD3(0, 0, 1)), 0))
            initializer.audio = ParticleAudioResponse(element)
            return initializer
        case "rotationrandom":
            // 0x1401bb390: "0 0 0"…"0 0 2π".
            return vector(.rotationRandom, .zero, SIMD3(0, 0, 6.28318530717), numberIsZ: true)
        case "angularvelocityrandom":
            // 0x1401bb9c0: "0 0 -5"…"0 0 5".
            return vector(.angularVelocityRandom, SIMD3(0, 0, -5), SIMD3(0, 0, 5), numberIsZ: true)
        case "positionoffsetrandom":
            // 0x1401bb660: directions "1 1 0" (2D) / "1 1 1", sign 0, scale 0.001 / 1, distance
            // 100 / 0.1, timescale 1, octaves 6 (1…8; 0 is the 2D flag, 0x1401c9382).
            let sign = v(element.sign, .zero)
            let octaves = element.octaves.map { $0 == 0 ? (d.pixelUnits ? 1 : 0) : $0 } ?? 6
            return ParticleInitializer(.positionOffsetRandom, flags: simd_length_squared(sign) > 1.19e-7 ? 1 : 0,
                                       a: SIMD4(v(element.directions, d.pick(SIMD3(1, 1, 0), SIMD3(1, 1, 1))), 0),
                                       b: SIMD4(sign, 0),
                                       c: SIMD4(f(element.scale, d.pick(0.001, 1)), f(element.distance, d.pick(100, 0.1)),
                                                f(element.timescale, 1), Float(min(max(octaves, 1), 8))))
        case "mapsequencearoundcontrolpoint":
            // 0x1401bbc90: count 32, bounds "0 1", speed "0 0 0"…"0 0 0", axis "0 0 1", repeat.
            let bounds = Self.bounds(element.bounds)
            var initializer = ParticleInitializer(
                .mapSequenceAroundControlPoint, flags: flags, controlPoints: UInt32(min(max(element.controlpoint ?? 0, 0), 7)),
                a: SIMD4(0, bounds.x, bounds.y, element.limitbehavior?.lowercased() == "mirror" ? 1 : 0),
                b: SIMD4(v(element.speedmin, .zero), 0), c: SIMD4(v(element.speedmax, .zero), 0),
                d: SIMD4(v(element.axis, SIMD3(0, 0, 1)), 0))
            initializer.sequenceCount = Float(element.count ?? 32)
            return initializer
        case "mapsequencebetweencontrolpoints":
            // 0x1401bc080: count 32, bounds "0 1", repeat, control points 0 and 1, arcamount 0.3,
            // arcdirection "0 1 0", sizereductionamount 0.9.
            let bounds = Self.bounds(element.bounds)
            let start = UInt32(min(max(element.controlpointstart ?? 0, 0), 7))
            let end = UInt32(min(max(element.controlpointend ?? 1, 0), 7))
            var initializer = ParticleInitializer(
                .mapSequenceBetweenControlPoints, flags: flags, controlPoints: start | end << 8,
                a: SIMD4(0, bounds.x, bounds.y, element.limitbehavior?.lowercased() == "mirror" ? 1 : 0),
                b: SIMD4(f(element.arcamount, 0.3), f(element.sizereductionamount, 0.9), 0, 0),
                c: SIMD4(v(element.arcdirection, SIMD3(0, 1, 0)), 0))
            initializer.sequenceCount = Float(element.count ?? 32)
            return initializer
        case "remapinitialvalue":
            // 0x1401bc4b0: multiply, maxlifetime → size.
            guard let code = ParticleRemapBuilder.code(operation: element.operation, input: element.input,
                                                       defaultInput: "maxlifetime", output: element.output,
                                                       inputComponent: element.inputcomponent,
                                                       outputComponent: element.outputcomponent,
                                                       transform: element.transformfunction,
                                                       octaves: element.transformoctaves, path: path) else { return nil }
            var initializer = ParticleInitializer(
                .remapInitialValue, flags: flags,
                controlPoints: ParticleRemapBuilder.controlPoints(element.inputcontrolpoint0, element.outputcontrolpoint0,
                                                                  element.inputcontrolpoint1, element.outputcontrolpoint1),
                a: SIMD4(v(element.inputrangemin, .zero), 0), b: SIMD4(v(element.inputrangemax, SIMD3(repeating: 1)), 0),
                c: SIMD4(v(element.outputrangemin, .zero), 0), d: SIMD4(v(element.outputrangemax, SIMD3(repeating: 1)), 0),
                e: SIMD4(f(element.transforminputscale, 2), 0, 0, 1))
            initializer.record.header.w = code
            return initializer
        case "inheritinitialvaluefromevent":
            // 0x1401bc980: setcolor.
            let input = element.input?.isEmpty == false ? element.input! : "setcolor"
            guard let verbs = ParticleInheritance(input: input) else {
                OWELog.error(.scene, "Particle system \(path): inheritinitialvaluefromevent has an unknown input \(input); ignored")
                return nil
            }
            return ParticleInitializer(.inheritInitialValueFromEvent, flags: verbs.rawValue)
        default:
            OWELog.error(.scene, "Particle system \(path): unknown initializer \(element.name ?? "(none)"); ignored")
            return nil
        }
    }

    /// `bounds` "min max" (default "0 1").
    private static func bounds(_ value: String?) -> SIMD2<Float> {
        guard let value else { return SIMD2(0, 1) }
        let parts = value.parseVector2()
        return SIMD2(Float(parts.0), Float(parts.1))
    }

    /// RGB to hue (turns), saturation and value (0x1401b8b90).
    static func hsv(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let high = max(rgb.x, rgb.y, rgb.z), low = min(rgb.x, rgb.y, rgb.z)
        let chroma = high - low
        var hue: Float = 0
        if chroma > 0 {
            if high == rgb.x { hue = fmod((rgb.y - rgb.z) / chroma, 6) }
            else if high == rgb.y { hue = (rgb.z - rgb.x) / chroma + 2 }
            else { hue = (rgb.x - rgb.y) / chroma + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return SIMD3(hue, high > 0 ? chroma / high : 0, high)
    }
}
