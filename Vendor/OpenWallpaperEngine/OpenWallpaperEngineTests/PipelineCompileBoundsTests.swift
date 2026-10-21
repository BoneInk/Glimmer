import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Roadmap item 20: bounded pipeline compiles, an evicting pipeline cache, retries of transient
/// Metal failures and toolchain versions in the variant cache key.
final class PipelineCompileBoundsTests: XCTestCase {
    func testWorkQueueNeverExceedsItsLimit() {
        let queue = BoundedWorkQueue(label: "test.bounded", qos: .userInitiated, limit: 3)
        let lock = NSLock()
        var running = 0, peak = 0, finished = 0
        let done = expectation(description: "all ran")
        done.expectedFulfillmentCount = 40
        for _ in 0..<40 {
            queue.async {
                lock.withLock { running += 1; peak = max(peak, running) }
                Thread.sleep(forTimeInterval: 0.005)
                lock.withLock { running -= 1; finished += 1 }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(finished, 40)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "work runs concurrently up to the limit")
    }

    func testPerformanceCoreCountIsPositive() {
        XCTAssertGreaterThan(BoundedWorkQueue.performanceCoreCount, 0)
        XCTAssertLessThanOrEqual(BoundedWorkQueue.performanceCoreCount, ProcessInfo.processInfo.activeProcessorCount)
    }

    func testLRUCacheEvictsLeastRecentlyUsed() {
        var cache = LRUCache<Int>(capacity: 3)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "c")
        XCTAssertEqual(cache.value(forKey: "a"), 1) // a is now the most recent
        let evicted = cache.insert(4, forKey: "d")
        XCTAssertEqual(evicted, ["b"])
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.contains("b"))
        XCTAssertTrue(cache.contains("a") && cache.contains("c") && cache.contains("d"))
        cache.keep { $0 != "c" }
        XCTAssertEqual(cache.count, 2)
    }

    func testLRUCacheEvictsInBatchesAndKeepsTheNewEntry() {
        var cache = LRUCache<Int>(capacity: 16)
        for index in 0..<16 { cache.insert(index, forKey: "\(index)") }
        let evicted = cache.insert(16, forKey: "16")
        XCTAssertEqual(Set(evicted), ["0", "1"]) // an eighth of the capacity, oldest first
        XCTAssertTrue(cache.contains("16"))
        XCTAssertLessThanOrEqual(cache.count, 16)
    }

    func testRetryRetriesTransientFailuresWithBackoff() throws {
        var calls = 0
        var waits: [TimeInterval] = []
        let transient = NSError(domain: MTLLibraryErrorDomain, code: Int(MTLLibraryError.internal.rawValue))
        let value = try PipelineCompileRetry.run(sleep: { waits.append($0) }) { () throws -> Int in
            calls += 1
            if calls < 3 { throw transient }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(waits, [0.05, 0.1])
    }

    func testRetryFailsAtOnceOnAShaderError() {
        var calls = 0
        let compileError = NSError(domain: MTLLibraryErrorDomain, code: Int(MTLLibraryError.compileFailure.rawValue))
        XCTAssertThrowsError(try PipelineCompileRetry.run(sleep: { _ in XCTFail("no wait") }) { () throws -> Int in
            calls += 1
            throw compileError
        })
        XCTAssertEqual(calls, 1)
    }

    func testRetryGivesUpAfterItsAttempts() {
        var calls = 0
        let transient = NSError(domain: MTLLibraryErrorDomain, code: Int(MTLLibraryError.internal.rawValue))
        XCTAssertThrowsError(try PipelineCompileRetry.run(sleep: { _ in }) { () throws -> Int in
            calls += 1
            throw transient
        })
        XCTAssertEqual(calls, PipelineCompileRetry.attempts)
    }

    func testVariantCacheKeyIncludesToolchainVersions() {
        let translator = ShaderVariantTranslator(compiler: ShaderCompilerFactory.makeDefault(stateDirectory: nil),
                                                 cacheDirectory: nil, failureDirectory: nil)
        let fingerprint = translator.toolchainFingerprint
        XCTAssertTrue(fingerprint.contains("glslang "), fingerprint)
        XCTAssertTrue(fingerprint.contains("spirv-cross "), fingerprint)
        XCTAssertTrue(fingerprint.hasSuffix("|metal \(ShaderToolchainVersions.osBuild)"), fingerprint)
        XCTAssertNotEqual(ShaderToolchainVersions.osBuild, "unknown")

        // A new OS build (Metal compiler) or library version changes the key and the generation.
        let source = ShaderSource(stage: .vertex, path: "v", text: "void main() {}", combos: [], uniforms: [])
        let compiler = InProcessShaderCompiler.fingerprint
        let current = ShaderToolchainVersions.fingerprint(compiler: compiler, osBuild: "25A1")
        let newOS = ShaderToolchainVersions.fingerprint(compiler: compiler, osBuild: "25B2")
        let newLibraries = ShaderToolchainVersions.fingerprint(compiler: compiler + "-next", osBuild: "25A1")
        let keys = [current, newOS, newLibraries].map {
            ShaderVariantTranslator.cacheKey(vertex: source, fragment: source, combos: [:], toolchain: $0)
        }
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertNotEqual(ShaderVariantTranslator.generation(toolchain: current),
                          ShaderVariantTranslator.generation(toolchain: newOS))
        // The update check predicts the same generation the translator uses.
        XCTAssertEqual(ShaderCacheKey.current.variantGeneration, ShaderVariantTranslator.generation(toolchain: fingerprint))
    }
}

final class PriorityGateTests: XCTestCase {
    func testWaitersGoInPriorityOrder() {
        let gate = PriorityGate()
        gate.enter(priority: 0)
        let lock = NSLock()
        var order: [Int] = []
        let done = expectation(description: "all")
        done.expectedFulfillmentCount = 3
        for priority in [9, 25, 17] {
            Thread.detachNewThread {
                gate.enter(priority: priority)
                lock.withLock { order.append(priority) }
                gate.leave()
                done.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        gate.leave()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order, [25, 17, 9])
    }
}
