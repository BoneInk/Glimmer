import Foundation

/// Executes the production accumulator directly, without Steam/auth/core dependencies.
@main enum WorkshopDownloadMetricsTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            checks += 1
            print("PASS \(description)")
        }
        let invalid: [(String, Double)] = [
            ("NaN", .nan), ("positive infinity", .infinity),
            ("negative infinity", -.infinity), ("negative", -0.1), ("greater than one", 1.1)
        ]
        for (name, value) in invalid {
            var metrics = WorkshopDownloadMetrics()
            metrics.start(now: 0)
            metrics.consume(fraction: value, bytes: .init(received: 25, total: 100), now: 1)
            check(metrics.fraction == 0.25, "\(name) with valid bytes uses measured byte fraction")
            check(metrics.presentation(now: 1, force: true)?.0 == 0.25,
                  "\(name) cannot escape through published presentation")
            metrics.consume(fraction: value, bytes: nil, now: 2)
            check(metrics.fraction == 0.25, "\(name) without bytes preserves last valid fraction")
        }
        var metrics = WorkshopDownloadMetrics()
        metrics.start(now: 0)
        metrics.consume(fraction: 0.6, bytes: .init(received: 25, total: 100), now: 1)
        check(metrics.fraction == 0.6, "valid explicit percentage retains precedence over byte ratio")
        metrics.consume(fraction: nil, bytes: .init(received: 50, total: 100), now: 2)
        check(metrics.fraction == 0.5 && metrics.bytesPerSecond == 25,
              "nil percentage retains counter fraction and measured rate")
        print("RESULT \(checks) production metrics robustness checks passed; no account/process/network")
    }
}
