import Foundation
import simd

/// `remapvalue` (operator, `wallpaper64.exe` 0x140244874) and `remapinitialvalue` (initializer,
/// 0x14023ce53): reads an input, maps it from the input range through a transform to the output
/// range, and sets, multiplies, adds to or subtracts from an output.
///
/// Record: `header.y` flags (1 clamps the normalised input, 2 the output), `header.z` control
/// points (input 0, output 0, input 1, output 1, a byte each), `header.w` the enums (`Code`);
/// `a`/`b` the input range, `c`/`d` the output range, `e.x` `transforminputscale`.
extension ParticleProgramEncoding {
    /// The packed enums of a remap record.
    enum RemapCode {
        static func pack(operation: UInt32, input: UInt32, output: UInt32, inputComponent: UInt32,
                         outputComponent: UInt32, transform: UInt32, octaves: UInt32) -> UInt32 {
            operation | input << 4 | output << 9 | inputComponent << 14 | outputComponent << 18 | transform << 22
                | min(octaves, 15) << 26
        }

        static func operation(_ code: UInt32) -> UInt32 { code & 0xF }
        static func input(_ code: UInt32) -> UInt32 { (code >> 4) & 0x1F }
        static func output(_ code: UInt32) -> UInt32 { (code >> 9) & 0x1F }
        static func inputComponent(_ code: UInt32) -> UInt32 { (code >> 14) & 0xF }
        static func outputComponent(_ code: UInt32) -> UInt32 { (code >> 18) & 0xF }
        static func transform(_ code: UInt32) -> UInt32 { (code >> 22) & 0xF }
        static func octaves(_ code: UInt32) -> UInt32 { (code >> 26) & 0xF }
    }

    /// WE's names, in its enum order (the string tables at 0x140484dc0…0x140484f38).
    static let remapOperations = ["remap", "multiply", "add", "subtract"]
    static let remapValues = ["lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
                              "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday",
                              "particlesystemtime", "layertime", "color", "position", "velocity", "controlpoint",
                              "deltatocontrolpoint", "directiontocontrolpoint", "layerorigin"]
    static let remapComponents = ["all", "x", "y", "z", "sum", "average", "max", "min"]
    static let remapTransforms = ["none", "sine", "square", "saw", "triangle", "simplexnoise", "fbmnoise"]

    /// The fraction of the day that has passed, for the `timeofday` input.
    static func fractionOfDay(_ date: Date = Date()) -> Float {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return Float(date.timeIntervalSince(start) / 86_400)
    }
}
