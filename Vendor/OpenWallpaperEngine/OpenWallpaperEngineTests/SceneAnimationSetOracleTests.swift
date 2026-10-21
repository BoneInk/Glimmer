import XCTest
@testable import OpenWallpaperEngine

/// `SceneAnimationSet` driven like WE's frame loop over every case of the committed oracle
/// (`Tests/Fixtures/Timeline/cases.json`, from `Scripts/timeline-reference.py`): each case's
/// timelines become one owner's animated properties in a scene document (a material's constants for
/// the effect-constant cases, a layer's fields otherwise), the set links them, and the run's ops
/// become `advance(by:)` and `IAnimation` calls on the clock owner's site. After every recorded
/// tick the owner's state and every site's value must match the oracle, and the events fired must
/// be the oracle's, reported as the owner's.
final class SceneAnimationSetOracleTests: XCTestCase {
    func testTheSetMatchesTheReferenceModel() throws {
        let root = try JSONDecoder().decode(SceneJSON.self, from: Fixtures.data("Timeline/cases.json"))
        let tolerance = try Float(XCTUnwrap(root.member("tolerance")?.number))
        let cases = try XCTUnwrap(root.member("timelines")?.array)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        var runs = 0
        for entry in cases {
            let id = entry.member("id")?.string ?? "?"
            let covers = (entry.member("covers")?.array ?? []).compactMap(\.string)
            let members = try XCTUnwrap(entry.member("timelines")?.array)
            let owner: SceneAnimationOwner = covers.contains("effect-constant")
                ? .material(object: 3, effect: 0, pass: 0) : .object(3)
            for run in entry.member("runs")?.array ?? [] {
                runs += 1
                if let mismatch = try Self.check(run, members: members, owner: owner, tolerance: tolerance) {
                    XCTFail("\(id), run \(run.member("name")?.string ?? "?"): \(mismatch)")
                }
            }
        }
        XCTAssertGreaterThan(runs, 100)
    }

    // MARK: - Running a case

