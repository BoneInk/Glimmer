import Foundation
import simd

/// A bone's physics constraint, read from its `MDLS` properties JSON as WE's loader reads it
/// (0x140265c30, called per bone at 0x1402625a9; docs/models-plan.md §2.14). The keys are the
/// compiled ones `resourcecompiler64.exe` writes (0x1400b0270): the Puppet Warp editor's bone
/// constraints (`se` spring, `re` rigid, `rs`/`ts` stiffness, `rf`/`tf` friction, `ri`/`ti`
/// inertia, `ge`/`gd`/`m` gravity, `la`/`lamin`/`lamax` angle limits, `lt`/`ltmax` torque
/// limit, `tm` maximum distance, `rax`… axes), with the editor's tip size and forward angle
/// turned into the tip position `tp`. The IK keys set their flags only.
struct MDLBonePhysics: Equatable {
    /// The flags word WE keeps at bone+0x68.
    struct Flags: OptionSet, Hashable {
        let rawValue: UInt32
        /// `se`: spring physics.
        static let spring = Flags(rawValue: 0x1)
        /// `re`: rigid physics (wins over `se`).
        static let rigid = Flags(rawValue: 0x2)
        /// `ge`: gravity.
        static let gravity = Flags(rawValue: 0x4)
        /// `la`: limit the angles to `minAngles`…`maxAngles`.
        static let limitAngles = Flags(rawValue: 0x8)
        /// `lt`: limit the angular velocity to `maxTorque` degrees about each axis.
        static let limitTorque = Flags(rawValue: 0x10)
        /// `ikg`: Puppet Warp's "Use orientation controller" (the solver reads the controller
        /// link whenever the compiler wrote one, not this flag).
        static let ikGravityController = Flags(rawValue: 0x20)
        /// `ikr`: "Rotate when overstretched" (`ScenePuppetIK`).
        static let ikEndRotation = Flags(rawValue: 0x40)
        static let ikStretch = Flags(rawValue: 0x80)
        /// `ikfe`: a free endpoint, which keeps its parent's orientation.
        static let ikFreeEndpoint = Flags(rawValue: 0x100)
        /// `r`: the rotation is simulated.
        static let rotation = Flags(rawValue: 0x1000)
        /// `t`: the translation is simulated.
        static let translation = Flags(rawValue: 0x2000)
        static let ik = Flags(rawValue: 0x4000)
        static let ikConstrained = Flags(rawValue: 0x8000)
        /// `rax`/`ray`/`raz` false: that Euler angle stays 0.
        static let lockRotationX = Flags(rawValue: 0x10_0000)
        static let lockRotationY = Flags(rawValue: 0x20_0000)
        static let lockRotationZ = Flags(rawValue: 0x40_0000)
        /// `tax`/`tay`/`taz` false: no offset along the bone's axis.
        static let lockTranslationX = Flags(rawValue: 0x80_0000)
        static let lockTranslationY = Flags(rawValue: 0x100_0000)
        static let lockTranslationZ = Flags(rawValue: 0x200_0000)
    }

    var flags: Flags = []
    /// `rs`, degrees a second per radian of angle.
    var rotationStiffness: Float = 0
    /// `ts`.
    var translationStiffness: Float = 0
    /// `rf`, a second⁻¹.
    var rotationFriction: Float = 0
    /// `tf` (as authored on a physics bone; an IK bone keeps `(tf / 100)²` in 0…1).
    var translationFriction: Float = 0
    /// `1 − ri / 100`: how much of the tip's lag becomes angular velocity.
    var rotationInertia: Float = 1
    /// `1 − ti / 100`.
    var translationInertia: Float = 1
    /// `gd`, in the world.
    var gravityDirection: SIMD3<Float> = .zero
    /// `m`: the tip's mass (the gravity's strength).
    var mass: Float = 1000
    /// `tp`: the tip's position in the bone's space.
    var tip: SIMD3<Float> = .zero
    /// `|tp| / 100` [?: nothing in the simulation reads it].
    var tipScale: Float = 1
    /// `tm`: the largest offset, times the object's mean scale; 0 is no limit.
    var maxDistance: Float = 0
    /// `lamin`, `lamax`: Euler angles in radians.
    var minAngles: SIMD3<Float> = .zero
    var maxAngles: SIMD3<Float> = .zero
    /// `ltmax`, degrees.
    var maxTorque: Float = 0
    /// `ikd` (+0x5c, at least 1): the limb depth, which the compiler turns into the IK sets.
    var ikDepth = 2
    /// `ikrd` (+0x60, at least 1): "Full rotation distance", how far past its reach the target
    /// is when `ikr` has turned the effector all the way to it.
    var ikRotationDistance: Float = 50
    /// `ikrminl`, `ikrmaxl` (+0x64, +0x68, radians): an `ikce` chain bone's turn from its parent.
    var ikMinimumAngle: Float = 0
    var ikMaximumAngle: Float = 0

