import simd

/// Compiles an `operator` json element into its record (`ParticleOperator`), with WE's defaults:
/// each one's filler function in `wallpaper64.exe` is cited. Record layouts are documented on
/// `runOperator` in `ParticleProgram.h`.
enum ParticleOperatorBuilder {
    /// `modelIndex` is how many `collisionmodel` operators came before this one.
    static func make(_ element: WEParticleOperator, defaults d: ParticleDefaults, sceneSize: SIMD2<Float>,
                     path: String, modelIndex: Int = 0) -> ParticleOperator? {
        let flags = UInt32(truncatingIfNeeded: max(element.flags ?? 0, 0))
        func cp(_ value: Int?, _ fallback: Int = 0) -> UInt32 { UInt32(min(max(value ?? fallback, 0), 7)) }
        func f(_ value: Double?, _ fallback: Float) -> Float { value.map(Float.init) ?? fallback }
        func v(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> { ParticleDefaults.vector(value, fallback) }
        func v(_ value: String?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            value.map { let p = $0.parseVector3(); return SIMD3(Float(p.0), Float(p.1), Float(p.2)) } ?? fallback
        }
        let blend = ParticleBlend(inStart: element.blendinstart, inEnd: element.blendinend,
                                  outStart: element.blendoutstart, outEnd: element.blendoutend)
        switch element.name?.lowercased() {
        case "movement":
            // 0x1401bc9a0: gravity 0, drag 0, flags 0.
            return ParticleOperator(.movement, flags: flags, a: SIMD4(v(element.gravity, .zero), f(element.drag, 0)))
        case "angularmovement":
            // 0x1401bcc80: force 0, drag 0.
            return ParticleOperator(.angularMovement, a: SIMD4(v(element.force, .zero), f(element.drag, 0)), blend: blend)
        case "alphafade":
            // 0x1401bce50: fadeintime 0.5, fadeouttime 0.5 (fractions of the life).
            return ParticleOperator(.alphaFade, a: SIMD4(f(element.fadeintime, 0.5), f(element.fadeouttime, 0.5), 0, 0))
        case "sizechange", "alphachange":
            // 0x1401bcfe0: startvalue 1, endvalue 0, starttime 0, endtime 1.
            let values = SIMD4(ParticleDefaults.scalar(element.startvalue, 1), ParticleDefaults.scalar(element.endvalue, 0),
                               f(element.starttime, 0), f(element.endtime, 1))
            return ParticleOperator(element.name?.lowercased() == "sizechange" ? .sizeChange : .alphaChange, a: values)
        case "colorchange":
            // 0x1401bd2a0: startvalue "1 1 1", endvalue "0 0 0", starttime 0, endtime 1; no /255.
            return ParticleOperator(.colorChange, a: SIMD4(v(element.startvalue, SIMD3(1, 1, 1)), 0),
                                    b: SIMD4(v(element.endvalue, .zero), 0),
                                    c: SIMD4(f(element.starttime, 0), f(element.endtime, 1), 0, 0))
        case "oscillateposition":
            // 0x1401bd5d0: mask "1 1 0", frequency 1…5, scale 0…10 (2D) / 0.5, phase 0…2π.
            return ParticleOperator(.oscillatePosition, a: SIMD4(v(element.mask, SIMD3(1, 1, 0)), 0),
                                    b: oscillation(element, frequencyMax: 5),
                                    c: SIMD4(f(element.scalemin, 0), f(element.scalemax, d.pick(10, 0.5)), 0, 0), blend: blend)
        case "oscillatealpha":
            // 0x1401bd910: frequency 1…10, scale 0…1, phase 0…2π.
            return ParticleOperator(.oscillateAlpha, b: oscillation(element, frequencyMax: 10),
                                    c: SIMD4(f(element.scalemin, 0), f(element.scalemax, 1), 0, 0), blend: blend)
        case "oscillatesize":
            // 0x1401bdbf0: frequency 1…10, scale 0.8…1.2, phase 0…2π.
            return ParticleOperator(.oscillateSize, b: oscillation(element, frequencyMax: 10),
                                    c: SIMD4(f(element.scalemin, 0.8), f(element.scalemax, 1.2), 0, 0), blend: blend)
        case "controlpointattract":
            // 0x1401bdee0: scale 512 / 20, threshold 512 / 5, deletethreshold 15 / 0.5, flags 2. The
            // operator's `origin` (offset) isn't read by the VM (0x140241554).
            let attractFlags = element.flags.map { UInt32(truncatingIfNeeded: max($0, 0)) } ?? 2
            return ParticleOperator(.controlPointAttract, flags: attractFlags, controlPoints: cp(element.controlpoint),
                                    b: SIMD4(ParticleDefaults.scalar(element.scale, d.pick(512, 20)),
                                             f(element.threshold, d.pick(512, 5)), f(element.deletethreshold, d.pick(15, 0.5)), 0),
                                    blend: blend)
        case "maintaindistancetocontrolpoint":
            // 0x1401be2a0: distance 200 / 1, variablestrength 0.
            return ParticleOperator(.maintainDistanceToControlPoint, controlPoints: cp(element.controlpoint),
                                    a: SIMD4(f(element.distance, d.pick(200, 1)), f(element.variablestrength, 0), 0, 0),
                                    blend: blend)
        case "maintaindistancebetweencontrolpoints":
            // 0x1401be5d0: controlpointstart 0, controlpointend 1.
            return ParticleOperator(.maintainDistanceBetweenControlPoints,
                                    controlPoints: cp(element.controlpointstart) | cp(element.controlpointend, 1) << 8,
                                    blend: blend)
        case "reducemovementnearcontrolpoint":
            // 0x1401be810: distanceinner 100 / 0.5, distanceouter 350 / 1, reductioninner 100,
            // reductionouter 0.
            return ParticleOperator(.reduceMovementNearControlPoint, controlPoints: cp(element.controlpoint),
                                    a: SIMD4(f(element.distanceinner, d.pick(100, 0.5)), f(element.distanceouter, d.pick(350, 1)),
                                             f(element.reductioninner, 100), f(element.reductionouter, 0)),
                                    blend: blend)
        case "turbulence":
            // 0x1401beb80: timescale 20 / 1, mask "1 1 0" / "1 1 1", scale 0.01 / 0.5, speed
            // 500…1000 / 1…5, phase 0…0.
            var op = ParticleOperator(.turbulence, a: SIMD4(v(element.mask, d.pick(SIMD3(1, 1, 0), SIMD3(1, 1, 1))), 0),
                                      b: SIMD4(ParticleDefaults.scalar(element.scale, d.pick(0.01, 0.5)),
                                               f(element.speedmin, d.pick(500, 1)), f(element.speedmax, d.pick(1000, 5)),
                                               f(element.timescale, d.pick(20, 1))),
                                      c: SIMD4(f(element.phasemin, 0), f(element.phasemax, 0), 0, 0), blend: blend)
            op.audio = ParticleAudioResponse(element)
            return op
        case "vortex":
            // 0x1401bef00: axis "0 0 1", distanceinner 500 / 1, distanceouter 650 / 2, speedinner
            // 2500 / 1, speedouter 0.
            var op = ParticleOperator(.vortex, flags: flags, controlPoints: cp(element.controlpoint),
                                      a: SIMD4(v(element.offset, .zero), 0), b: SIMD4(v(element.axis, SIMD3(0, 0, 1)), 0),
                                      c: SIMD4(f(element.distanceinner, d.pick(500, 1)), f(element.distanceouter, d.pick(650, 2)),
                                               f(element.speedinner, d.pick(2500, 1)), f(element.speedouter, 0)))
            op.audio = ParticleAudioResponse(element)
            return op
        case "vortex_v2":
            // 0x1401bf2d0: as `vortex`, centerforce 1, ringradius 300 / 1, ringwidth 50 / 0.2,
            // ringpulldistance 50 / 0.25, ringpullforce 10 / 0.05.
            var op = ParticleOperator(.vortexV2, flags: flags, controlPoints: cp(element.controlpoint),
                                      a: SIMD4(v(element.axis, SIMD3(0, 0, 1)), 0),
                                      b: SIMD4(f(element.distanceinner, d.pick(500, 1)), f(element.distanceouter, d.pick(650, 2)),
                                               f(element.speedinner, d.pick(2500, 1)), f(element.speedouter, 0)),
                                      c: SIMD4(f(element.centerforce, 1), f(element.ringradius, d.pick(300, 1)),
                                               f(element.ringwidth, d.pick(50, 0.2)), f(element.ringpulldistance, d.pick(50, 0.25))),
                                      d: SIMD4(f(element.ringpullforce, d.pick(10, 0.05)), 0, 0, 0), blend: blend)
            op.audio = ParticleAudioResponse(element)
            return op
        case "boids":
            // 0x1401bf700: separationthreshold 20 / 0.02, neighborthreshold 50 / 0.2, maxspeed
            // 500 / 1, factors 15 / 1 / 2, flags 1.
            let boidFlags = element.flags.map { UInt32(truncatingIfNeeded: max($0, 0)) } ?? 1
            return ParticleOperator(.boids, flags: boidFlags,
                                    a: SIMD4(f(element.separationthreshold, d.pick(20, 0.02)),
                                             f(element.neighborthreshold, d.pick(50, 0.2)), f(element.maxspeed, d.pick(500, 1)), 0),
                                    b: SIMD4(f(element.separationfactor, 15), f(element.alignmentfactor, 1),
                                             f(element.cohesionfactor, 2), 0))
        case "capvelocity":
            // 0x1401bfab0: maxspeed 100 / 1.
            return ParticleOperator(.capVelocity, a: SIMD4(f(element.maxspeed, d.pick(100, 1)), 0, 0, 0), blend: blend)
        case "remapvalue":
            // 0x1401bfbb0: multiply, lifetimefraction → size.
            guard var op = remap(element, defaultInput: "lifetimefraction", path: path) else { return nil }
            op.record.blend = blend?.window ?? ParticleProgramOp.noBlend
            return op
        case "inheritvaluefromevent":
            // 0x1401c0700: setcoloropacity.
            let input = element.input?.isEmpty == false ? element.input! : "setcoloropacity"
            guard let verbs = ParticleInheritance(input: input) else {
                OWELog.error(.scene, "Particle system \(path): inheritvaluefromevent has an unknown input \(input); ignored")
                return nil
            }
            return ParticleOperator(.inheritValueFromEvent, flags: verbs.rawValue, blend: blend)
        case "collisionplane", "collisionsphere", "collisionquad", "collisionbounds", "collisionmodel":
            // `collisionmodel` collides with the capsules of the object the system's `dependencies`
            // link to it (`SceneMetalParticleSystem.collisionModels`).
            guard let collision = ParticleCollision(element, sceneSize: sceneSize, defaults: d,
                                                    modelIndex: modelIndex) else { return nil }
            var op = ParticleOperator(.collision)
            op.collision = collision
            return op
        case "collisionbox":
            // Its VM entry does nothing (0x140240279).
            return nil
        default:
            OWELog.error(.scene, "Particle system \(path): unknown operator \(element.name ?? "(none)"); ignored")
            return nil
        }
    }

    /// Frequency, phase: `frequencymin` 1…`frequencymax`, `phasemin` 0…`phasemax` 2π.
    private static func oscillation(_ element: WEParticleOperator, frequencyMax: Float) -> SIMD4<Float> {
        SIMD4(Float(element.frequencymin ?? 1), Float(element.frequencymax ?? Double(frequencyMax)),
              Float(element.phasemin ?? 0), Float(element.phasemax ?? 2 * Double.pi))
    }

    /// `remapvalue`'s record (`remap` in `ParticleProgram.h`).
    static func remap(_ element: WEParticleOperator, defaultInput: String, path: String) -> ParticleOperator? {
        guard let code = ParticleRemapBuilder.code(operation: element.operation, input: element.input, defaultInput: defaultInput,
                                                   output: element.output, inputComponent: element.inputcomponent,
                                                   outputComponent: element.outputcomponent,
                                                   transform: element.transformfunction, octaves: element.transformoctaves,
                                                   path: path) else { return nil }
        var op = ParticleOperator(.remapValue, flags: UInt32(truncatingIfNeeded: max(element.flags ?? 0, 0)),
                                  controlPoints: ParticleRemapBuilder.controlPoints(element.inputcontrolpoint0, element.outputcontrolpoint0,
                                                                                    element.inputcontrolpoint1, element.outputcontrolpoint1),
                                  a: SIMD4(ParticleDefaults.vector(element.inputrangemin, .zero), 0),
                                  b: SIMD4(ParticleDefaults.vector(element.inputrangemax, SIMD3(repeating: 1)), 0),
                                  c: SIMD4(ParticleDefaults.vector(element.outputrangemin, .zero), 0),
                                  d: SIMD4(ParticleDefaults.vector(element.outputrangemax, SIMD3(repeating: 1)), 0),
                                  e: SIMD4(Float(element.transforminputscale ?? 2), 0, 0, 1))
        op.record.header.w = code
        return op
    }
}

/// The enums of `remapvalue` and `remapinitialvalue` (`ParticleProgramEncoding.RemapCode`).
enum ParticleRemapBuilder {
    static func code(operation: String?, input: String?, defaultInput: String, output: String?, inputComponent: String?,
                     outputComponent: String?, transform: String?, octaves: Int?, path: String) -> UInt32? {
        func index(_ value: String?, in names: [String], fallback: String, what: String) -> UInt32? {
            let name = (value?.isEmpty == false ? value! : fallback).lowercased()
            guard let found = names.firstIndex(of: name) else {
                OWELog.error(.scene, "Particle system \(path): remap \(what) \(name) is unknown; the remap is ignored")
                return nil
            }
            return UInt32(found)
        }
        guard let operation = index(operation, in: ParticleProgramEncoding.remapOperations, fallback: "multiply", what: "operation"),
              let input = index(input, in: ParticleProgramEncoding.remapValues, fallback: defaultInput, what: "input"),
              let output = index(output, in: ParticleProgramEncoding.remapValues, fallback: "size", what: "output"),
              let inputComponent = index(inputComponent, in: ParticleProgramEncoding.remapComponents, fallback: "all", what: "component"),
              let outputComponent = index(outputComponent, in: ParticleProgramEncoding.remapComponents, fallback: "all", what: "component"),
              let transform = index(transform, in: ParticleProgramEncoding.remapTransforms, fallback: "none", what: "transform")
        else { return nil }
        return ParticleProgramEncoding.RemapCode.pack(operation: operation, input: input, output: output,
                                                 inputComponent: inputComponent, outputComponent: outputComponent,
                                                 transform: transform, octaves: UInt32(min(max(octaves ?? 3, 1), 15)))
    }

    /// Input and output control points 0 and 1 (defaults 0, 0, 1, 1), a byte each.
    static func controlPoints(_ input0: Int?, _ output0: Int?, _ input1: Int?, _ output1: Int?) -> UInt32 {
        func clamped(_ value: Int?, _ fallback: Int) -> UInt32 { UInt32(min(max(value ?? fallback, 0), 7)) }
        return clamped(input0, 0) | clamped(output0, 0) << 8 | clamped(input1, 1) << 16 | clamped(output1, 1) << 24
    }
}