    private static func check(_ run: SceneJSON, members: [SceneJSON], owner: SceneAnimationOwner,
                              tolerance: Float) throws -> String? {
        let keys = members.compactMap { $0.member("key")?.string }
        let widths = members.compactMap { $0.member("components")?.number }.map(Int.init)
        let set = SceneAnimationSet(document: document(members, owner: owner), wallpaperID: "oracle")
        let sites = keys.map { SceneAnimationSite(owner: owner, key: $0) }
        guard set.sites.count == sites.count else { return "the set built \(set.sites.count) of \(sites.count) sites" }
        for site in sites.dropFirst() where set.clockOwner(of: site) != sites[0] {
            return "\(site) isn't linked to \(sites[0])"
        }

        var records: [String: SceneJSON] = [:]
        for record in run.member("records")?.array ?? [] {
            guard let fields = record.array, fields.count == 6,
                  let op = fields[0].number, let tick = fields[1].number else { continue }
            records["\(Int(op)):\(Int(tick))"] = record
        }
        var events: [String: [String]] = [:]
        for event in run.member("events")?.array ?? [] {
            guard let fields = event.array, fields.count == 3, let op = fields[0].number, let tick = fields[1].number else {
                continue
            }
            events["\(Int(op)):\(Int(tick))"] = (fields[2].array ?? []).compactMap(\.string)
        }
        var checked = 0

        func compare(_ op: Int, _ tick: Int, fired: [SceneAnimationEvent]) -> String? {
            let key = "\(op):\(tick)"
            if fired.map(\.name) != events[key] ?? [] {
                return "op \(op) tick \(tick): events \(fired.map(\.name)), expected \(events[key] ?? [])"
            }
            if let stray = fired.first(where: { $0.site != sites[0] }) {
                return "op \(op) tick \(tick): event \(stray.name) reported for \(stray.site)"
            }
            guard let fields = records[key]?.array else { return nil }
            checked += 1
            guard let state = set.state(of: sites[0]) else { return "no state" }
            let time = Float(fields[2].number ?? .nan), frame = Float(fields[4].number ?? .nan)
            let flags = Int(fields[3].number ?? -1)
            let got = (state.flags.contains(.paused) ? 1 : 0) | (state.flags.contains(.finished) ? 2 : 0)
                | (state.flags.contains(.reversed) ? 4 : 0)
            if !close(state.time, time, tolerance) { return "op \(op) tick \(tick): time \(state.time), expected \(time)" }
            if got != flags { return "op \(op) tick \(tick): state \(got), expected \(flags)" }
            if !close(state.frame, frame, tolerance) { return "op \(op) tick \(tick): frame \(state.frame), expected \(frame)" }
            let expected = (fields[5].array ?? []).map { ($0.array ?? []).compactMap(\.number).map(Float.init) }
            for (index, site) in sites.enumerated() {
                let value = Array((set.value(of: site) ?? []).prefix(widths[index]))
                let wanted = expected[index]
                if value.count != wanted.count || zip(value, wanted).contains(where: { !close($0, $1, tolerance) }) {
                    return "op \(op) tick \(tick): \(site) = \(value), expected \(wanted)"
                }
            }
            return nil
        }

        if let mismatch = compare(-1, 0, fired: []) { return mismatch }
        for (index, op) in (run.member("ops")?.array ?? []).enumerated() {
            let fields = op.array ?? []
            let name = fields.first?.string ?? "?"
            switch name {
            case "advance", "cycle":
                let count = Int(fields[2].number ?? 0)
                let deltas = name == "advance" ? [Float(fields[1].number ?? 0)]
                    : (fields[1].array ?? []).compactMap(\.number).map(Float.init)
                for tick in 0..<count {
                    let frame = set.advance(by: deltas[tick % deltas.count])
                    if let mismatch = compare(index, tick, fired: frame.events) { return mismatch }
                }
                continue
            case "play": set.perform(.play, on: sites[0])
            case "pause": set.perform(.pause, on: sites[0])
            case "stop": set.perform(.stop, on: sites[0])
            case "setFrame": set.perform(.setFrame(Float(fields[1].number ?? 0)), on: sites[0])
            case "rate": set.perform(.setRate(Float(fields[1].number ?? 0)), on: sites[0])
            default: return "unknown op \(name)"
            }
            set.refresh()
            if let mismatch = compare(index, 0, fired: []) { return mismatch }
        }
        let expectedCount = run.member("records")?.array?.count ?? 0
        return checked == expectedCount ? nil : "checked \(checked) of \(expectedCount) records"
    }

    /// A scene with one layer (id 3) holding the members at `owner`.
    private static func document(_ members: [SceneJSON], owner: SceneAnimationOwner) -> SceneJSON {
        var block: [String: SceneJSON] = [:]
        for member in members {
            guard let key = member.member("key")?.string, let animation = member.member("animation") else { continue }
            var holder: [String: SceneJSON] = ["animation": animation]
            if let value = member.member("value"), value != .null { holder["value"] = value }
            block[key] = .object(holder)
        }
        var layer: [String: SceneJSON] = ["id": .number(3), "image": .string("models/layer.json")]
        if case .material = owner {
            let pass: SceneJSON = .object(["constantshadervalues": .object(block)])
            layer["effects"] = .array([.object(["file": .string("effects/tint/effect.json"), "passes": .array([pass])])])
        } else {
            layer.merge(block) { $1 }
        }
        return .object(["objects": .array([.object(layer)])])
    }

    private static func close(_ value: Float, _ expected: Float, _ tolerance: Float) -> Bool {
        abs(value - expected) <= tolerance * max(1, abs(expected))
    }
}

private extension SceneJSON {
    func member(_ key: String) -> SceneJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var array: [SceneJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var string: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var number: Double? {
        if case .number(let number) = self { return number }
        return nil
    }
}