    /// Simulated: rotation or translation, with spring or rigid physics (the loader's test at
    /// 0x140265f0d; the update's is `flags & (r | t)`, 0x14020136e, and neither spring nor rigid
    /// changes nothing there).
    var isSimulated: Bool {
        !flags.isDisjoint(with: [.rotation, .translation]) && !flags.isDisjoint(with: [.spring, .rigid])
    }

    /// The bone's properties; nil when they aren't a JSON object or set no flag (WE clears the
    /// flags of a bone that is neither simulated, IK nor IK-constrained, 0x140266559).
    init?(properties: String) {
        guard !properties.isEmpty, let data = properties.data(using: .utf8) else { return nil }
        let json: SceneJSON
        do {
            json = try JSONDecoder().decode(SceneJSON.self, from: data)
        } catch {
            OWELog.error(.scene, "A bone's properties aren't JSON: \(error)")
            return nil
        }
        guard case .object(let keys) = json else { return nil }
        self.init(keys: keys)
        if flags.isEmpty { return nil }
    }

    private init(keys: [String: SceneJSON]) {
        // rapidjson's `GetBool` only for a bool, `GetFloat` only for a number, the vectors only
        // for a string; anything else keeps the bone's default (0x14026b860).
        func bool(_ key: String) -> Bool? { if case .bool(let b)? = keys[key] { return b } else { return nil } }
        func number(_ key: String) -> Float? { if case .number(let n)? = keys[key] { return Float(n) } else { return nil } }
        func vector(_ key: String) -> SIMD3<Float>? { if case .string(let s)? = keys[key] { return Self.vector(s) } else { return nil } }
        func set(_ flag: Flags, _ key: String) { if bool(key) == true { flags.insert(flag) } }

        set(.ik, "ik")
        set(.ikConstrained, "ikce")
        set(.rotation, "r")
        set(.translation, "t")
        set(.spring, "se")
        set(.rigid, "re")
        let simulated = isSimulated
        guard simulated || flags.contains(.ik) else {
            if flags.contains(.ikConstrained) {
                // 0x140266475: an IK-constrained bone's angle limits.
                if let value = number("ikrminl") { ikMinimumAngle = value }
                if let value = number("ikrmaxl") { ikMaximumAngle = value }
            } else {
                flags = []
            }
            return
        }
        set(.gravity, "ge")
        if let value = vector("gd") { gravityDirection = value }
        if let value = number("m") { mass = value }
        if let value = number("tf") { translationFriction = value }
        guard simulated else {
            // The IK path keeps the friction as (tf / 100)², clamped to 0…1 (0x140266195).
            translationFriction = min(max((translationFriction / 100) * (translationFriction / 100), 0), 1)
            // 0x1402661cf…: `ikd` (an integer), `ikg`, `ikr`, `ikrd`, `ikse`, `ikfe`.
            if let value = number("ikd") { ikDepth = max(Int(value), 1) }
            for (flag, key) in [(Flags.ikGravityController, "ikg"), (.ikEndRotation, "ikr")] { set(flag, key) }
            if let value = number("ikrd") { ikRotationDistance = value > 1 ? value : 1 }
            for (flag, key) in [(Flags.ikStretch, "ikse"), (.ikFreeEndpoint, "ikfe")] { set(flag, key) }
            return
        }
        if let value = number("rs") { rotationStiffness = value }
        if let value = number("ts") { translationStiffness = value }
        if let value = number("rf") { rotationFriction = value }
        if let value = number("ri") { rotationInertia = 1 - value / 100 }
        if let value = number("ti") { translationInertia = 1 - value / 100 }
        if let value = vector("tp") {
            tip = value
            tipScale = simd_length(value) / 100
        }
        if let value = number("tm") { maxDistance = value }
        set(.limitAngles, "la")
        if let value = vector("lamin") { minAngles = value }
        if let value = vector("lamax") { maxAngles = value }
        set(.limitTorque, "lt")
        if let value = number("ltmax") { maxTorque = value }
        // The axes count only when all three are bools; a false one locks its axis (0x140266e31).
        if let x = bool("rax"), let y = bool("ray"), let z = bool("raz") {
            if !x { flags.insert(.lockRotationX) }
            if !y { flags.insert(.lockRotationY) }
            if !z { flags.insert(.lockRotationZ) }
        }
        if let x = bool("tax"), let y = bool("tay"), let z = bool("taz") {
            if !x { flags.insert(.lockTranslationX) }
            if !y { flags.insert(.lockTranslationY) }
            if !z { flags.insert(.lockTranslationZ) }
        }
    }

    /// WE's "x y z" reader (0x140266058…): `atof` at the start, then at each run of spaces;
    /// missing numbers stay 0.
    static func vector(_ text: String) -> SIMD3<Float> {
        let bytes = Array(text.utf8)
        var result = SIMD3<Float>.zero
        var position = 0
        for component in 0..<3 {
            if component > 0 {
                while position < bytes.count, bytes[position] != 0x20 { position += 1 }
                guard position < bytes.count else { break }
                while position < bytes.count, bytes[position] == 0x20 { position += 1 }
            }
            let rest = String(decoding: bytes[position...], as: UTF8.self)
            result[component] = Float(rest.withCString { atof($0) })
            if position >= bytes.count { break }
        }
        return result
    }
}
