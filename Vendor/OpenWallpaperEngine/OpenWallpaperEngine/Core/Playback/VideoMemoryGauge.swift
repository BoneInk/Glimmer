import Foundation

/// Advanced › "Pause when VRAM is exhausted": decides from cheap samples whether video memory has
/// run out, as WE pauses the wallpaper then instead of stuttering or crashing.
///
/// Exhausted when the GPU's allocations reach its working-set budget (`currentAllocatedSize`
/// against `recommendedMaxWorkingSetSize`), a command buffer failed for lack of memory, or (on
/// unified memory, where video memory is system memory) the system reports critical memory
/// pressure. It clears once allocations fall below `resumeFraction` of the budget and the pressure
/// is no longer critical, and never sooner than `minimumHold` after it began, so it can't flap.
struct VideoMemoryGauge: Equatable {
    /// Allocations at or above this share of the budget exhaust it.
    static let exhaustFraction = 1.0
    /// Allocations must fall below this share of the budget to clear it.
    static let resumeFraction = 0.85
    /// The shortest time a state is held before it may change back.
    static let minimumHold: TimeInterval = 5

    /// One reading of the device and the system.
    struct Sample: Equatable {
        var allocated: UInt64
        var budget: UInt64
        /// The system's memory pressure is critical (counted only with unified memory).
        var criticalPressure = false
        /// A command buffer failed for lack of memory since the last sample.
        var outOfMemoryError = false
    }

    private(set) var exhausted = false
    /// When `exhausted` last changed.
    private(set) var changedAt: TimeInterval = -.infinity

    /// Folds in `sample` taken at `now`; true when `exhausted` changed.
    @discardableResult
    mutating func update(_ sample: Sample, now: TimeInterval) -> Bool {
        let held = now - changedAt >= Self.minimumHold
        let usage = sample.budget > 0 ? Double(sample.allocated) / Double(sample.budget) : 0
        let next: Bool
        if exhausted {
            next = !(usage < Self.resumeFraction && !sample.criticalPressure && !sample.outOfMemoryError)
        } else {
            next = usage >= Self.exhaustFraction || sample.criticalPressure || sample.outOfMemoryError
        }
        guard next != exhausted, held else { return false }
        exhausted = next
        changedAt = now
        return true
    }

    /// The user resumed by hand: clear, and hold that for `minimumHold`.
    @discardableResult
    mutating func userResumed(now: TimeInterval) -> Bool {
        guard exhausted else { return false }
        exhausted = false
        changedAt = now
        return true
    }

    /// Why `sample` exhausts the budget, for the log.
    static func reason(_ sample: Sample) -> String {
        if sample.outOfMemoryError { return "a command buffer ran out of memory" }
        if sample.criticalPressure { return "system memory pressure is critical" }
        let mb = { (bytes: UInt64) in bytes / 1_048_576 }
        return "\(mb(sample.allocated)) MB allocated of a \(mb(sample.budget)) MB budget"
    }
}
