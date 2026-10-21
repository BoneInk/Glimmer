import XCTest
@testable import OpenWallpaperEngine

/// The texture cases of `Tests/Fixtures/Timeline/cases.json` (`Scripts/timeline-reference.py
/// fixture`): WE's sprite-frame walk (docs/timeline-plan.md §2.7) on library frame times (one with
/// a 0 s frame) and synthetic ones (frames shorter than a tick, several 0 s frames), at 1/60 and
/// 1/144 s ticks and under rate changes (2, 0, −1, 0.3). Runs everywhere, CI included.
final class TextureClockOracleTests: XCTestCase {
    private static let fixture = Fixtures.url("Timeline/cases.json")

    /// The walk under the engine frame time × a script's rate, as the override of
    /// `ITextureAnimation` advances it (the shared clock is the same walk at rate 1).
    func testTextureClocksMatchTheReferenceModel() throws {
        let root = try TimelineOracle.load(Self.fixture)
        let cases = try XCTUnwrap(root[oracle: "textures"]?.oracleArray)
        XCTAssertTrue(cases.contains { $0[oracle: "frameTimes"]?.oracleArray?.contains { $0.oracleNumber == 0 } == true },
                      "no texture case has a 0 s frame")
        for entry in cases {
            let id = entry[oracle: "id"]?.oracleString ?? "?"
            let frameTimes = try (entry[oracle: "frameTimes"]?.oracleArray ?? []).map(TimelineOracle.float)
            for run in entry[oracle: "runs"]?.oracleArray ?? [] {
                let name = run[oracle: "name"]?.oracleString ?? "?"
                if let mismatch = try Self.checkTexture(run, frameTimes: frameTimes) {
                    XCTFail("\(id), run \(name): \(mismatch)")
                }
            }
        }
    }

    private static func checkTexture(_ run: SceneJSON, frameTimes: [Float]) throws -> String? {
        var expected: [String: (frame: Int32, time: Float)] = [:]
        let records = run[oracle: "records"]?.oracleArray ?? []
        for record in records {
            let fields = record.oracleArray ?? []
            guard fields.count == 4 else { throw TimelineOracle.OracleError.malformed("\(record)") }
            expected["\(try TimelineOracle.int(fields[0])):\(try TimelineOracle.int(fields[1]))"] =
                (Int32(try TimelineOracle.int(fields[2])), try TimelineOracle.float(fields[3]))
        }
        var frame: Int32 = 0, time: Float = 0, rate: Float = 1, checked = 0
        func compare(_ op: Int, _ tick: Int) -> String? {
            guard let wanted = expected["\(op):\(tick)"] else { return nil }
            checked += 1
            // Exact: the walk only adds, subtracts and compares float32 frame times.
            if frame != wanted.frame || time != wanted.time {
                return "op \(op) tick \(tick): frame \(frame) time \(time), expected frame \(wanted.frame) time \(wanted.time)"
            }
            return nil
        }
        if let mismatch = compare(-1, 0) { return mismatch }
        for (index, op) in (run[oracle: "ops"]?.oracleArray ?? []).enumerated() {
            let fields = op.oracleArray ?? []
            switch fields.first?.oracleString {
            case "advance":
                let delta = try TimelineOracle.float(fields[1])
                for tick in 0..<(try TimelineOracle.int(fields[2])) {
                    SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: delta * rate, frameTimes: frameTimes)
                    if let mismatch = compare(index, tick) { return mismatch }
                }
            case "rate":
                rate = try TimelineOracle.float(fields[1])
                if let mismatch = compare(index, 0) { return mismatch }
            default:
                throw TimelineOracle.OracleError.malformed("texture op \(op)")
            }
        }
        return checked == records.count ? nil : "checked \(checked) of \(records.count) records"
    }
}
