import Foundation
import simd

/// A bone's physics constraint as WE's Puppet Warp editor offers it (`physicsconstraints` in its
/// `ui/dist/scripts/scripts.js`; docs/models-plan.md §2.14), written into the bone's `MDLS`
/// properties as the keys `resourcecompiler64.exe` compiles them to (`se`, `re`, `r`, `t`, `rs`,
/// `rf`, `ri`, `ts`, `tf`, `ti`, `m`, `ge`, `gd`, `la`, `lamin`, `lamax`, `lt`, `ltmax`, `tm`,
/// `tp`, the axes): the keys the player reads (`MDLBonePhysics`). Defaults are the editor's
/// (`makeDefaultPhysicsConstraintSettings`).
public struct PuppetBonePhysics: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// `se`: springs back to its rest pose.
        case spring
        /// `re`: no spring; only the lag, gravity and friction.
        case rigid
    }

    public var kind: Kind = .spring
    /// `r`: the rotation is simulated.
    public var rotation = true
    /// `t`: the translation is simulated.
    public var translation = false
    /// `rs`, `rf`, `ri`.
    public var rotationStiffness: Float = 200
    public var rotationFriction: Float = 20
    public var rotationInertia: Float = 30
    /// `ts`, `tf`, `ti`.
    public var translationStiffness: Float = 200
    public var translationFriction: Float = 20
    public var translationInertia: Float = 30
    /// `ge`, `gd` (in the world, y up), `m`.
    public var gravity = false
    public var gravityDirection = SIMD3<Float>(0, -1, 0)
    public var mass: Float = 20
    /// `la`, `lamin`, `lamax`: Euler angles in radians.
    public var limitAngles = false
    public var minAngles = SIMD3<Float>(0, 0, -.pi)
    public var maxAngles = SIMD3<Float>(0, 0, .pi)
    /// `lt`, `ltmax` (degrees).
    public var limitTorque = false
    public var maxTorque: Float = 100
    /// `tm`: the largest offset (times the object's mean scale); 0 is none.
    public var maxDistance: Float = 200
    /// The editor's tip size `s` (0: the distance to the child, else 100) and forward direction
    /// `a`, compiled into the tip position `tp`.
    public var tipSize: Float = 0
    public var forward = SIMD3<Float>(1, 0, 0)
    /// The tip a loaded rig was compiled with (`tp`), kept until the tip size or direction
    /// changes; nil compiles it from them.
    public var compiledTip: SIMD3<Float>?
    /// `rax`, `ray`, `raz`: which Euler angles move (2D: z only).
    public var rotationAxes = PuppetAxes(false, false, true)
    /// `tax`, `tay`, `taz`.
    public var translationAxes = PuppetAxes(true, true, true)

    public init() {}

    /// The editor's presets.
    public enum Preset: String, CaseIterable, Sendable {
        case springy, stiff, floppy, bouncyPosition
    }

    public init(preset: Preset) {
        self.init()
        switch preset {
        case .springy:
            break
        case .stiff:
            rotationStiffness = 600
            rotationFriction = 40
            rotationInertia = 60
        case .floppy:
            rotationStiffness = 40
            rotationFriction = 5
            rotationInertia = 10
            gravity = true
        case .bouncyPosition:
            rotation = false
            translation = true
            translationStiffness = 300
            translationFriction = 10
            translationInertia = 20
        }
    }

    /// The compiled tip: the forward direction times the tip size, the distance to the bone's
    /// first child when the size is 0, else 100.
    public func tip(childDistance: Float?) -> SIMD3<Float> {
        let length = simd_length(forward)
        let direction = length > 0 ? forward / length : SIMD3(1, 0, 0)
        let size = tipSize > 0 ? tipSize : (childDistance.flatMap { $0 > 0 ? $0 : nil } ?? 100)
        return direction * size
    }

    // MARK: Properties JSON

    /// A vector as WE's "x y z" strings: each number as the shortest text that reads back as the
    /// same float, so a loaded rig saves back exactly.
    static func vectorString(_ v: SIMD3<Float>) -> String {
        [v.x, v.y, v.z].map { ($0 + 0).description }.joined(separator: " ")
    }

    /// The tip as WE's compiler writes it (`"%.5f %.5f %.5f"`, 0x1400b0270).
    static func tipString(_ v: SIMD3<Float>) -> String {
        String(format: "%.5f %.5f %.5f", Double(v.x), Double(v.y), Double(v.z))
    }

    /// The keys WE's compiler writes for this constraint.
    public func properties(childDistance: Float?) -> [String: SceneJSONValue] {
        [
            "se": .bool(kind == .spring), "re": .bool(kind == .rigid), "r": .bool(rotation), "t": .bool(translation),
            "rs": .number(Double(rotationStiffness)), "rf": .number(Double(rotationFriction)), "ri": .number(Double(rotationInertia)),
            "ts": .number(Double(translationStiffness)), "tf": .number(Double(translationFriction)),
            "ti": .number(Double(translationInertia)),
            "ge": .bool(gravity), "gd": .string(Self.vectorString(gravityDirection)), "m": .number(Double(mass)),
            "la": .bool(limitAngles), "lamin": .string(Self.vectorString(minAngles)), "lamax": .string(Self.vectorString(maxAngles)),
            "lt": .bool(limitTorque), "ltmax": .number(Double(maxTorque)), "tm": .number(Double(maxDistance)),
            "s": .number(Double(tipSize)), "a": .string(Self.vectorString(forward)),
            "tp": .string(Self.tipString(compiledTip ?? tip(childDistance: childDistance))),
            "rax": .bool(rotationAxes.x), "ray": .bool(rotationAxes.y), "raz": .bool(rotationAxes.z),
            "tax": .bool(translationAxes.x), "tay": .bool(translationAxes.y), "taz": .bool(translationAxes.z),
        ]
    }

    /// Every key this type reads and writes; the rest of a bone's properties are kept apart.
    static let keys: Set<String> = ["se", "re", "r", "t", "rs", "rf", "ri", "ts", "tf", "ti", "ge", "gd", "m", "la", "lamin",
                                    "lamax", "lt", "ltmax", "tm", "s", "a", "tp", "rax", "ray", "raz", "tax", "tay", "taz"]

    /// The constraint of a bone's properties; nil when it isn't simulated (WE needs `r` or `t`
    /// with `se` or `re`). Values of the wrong type keep the defaults, as WE's reader does.
    public init?(properties: [String: SceneJSONValue]) {
        func bool(_ key: String) -> Bool? { if case .bool(let b)? = properties[key] { return b } else { return nil } }
        func number(_ key: String) -> Float? { if case .number(let n)? = properties[key] { return Float(n) } else { return nil } }
        func vector(_ key: String) -> SIMD3<Float>? {
            if case .string(let s)? = properties[key] { return PuppetPhysicsConstraint.vector(s) } else { return nil }
        }
        let spring = bool("se") == true, rigid = bool("re") == true
        let rotation = bool("r") == true, translation = bool("t") == true
        guard (spring || rigid), (rotation || translation) else { return nil }
        self.init()
        kind = rigid ? .rigid : .spring
        self.rotation = rotation
        self.translation = translation
        rotationStiffness = number("rs") ?? 0
        rotationFriction = number("rf") ?? 0
        rotationInertia = number("ri") ?? 0
        translationStiffness = number("ts") ?? 0
        translationFriction = number("tf") ?? 0
        translationInertia = number("ti") ?? 0
        gravity = bool("ge") == true
        gravityDirection = vector("gd") ?? .zero
        mass = number("m") ?? 1000
        limitAngles = bool("la") == true
        minAngles = vector("lamin") ?? .zero
        maxAngles = vector("lamax") ?? .zero
        limitTorque = bool("lt") == true
        maxTorque = number("ltmax") ?? 0
        maxDistance = number("tm") ?? 0
        tipSize = number("s") ?? 0
        if let a = vector("a") { forward = a }
        // A tip that isn't a number (WE writes NaN for a bone without a child) compiles anew.
        compiledTip = vector("tp").flatMap { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : nil }
        if let x = bool("rax"), let y = bool("ray"), let z = bool("raz") { rotationAxes = PuppetAxes(x, y, z) } else { rotationAxes = PuppetAxes(true, true, true) }
        if let x = bool("tax"), let y = bool("tay"), let z = bool("taz") { translationAxes = PuppetAxes(x, y, z) } else { translationAxes = PuppetAxes(true, true, true) }
    }
}

