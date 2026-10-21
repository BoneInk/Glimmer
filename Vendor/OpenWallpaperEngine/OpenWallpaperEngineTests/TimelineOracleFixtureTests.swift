import XCTest
@testable import OpenWallpaperEngine

/// The committed oracle `Tests/Fixtures/Timeline/cases.json`, from `Scripts/timeline-reference.py
/// fixture`: representative library timelines (every mode in the library, wraploop, relative,
/// linked children, default and custom handles) and synthetic edge cases (mirror, step, disabled
/// handles, dropped keyframes, events, negative rates, relative's tokenizer), each through the
/// standard runs (1/60, 1/144, 1/30 and jittered deltas, and play/pause/stop/setFrame/rate).
/// Runs everywhere, CI included. The file's texture cases are `TextureClockOracleTests`.
final class TimelineOracleFixtureTests: XCTestCase {
    private static let fixture = Fixtures.url("Timeline/cases.json")

    func testTimelinesMatchTheReferenceModel() throws {
        let root = try TimelineOracle.load(Self.fixture)
        let tolerance = try TimelineOracle.float(XCTUnwrap(root[oracle: "tolerance"]))
        let cases = try XCTUnwrap(root[oracle: "timelines"]?.oracleArray)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        var covered = Set<String>()
        for entry in cases {
            let id = entry[oracle: "id"]?.oracleString ?? "?"
            (entry[oracle: "covers"]?.oracleArray ?? []).compactMap(\.oracleString).forEach { covered.insert($0) }
            let members = try Self.members(entry[oracle: "timelines"])
            for run in try TimelineOracle.runs(entry[oracle: "runs"]) {
                do {
                    if let mismatch = try TimelineOracle.check(run, members: members, tolerance: tolerance) {
                        XCTFail("\(id): \(mismatch)")
                    }
                } catch {
                    XCTFail("\(id): \(error)")
                }
            }
        }
        for feature in ["loop", "single", "mirror", "wraploop", "relative", "linked-children", "step",
                        "default-handles", "custom-handles", "disabled-handles", "events", "negative-rate"] {
            XCTAssertTrue(covered.contains(feature), "no fixture case covers \(feature)")
        }
    }

    static func members(_ json: SceneJSON?) throws -> [TimelineOracle.Member] {
        try (json?.oracleArray ?? []).map { member in
            TimelineOracle.Member(key: try XCTUnwrap(member[oracle: "key"]?.oracleString),
                                  value: member[oracle: "value"],
                                  components: try TimelineOracle.int(XCTUnwrap(member[oracle: "components"])),
                                  animation: try XCTUnwrap(member[oracle: "animation"]))
        }
    }
}
