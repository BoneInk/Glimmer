import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// Writes where each test spent its time: one JSON line per test with the `OWEPhaseTiming`
/// totals (scene load, shader translate, pipeline, texture, particles/models, render, GPU wait,
/// scripts, readback, compare), into `<OWE_TEST_PHASES>/phases-<pid>.jsonl`.
/// `Scripts/ci-test-durations.py` joins the lines with the result bundle's durations.
///
/// On only when `OWE_TEST_PHASES` names a folder (`TEST_RUNNER_OWE_TEST_PHASES` through
/// `xcodebuild`; `Scripts/ci-run-tests.sh` sets it). Off, the app's phase hooks read one Bool.
///
/// The test bundle's principal class (`NSPrincipalClass`), so XCTest creates it once when the
/// bundle loads, before any test runs.
@objc(OWETestPhaseTimer)
final class TestPhaseTimer: NSObject, XCTestObservation {
    private let output: FileHandle?
    private var started: UInt64 = 0

    override init() {
        output = Self.openOutput()
        super.init()
        ThreadGuardTestObserver.register()
        guard output != nil else { return }
        OWEPhaseTiming.setEnabled(true)
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    private static func openOutput() -> FileHandle? {
        guard let folder = ProcessInfo.processInfo.environment["OWE_TEST_PHASES"], !folder.isEmpty else { return nil }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
            .appending(path: "phases-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch {
            print("TestPhaseTimer: can't write \(url.path): \(error)")
            return nil
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        _ = OWEPhaseTiming.take()
        started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started) / 1e9
        let totals = OWEPhaseTiming.take()
        var phases: [String: [String: Double]] = [:]
        for (phase, total) in totals where total.calls > 0 {
            var entry = ["seconds": total.seconds, "calls": Double(total.calls)]
            if total.frames > 0 { entry["frames"] = Double(total.frames) }
            phases[phase.rawValue] = entry
        }
        let line: [String: Any] = ["test": Self.identifier(testCase.name), "seconds": seconds, "phases": phases]
        do {
            var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            data.append(0x0A)
            try output?.write(contentsOf: data)
        } catch {
            print("TestPhaseTimer: can't record \(testCase.name): \(error)")
        }
    }

    /// `-[Class testName]` → `Class/testName`, as the result bundle names it (without `()`).
    static func identifier(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : trimmed
    }
}