/// A simulated bone's constraint as the player's loader reads it from the properties
/// (`MDLBonePhysics`, 0x140265c30): flags and the values the step uses.
public struct PuppetPhysicsConstraint: Hashable, Sendable {
    public var spring: Bool
    public var rotation: Bool
    public var translation: Bool
    public var gravity: Bool
    public var limitAngles: Bool
    public var limitTorque: Bool
    public var lockRotation: PuppetAxes
    public var lockTranslation: PuppetAxes
    public var rotationStiffness: Float = 0
    public var translationStiffness: Float = 0
    public var rotationFriction: Float = 0
    public var translationFriction: Float = 0
    /// `1 − ri / 100`.
    public var rotationInertia: Float = 1
    /// `1 − ti / 100`.
    public var translationInertia: Float = 1
    public var gravityDirection: SIMD3<Float> = .zero
    public var mass: Float = 1000
    public var tip: SIMD3<Float> = .zero
    public var maxDistance: Float = 0
    public var minAngles: SIMD3<Float> = .zero
    public var maxAngles: SIMD3<Float> = .zero
    public var maxTorque: Float = 0

    /// From a bone's compiled properties, as the loader reads them; nil unless simulated.
    public init?(properties: [String: SceneJSONValue]) {
        func bool(_ key: String) -> Bool? { if case .bool(let b)? = properties[key] { return b } else { return nil } }
        func number(_ key: String) -> Float? { if case .number(let n)? = properties[key] { return Float(n) } else { return nil } }
        func vector(_ key: String) -> SIMD3<Float>? { if case .string(let s)? = properties[key] { return Self.vector(s) } else { return nil } }
        let spring = bool("se") == true, rigid = bool("re") == true
        rotation = bool("r") == true
        translation = bool("t") == true
        guard (spring || rigid), (rotation || translation) else { return nil }
        self.spring = !rigid
        gravity = bool("ge") == true
        if let value = vector("gd") { gravityDirection = value }
        if let value = number("m") { mass = value }
        if let value = number("tf") { translationFriction = value }
        if let value = number("rs") { rotationStiffness = value }
        if let value = number("ts") { translationStiffness = value }
        if let value = number("rf") { rotationFriction = value }
        if let value = number("ri") { rotationInertia = 1 - value / 100 }
        if let value = number("ti") { translationInertia = 1 - value / 100 }
        if let value = vector("tp") { tip = value }
        if let value = number("tm") { maxDistance = value }
        limitAngles = bool("la") == true
        if let value = vector("lamin") { minAngles = value }
        if let value = vector("lamax") { maxAngles = value }
        limitTorque = bool("lt") == true
        if let value = number("ltmax") { maxTorque = value }
        if let x = bool("rax"), let y = bool("ray"), let z = bool("raz") {
            lockRotation = PuppetAxes(!x, !y, !z)
        } else {
            lockRotation = PuppetAxes(false, false, false)
        }
        if let x = bool("tax"), let y = bool("tay"), let z = bool("taz") {
            lockTranslation = PuppetAxes(!x, !y, !z)
        } else {
            lockTranslation = PuppetAxes(false, false, false)
        }
    }

