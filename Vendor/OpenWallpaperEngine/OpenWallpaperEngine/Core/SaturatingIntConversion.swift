/// Float-to-integer conversion for values read from wallpaper files. `Int(_:)` on a floating-point
/// value stops the process when the value is NaN, infinite or outside `Int`'s range; this never
/// does. It truncates toward zero like `Int(_:)`, so callers round first as before.
extension Int {
    /// `value` truncated toward zero and clamped to `range`: NaN becomes 0 (clamped to `range`),
    /// infinities and out-of-range values become the nearest bound.
    init<Source: BinaryFloatingPoint>(saturating value: Source, in range: ClosedRange<Int> = Int.min...Int.max) {
        guard !value.isNaN else {
            self = Swift.min(Swift.max(0, range.lowerBound), range.upperBound)
            return
        }
        // `Source(range.upperBound)` may round up to a power of two (2^63 for `Int.max`); every
        // value below it converts without leaving `Int`'s range.
        if value >= Source(range.upperBound) {
            self = range.upperBound
        } else if value <= Source(range.lowerBound) {
            self = range.lowerBound
        } else {
            self = Swift.min(Swift.max(Int(value), range.lowerBound), range.upperBound)
        }
    }
}
