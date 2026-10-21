import Foundation

/// Integers from numbers scripts produced. Scripts hand NaN, ±Infinity and huge values to native
/// code without trying (`audio.average[64] * 10`, `1000 / (now - last)`, `1e39` after a Float32
/// write), and Swift's `Int(_:)` traps on every one of them. Every Float/Double → Int conversion
/// of a script-provided number in `Scene/Scripting` goes through here.
enum SceneScriptNumber {
    /// `value` truncated toward zero and clamped into `range`; nil for NaN. ±Infinity clamps to the
    /// range's ends, like any other out-of-range value.
    static func integer<Value: BinaryFloatingPoint>(_ value: Value, clampedTo range: ClosedRange<Int>) -> Int? {
        guard !value.isNaN else { return nil }
        if value <= Value(range.lowerBound) { return range.lowerBound }
        if value >= Value(range.upperBound) { return range.upperBound }
        return Int(value.rounded(.towardZero))
    }

    /// `value` truncated toward zero when it is finite and inside `range`; nil otherwise. For
    /// indices, where a clamped value would silently address the wrong object.
    static func index<Value: BinaryFloatingPoint>(_ value: Value, in range: ClosedRange<Int>) -> Int? {
        guard value.isFinite, value >= Value(range.lowerBound), value < Value(range.upperBound) + 1 else { return nil }
        let truncated = Int(value.rounded(.towardZero))
        return range.contains(truncated) ? truncated : nil
    }
}