    /// WE's "x y z" reader: a number at the start and after each run of spaces, 0 where missing.
    static func vector(_ text: String) -> SIMD3<Float> {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        var result = SIMD3<Float>.zero
        for (index, part) in parts.prefix(3).enumerated() {
            result[index] = Float(String(part).withCString { atof($0) })
        }
        return result
    }
}

/// The physics bones in motion, the player's step (`SceneBonePhysics`, 0x14020136e…0x140203648)
/// for the editor's live preview: each frame the bones are posed parents first; a physics bone's
/// model matrix takes its simulated rotation and offset, `model · P`, before its children.
public struct PuppetPhysicsSimulation: Sendable {
    public struct State: Hashable, Sendable {
        public var angularVelocity = Q.identity
        public var angles = SIMD3<Float>.zero
        public var offset = SIMD3<Float>.zero
        public var velocity = SIMD3<Float>.zero

        public static func == (lhs: State, rhs: State) -> Bool {
            lhs.angularVelocity.vector == rhs.angularVelocity.vector && lhs.angles == rhs.angles && lhs.offset == rhs.offset
                && lhs.velocity == rhs.velocity
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(angles); hasher.combine(offset) }
    }

    typealias Q = PuppetPhysicsMath

    public let constraints: [PuppetPhysicsConstraint?]
    public private(set) var states: [State]
    private var transforms: [simd_float4x4?]
    /// Last frame's world matrices (the player's double buffer); nil before the first frame.
    private var previousWorlds: [simd_float4x4]?

