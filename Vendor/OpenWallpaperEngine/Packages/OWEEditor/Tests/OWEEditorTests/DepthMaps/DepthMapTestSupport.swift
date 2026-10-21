import CoreGraphics
import Foundation
import XCTest
@testable import OWEEditor

/// Pictures and a fake model for the depth map tests: no Core ML, no network.
enum DepthMapTestSupport {
    /// An opaque grey picture whose pixel `(x, y)` (from the top-left) is `value(x, y)` (0…1).
    static func image(width: Int, height: Int, _ value: (Int, Int) -> Double) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level = UInt8((min(max(value(x, y), 0), 1) * 255).rounded())
                let offset = (y * width + x) * 4
                bytes[offset] = level
                bytes[offset + 1] = level
                bytes[offset + 2] = level
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A left-black, right-white picture: one sharp vertical edge in the middle.
    static func edge(width: Int = 256, height: Int = 64) -> CGImage {
        image(width: width, height: height) { x, _ in x < width / 2 ? 0 : 1 }
    }

    static func model(version: String = "fake-1") -> DepthMapPluginLayout.ActiveModel {
        DepthMapPluginLayout.ActiveModel(version: version, url: URL(fileURLWithPath: "/nonexistent/fake.mlmodelc"))
    }
}

/// A model that answers with `depth(width, height)` at its own low resolution, counts its runs
/// and can be held mid-run.
final class FakeDepthEstimator: DepthEstimating, @unchecked Sendable {
    let outputIsInverseDepth = true
    let width: Int
    let height: Int
    let depth: (Int, Int) -> Float
    private let lock = NSLock()
    private var _runs = 0
    /// Set before a run to hold it until signalled.
    var gate: DispatchSemaphore?
    var onEstimate: (() -> Void)?

    var runs: Int { lock.withLock { _runs } }

    init(width: Int = 16, height: Int = 4, depth: @escaping (Int, Int) -> Float) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    func estimate(_ image: CGImage) throws -> DepthMapBuffer {
        lock.withLock { _runs += 1 }
        onEstimate?()
        gate?.wait()
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { values[y * width + x] = depth(x, y) } }
        return DepthMapBuffer(width: width, height: height, values: values)
    }
}

/// Loads `FakeDepthEstimator`s and keeps a weak reference to the last, to see it released.
final class FakeModelLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private weak var _last: FakeDepthEstimator?
    private let make: () -> FakeDepthEstimator

    init(make: @escaping () -> FakeDepthEstimator = { FakeDepthEstimator { x, _ in x < 8 ? 10 : 50 } }) {
        self.make = make
    }

    var loads: Int { lock.withLock { _loads } }
    var last: FakeDepthEstimator? { lock.withLock { _last } }

    func load(_ url: URL) throws -> DepthEstimating {
        let estimator = make()
        lock.withLock {
            _loads += 1
            _last = estimator
        }
        return estimator
    }
}

/// A clock the test moves: actions run when `advance` passes their deadline.
@MainActor
final class ManualIdleScheduler: DepthMapIdleScheduler {
    final class Pending: DepthMapIdleTimer {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private(set) var pending: [Pending] = []
    private(set) var scheduledDelays: [TimeInterval] = []

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DepthMapIdleTimer {
        scheduledDelays.append(seconds)
        let timer = Pending(deadline: now + seconds, action: action)
        pending.append(timer)
        return timer
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = pending.filter { !$0.isCancelled && $0.deadline <= now }
        pending.removeAll { $0.isCancelled || $0.deadline <= now }
        for timer in due { timer.action() }
    }
}
