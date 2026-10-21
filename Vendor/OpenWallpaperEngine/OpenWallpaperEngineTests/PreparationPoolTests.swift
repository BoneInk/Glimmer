import XCTest
@testable import OpenWallpaperEngine

final class PreparationPoolTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var order: [Int] = []
        var bytes = 0
        var peakBytes = 0
        var running = 0
        var peakRunning = 0
        func begin(_ id: Int, _ size: Int) {
            lock.lock(); order.append(id); bytes += size; running += 1
            peakBytes = max(peakBytes, bytes); peakRunning = max(peakRunning, running); lock.unlock()
        }
        func end(_ size: Int) { lock.lock(); bytes -= size; running -= 1; lock.unlock() }
    }

    private func waitIdle(_ pool: PreparationPool) {
        let idle = expectation(description: "idle")
        pool.whenIdle { idle.fulfill() }
        wait(for: [idle], timeout: 10)
    }

    func testJobsNeverExceedTheMemoryBudget() {
        let pool = PreparationPool(maxWorkers: 8, memoryBudget: 100)
        let recorder = Recorder()
        for id in 0..<20 {
            let size: Int = 30 + (id % 3) * 10
            pool.submit(priority: .currentWallpaper, estimatedBytes: size) { _ in
                recorder.begin(id, size)
                Thread.sleep(forTimeInterval: 0.01)
                recorder.end(size)
            }
        }
        waitIdle(pool)
        let peak: Int = recorder.peakBytes
        let count: Int = recorder.order.count
        XCTAssertLessThanOrEqual(peak, 100)
        XCTAssertEqual(count, 20)
    }

    func testOversizedJobRunsAlone() {
        let pool = PreparationPool(maxWorkers: 8, memoryBudget: 100)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        pool.submit(priority: .settingWallpaper, estimatedBytes: 10) { _ in gate.wait() }
        pool.submit(priority: .settingWallpaper, estimatedBytes: 500) { _ in
            recorder.begin(1, 500); Thread.sleep(forTimeInterval: 0.05); recorder.end(500)
        }
        pool.submit(priority: .settingWallpaper, estimatedBytes: 10) { _ in
            recorder.begin(2, 10); recorder.end(10)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let startedEarly: Int = recorder.order.count
        XCTAssertEqual(startedEarly, 0, "the oversized job waits for the running one and holds back the rest")
        gate.signal()
        waitIdle(pool)
        let peakRunning: Int = recorder.peakRunning
        let order: [Int] = recorder.order
        XCTAssertEqual(peakRunning, 1)
        XCTAssertEqual(order, [1, 2])
    }

    func testPriorityOrder() {
        let pool = PreparationPool(maxWorkers: 1, memoryBudget: 1000)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        pool.submit(priority: .settingWallpaper) { _ in gate.wait() }
        let submissions: [(Int, PreparationPool.Priority)] = [(1, .library), (2, .currentWallpaper),
                                                               (3, .settingWallpaper), (4, .library),
                                                               (5, .currentWallpaper), (6, .settingWallpaper)]
        for (id, priority) in submissions {
            pool.submit(priority: priority) { _ in recorder.begin(id, 0); recorder.end(0) }
        }
        gate.signal()
        waitIdle(pool)
        let order: [Int] = recorder.order
        XCTAssertEqual(order, [3, 6, 2, 5, 1, 4])
    }

    func testCancelledJobNeverRuns() {
        let pool = PreparationPool(maxWorkers: 1, memoryBudget: 1000)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "onCancel")
        pool.submit(priority: .settingWallpaper) { _ in gate.wait() }
        let job = pool.submit(priority: .library, onCancel: { cancelled.fulfill() }) { _ in recorder.begin(1, 0) }
        pool.submit(priority: .library) { _ in recorder.begin(2, 0); recorder.end(0) }
        job.cancel()
        gate.signal()
        wait(for: [cancelled], timeout: 5)
        waitIdle(pool)
        let order: [Int] = recorder.order
        XCTAssertEqual(order, [2])
    }

    func testRunningJobSeesCancellation() async {
        let pool = PreparationPool(maxWorkers: 2, memoryBudget: 1000)
        let task = Task {
            try await pool.run(priority: .currentWallpaper) { job -> Bool in
                for _ in 0..<500 where !job.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                return job.isCancelled
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let sawCancel: Bool = (try? await task.value) ?? true
        XCTAssertTrue(sawCancel)
    }

    func testLibraryJobsWaitForTheGateAndTheirWorkerLimit() {
        let pool = PreparationPool(maxWorkers: 8, libraryWorkers: 2, memoryBudget: 1000)
        let recorder = Recorder()
        final class Flag: @unchecked Sendable { var open = false }
        let flag = Flag()
        pool.setLibraryGate { flag.open }
        for id in 0..<6 {
            pool.submit(priority: .library) { _ in
                recorder.begin(id, 0); Thread.sleep(forTimeInterval: 0.02); recorder.end(0)
            }
        }
        let current = expectation(description: "current runs while library waits")
        pool.submit(priority: .currentWallpaper) { _ in current.fulfill() }
        wait(for: [current], timeout: 5)
        let beforeGate: Int = recorder.order.count
        XCTAssertEqual(beforeGate, 0)
        flag.open = true
        pool.reevaluate()
        waitIdle(pool)
        let peakRunning: Int = recorder.peakRunning
        let count: Int = recorder.order.count
        XCTAssertLessThanOrEqual(peakRunning, 2)
        XCTAssertEqual(count, 6)
    }
}

final class PowerPolicyTests: XCTestCase {
    func testLibraryPreparationRules() {
        let ac = PowerPolicy(PowerState(onBattery: false, batteryLevel: 0.2))
        XCTAssertTrue(ac.allowsLibraryPreparation)
        let busy = PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.9, userIdleSeconds: 10))
        XCTAssertFalse(busy.allowsLibraryPreparation)
        let idleHigh = PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.6, userIdleSeconds: 130))
        XCTAssertTrue(idleHigh.allowsLibraryPreparation)
        let idleLow = PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.5, userIdleSeconds: 130))
        XCTAssertFalse(idleLow.allowsLibraryPreparation)
        let hot = PowerPolicy(PowerState(thermal: .critical))
        XCTAssertFalse(hot.allowsLibraryPreparation)
    }

    func testEfficiencyStepsAndRateCap() {
        let nominal = PowerPolicy(PowerState())
        let nominalStop: Int = nominal.effectiveStop(4)
        XCTAssertEqual(nominalStop, 4)
        XCTAssertNil(nominal.frameRateCap)
        let lowPower = PowerPolicy(PowerState(lowPowerMode: true))
        let lowPowerStop: Int = lowPower.effectiveStop(3)
        XCTAssertEqual(lowPowerStop, 4)
        let serious = PowerPolicy(PowerState(lowPowerMode: true, thermal: .serious))
        let seriousStop: Int = serious.effectiveStop(3)
        XCTAssertEqual(seriousStop, 4)
        let critical = PowerPolicy(PowerState(thermal: .critical))
        let criticalStop: Int = critical.effectiveStop(4)
        XCTAssertEqual(criticalStop, 5)
        XCTAssertEqual(critical.frameRateCap, 30)
    }

    func testLiveStateReads() {
        let state: PowerState = PowerPolicyMonitor.readState()
        XCTAssertGreaterThanOrEqual(state.userIdleSeconds, 0)
    }
}