    /// The document's simulated bones, read from the properties it writes; nil when none is.
    public init?(_ document: PuppetDocument) {
        let constraints = PuppetMDLWriter.boneProperties(document).map { properties -> PuppetPhysicsConstraint? in
            PuppetPhysicsConstraint(properties: properties)
        }
        guard constraints.contains(where: { $0 != nil }) else { return nil }
        self.constraints = constraints
        states = Array(repeating: State(), count: constraints.count)
        transforms = Array(repeating: nil, count: constraints.count)
    }

    public mutating func reset() {
        states = Array(repeating: State(), count: constraints.count)
        transforms = Array(repeating: nil, count: constraints.count)
        previousWorlds = nil
    }

    /// `applyBonePhysicsImpulse`: `linear` joins the velocity; the angular velocity turns by
    /// `angularDegrees`.
    public mutating func applyImpulse(bone: Int, linear: SIMD3<Float>, angularDegrees: SIMD3<Float>) {
        guard states.indices.contains(bone) else { return }
        states[bone].velocity += linear
        states[bone].angularVelocity = states[bone].angularVelocity * Q.quaternion(euler: angularDegrees * Q.degrees)
    }

    /// One frame: model-space matrices of `locals`, parents first, every physics bone stepped
    /// by `delta` with the object at `objectWorld`. Nothing moves on the first frame. `adjust`
    /// changes a bone's matrix before its step (the blend rules, `PuppetBlendMath.adjust`).
    public mutating func step(locals: [simd_float4x4], parents: [Int?], delta: Float, objectWorld: simd_float4x4,
                              adjust: ((Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4)? = nil,
                              ik: PuppetIKSolver? = nil) -> [simd_float4x4] {
        let scale = Self.meanScale(objectWorld)
        var models: [simd_float4x4] = []
        models.reserveCapacity(locals.count)
        var worlds: [simd_float4x4] = []
        for index in locals.indices {
            // A chain bone keeps what its solver wrote; a chain's root solves once stepped.
            if let held = ik?.heldModel(index) {
                models.append(held)
                worlds.append(objectWorld * held)
                continue
            }
            let parent = index < parents.count ? parents[index].flatMap { $0 < index ? $0 : nil } : nil
            var model = parent.map { models[$0] * locals[index] } ?? locals[index]
            if let adjust { model = adjust(index, model, models) }
            if index < constraints.count, let constraint = constraints[index] {
                if let previous = previousWorlds, index < previous.count, delta > 0 {
                    transforms[index] = Self.step(constraint, state: &states[index], world: objectWorld * model,
                                                  previous: previous[index], delta: delta, scale: scale)
                }
                if let transform = transforms[index] { model = model * transform }
            }
            models.append(model)
            worlds.append(objectWorld * model)
            if let ik {
                ik.posed(bone: index, worlds: &models)
                worlds = models.map { objectWorld * $0 }
            }
        }
        previousWorlds = worlds
        return models
    }

    static func meanScale(_ world: simd_float4x4) -> Float {
        let x = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
        let y = simd_length(SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z))
        let z = simd_length(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        return (y + x + z) / 3
    }

    static func step(_ constraint: PuppetPhysicsConstraint, state: inout State, world: simd_float4x4, previous: simd_float4x4,
                     delta: Float, scale: Float) -> simd_float4x4 {
        let basis = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                  SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                  SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        let origin = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let inverse = basis.inverse
        let previousTipWorld = previous * SIMD4(constraint.tip, 1)
        let previousTip = inverse * (SIMD3(previousTipWorld.x, previousTipWorld.y, previousTipWorld.z) - origin)
        let rotatedTip = Q.euler(state.angles) * constraint.tip
        var target = rotatedTip + inverse * state.offset
        var velocity = state.velocity
        if constraint.gravity {
            let gravity = inverse * constraint.gravityDirection * (constraint.mass * scale)
            let along = Q.unit(rotatedTip)
            target -= gravity - along * simd_dot(along, gravity)
            if constraint.translation { velocity += constraint.gravityDirection * (constraint.mass * delta * 1000) }
        }
        if constraint.rotation {
            let distance = min(simd_length(target - previousTip), delta * 900)
            let alignment = Q.alignment(from: Q.unit(target), to: Q.unit(previousTip))
            rotate(constraint, state: &state, distance: distance, alignment: alignment, delta: delta)
        }
        if constraint.translation {
            let previousOrigin = SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
            translate(constraint, state: &state, velocity: velocity, moved: origin - previousOrigin, world: world, delta: delta,
                      scale: scale)
        }
        let rotation = Q.euler(state.angles)
        return simd_float4x4(columns: (SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0),
                                       SIMD4(rotation.columns.2, 0), SIMD4(inverse * state.offset, 1)))
    }

