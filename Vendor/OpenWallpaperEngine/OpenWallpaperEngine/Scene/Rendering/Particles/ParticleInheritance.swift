import simd

/// What a child particle takes from the parent particle of its instance's event:
/// `inheritinitialvaluefromevent` once when it spawns, `inheritvaluefromevent` every step.
/// Each case is one of WE's `input` verbs; `ParticleSimulation.metal` applies the same bits in the
/// same order.
struct ParticleInheritance: OptionSet, Hashable {
    let rawValue: UInt32

    static let setColor = ParticleInheritance(rawValue: 1 << 0)
    static let multiplyColor = ParticleInheritance(rawValue: 1 << 1)
    static let setOpacity = ParticleInheritance(rawValue: 1 << 2)
    static let multiplyOpacity = ParticleInheritance(rawValue: 1 << 3)
    static let setVelocity = ParticleInheritance(rawValue: 1 << 4)
    static let addVelocity = ParticleInheritance(rawValue: 1 << 5)
    static let setSize = ParticleInheritance(rawValue: 1 << 6)
    static let multiplySize = ParticleInheritance(rawValue: 1 << 7)
    static let setRotation = ParticleInheritance(rawValue: 1 << 8)
    static let addRotation = ParticleInheritance(rawValue: 1 << 9)
    static let setAngularVelocity = ParticleInheritance(rawValue: 1 << 10)
    static let addAngularVelocity = ParticleInheritance(rawValue: 1 << 11)

    /// An `input` verb; nil for one WE doesn't have.
    init?(input: String) {
        switch input.lowercased() {
        case "setcolor": self = .setColor
        case "multiplycolor": self = .multiplyColor
        case "setopacity": self = .setOpacity
        case "multiplyopacity": self = .multiplyOpacity
        case "setcoloropacity": self = [.setColor, .setOpacity]
        case "multiplycoloropacity": self = [.multiplyColor, .multiplyOpacity]
        case "setvelocity": self = .setVelocity
        case "addvelocity": self = .addVelocity
        case "setsize": self = .setSize
        case "multiplysize": self = .multiplySize
        case "setrotation": self = .setRotation
        case "addrotation": self = .addRotation
        case "setangularvelocity": self = .setAngularVelocity
        case "addangularvelocity": self = .addAngularVelocity
        default: return nil
        }
    }

    init(rawValue: UInt32) { self.rawValue = rawValue }
}