    static func rotate(_ constraint: PuppetPhysicsConstraint, state: inout State, distance: Float, alignment: simd_quatf,
                       delta: Float) {
        var velocity = state.angularVelocity
        velocity = velocity * Q.slerp(Q.identity, alignment, min(distance * constraint.rotationInertia * Q.degrees, 1))
        if constraint.spring {
            let rest = Q.quaternion(euler: -state.angles)
            velocity = velocity * Q.slerp(Q.identity, rest, min(constraint.rotationStiffness * Q.degrees * delta, 1))
        }
        if constraint.limitTorque { velocity = Q.limitTorque(velocity, degrees: constraint.maxTorque) }
        let turn = Q.slerp(Q.identity, velocity, min(delta / 0.016666668, 1))
        var angles = Q.angles(simd_float3x3(turn) * Q.euler(state.angles))
        if constraint.spring {
            for axis in 0..<3 { angles[axis] = constraint.lockRotation[axis] ? 0 : Q.wrap(angles[axis]) }
        }
        if constraint.limitAngles {
            let unclamped = angles
            angles = simd_min(simd_max(angles, constraint.minAngles), constraint.maxAngles)
            velocity = Q.quaternion(euler: unclamped - angles).conjugate * velocity
        }
        if !constraint.spring {
            for axis in 0..<3 where constraint.lockRotation[axis] { angles[axis] = 0 }
        }
        state.angles = angles
        state.angularVelocity = Q.slerp(velocity, Q.identity, min(delta * constraint.rotationFriction, 1))
    }

    static func translate(_ constraint: PuppetPhysicsConstraint, state: inout State, velocity: SIMD3<Float>, moved: SIMD3<Float>,
                          world: simd_float4x4, delta: Float, scale: Float) {
        var velocity = velocity
        let kept = state.offset - (state.offset + moved) * constraint.translationInertia
        var offset: SIMD3<Float>
        if !constraint.spring {
            offset = kept + velocity * delta
        } else {
            velocity -= kept * (delta * constraint.translationStiffness)
            offset = kept + velocity * delta
        }
        for axis in 0..<3 where constraint.lockTranslation[axis] {
            let column = world[axis]
            let direction = SIMD3(column.x, column.y, column.z)
            offset -= direction * (simd_dot(offset, direction) / simd_dot(direction, direction))
        }
        let limit = scale * constraint.maxDistance
        if limit > 0, limit * limit < simd_length_squared(offset) { offset *= limit / simd_length(offset) }
        velocity -= velocity * min(delta * constraint.translationFriction, 1)
        state.offset = offset
        state.velocity = velocity
    }
}

/// The rotation helpers of the player's bone physics (`SceneBonePhysicsMath`), with WE's
/// thresholds.
enum PuppetPhysicsMath {
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    static let nearlyOne: Float = 0.99999988
    static let degrees: Float = 0.017453292
    static let radians: Float = 57.29578

    static func euler(_ angles: SIMD3<Float>) -> simd_float3x3 { PuppetMath.rotation(angles) }
    static func angles(_ m: simd_float3x3) -> SIMD3<Float> { PuppetMath.angles(m) }
    static func quaternion(euler angles: SIMD3<Float>) -> simd_quatf { PuppetMath.quaternion(euler: angles) }

    static func alignment(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let d = simd_dot(a, b)
        if d >= nearlyOne { return identity }
        if d < -nearlyOne {
            var axis = SIMD3<Float>(-a.y, a.x, 0)
            if simd_length_squared(axis) < 1.1920929e-7 { axis = SIMD3(0, -a.z, a.y) }
            return simd_quatf(real: cos(Float.pi / 2), imag: axis / simd_length(axis) * sin(Float.pi / 2))
        }
        let s = (2 * (1 + d)).squareRoot()
        return simd_quatf(real: s * 0.5, imag: simd_cross(a, b) / s)
    }

    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        var b = b.vector
        var d = simd_dot(a.vector, b)
        if d < 0 {
            b = -b
            d = -d
        }
        if d > nearlyOne { return simd_quatf(vector: a.vector * (1 - t) + b * t) }
        let angle = acos(d)
        return simd_quatf(vector: (a.vector * sin((1 - t) * angle) + b * sin(t * angle)) / sin(angle))
    }

    static func normalized(_ q: simd_quatf) -> simd_quatf {
        let length = simd_length(q.vector)
        return length > 0 ? simd_quatf(vector: q.vector / length) : identity
    }

    static func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { v * (1 / simd_length(v)) }

    static func limitTorque(_ q: simd_quatf, degrees limit: Float) -> simd_quatf {
        let tangents = q.imag / q.real
        var clamped = SIMD3<Float>.zero
        for axis in 0..<3 {
            var angle = min(atan(tangents[axis]) * radians * 2, limit)
            if -limit > angle { angle = -limit }
            clamped[axis] = tan(angle * degrees * 0.5)
        }
        return normalized(simd_quatf(real: 1, imag: clamped))
    }

    static func wrap(_ angle: Float) -> Float {
        angle < 0 ? fmodf(angle - .pi, 2 * .pi) + .pi : fmodf(angle + .pi, 2 * .pi) - .pi
    }
}

/// Three switches, one per axis.
public struct PuppetAxes: Codable, Hashable, Sendable {
    public var x: Bool
    public var y: Bool
    public var z: Bool

    public init(_ x: Bool, _ y: Bool, _ z: Bool) {
        self.x = x
        self.y = y
        self.z = z
    }

    public subscript(axis: Int) -> Bool {
        get { axis == 0 ? x : axis == 1 ? y : z }
        set {
            switch axis {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }
}
