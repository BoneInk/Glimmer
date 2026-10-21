import Foundation
@testable import OpenWallpaperEngine

/// Runs the oracle of `Scripts/timeline-reference.py` (WE's timeline maths as a float32 reference
/// model) against `SceneTimelineAnimation` and `SceneTextureAnimationClock`.
///
/// A *group* is a clock owner and the timelines linked to it (`options.parent`, §2.5 of
/// docs/timeline-plan.md). A *run* is a list of ops applied to the owner's clock, as T2 will apply
/// them each frame: `advance(by: delta × rate)`, and the `IAnimation` calls. After selected ticks
/// the oracle records the clock's time, its state, `getFrame()` and every timeline's value on the
/// owner's clock; the events fired are recorded on every tick that fires any.
enum TimelineOracle {
    enum Op {
        /// `count` ticks of `delta` seconds.
        case advance(Float, count: Int)
        /// `count` ticks; tick k uses `deltas[k % deltas.count]`.
        case cycle([Float], count: Int)
        case play, pause, stop
        case setFrame(Float)
        case rate(Float)

        var ticks: Int {
            switch self {
            case let .advance(_, count), let .cycle(_, count): return count
            default: return 0
            }
        }

        func delta(at tick: Int) -> Float {
            switch self {
            case let .advance(delta, _): return delta
            case let .cycle(deltas, _): return deltas[tick % deltas.count]
            default: return 0
            }
        }
    }

    /// The owner's state after a tick (`tick` within an advance op) or after a control op (tick 0).
    /// `op` −1 is the state before the first op.
    struct Record {
        var op: Int
        var tick: Int
        var time: Float
        /// 1 paused, 2 finished, 4 running backwards (mirror).
        var state: Int
        var frame: Float
        /// Per timeline, the components that exist (the property's width, capped at the channels).
        var values: [[Float]]
    }

    struct Run {
        var name: String
        var ops: [Op]
        var records: [Record]
        var events: [(op: Int, tick: Int, names: [String])]
    }

    struct Member {
        /// The property key (`origin`, a constant's name…); children name their owner's key.
        var key: String
        var value: SceneJSON?
        var components: Int
        var animation: SceneJSON
    }

    struct Mismatch: CustomStringConvertible {
        var run: String
        var op: Int
        var tick: Int
        var detail: String
        var description: String { "run \(run), op \(op) tick \(tick): \(detail)" }
    }

    // MARK: - Running

    /// Plays `run` on fresh timelines built from `members` and returns the first mismatch, if any.
    static func check(_ run: Run, members: [Member], tolerance: Float) throws -> Mismatch? {
        var timelines = try members.map {
            try SceneTimelineAnimation(json: $0.animation, staticValue: $0.value)
        }
        for child in timelines.dropFirst() where child.parentKey != members[0].key {
            return Mismatch(run: run.name, op: -1, tick: 0,
                            detail: "timeline follows '\(child.parentKey ?? "nothing")', not '\(members[0].key)'")
        }
        var expected: [String: Record] = [:]
        for record in run.records { expected["\(record.op):\(record.tick)"] = record }
        var expectedEvents: [String: [String]] = [:]
        for event in run.events { expectedEvents["\(event.op):\(event.tick)"] = event.names }
        var rate: Float = 1
        var checked = 0

        func compare(op: Int, tick: Int, fired: [String]) -> Mismatch? {
            let key = "\(op):\(tick)"
            let wanted = expectedEvents[key] ?? []
            if fired != wanted {
                return Mismatch(run: run.name, op: op, tick: tick, detail: "events \(fired), expected \(wanted)")
            }
            guard let record = expected[key] else { return nil }
            checked += 1
            let clock = timelines[0].clock
            if !close(clock.time, record.time, tolerance) {
                return Mismatch(run: run.name, op: op, tick: tick, detail: "time \(clock.time), expected \(record.time)")
            }
            if state(of: clock) != record.state {
                return Mismatch(run: run.name, op: op, tick: tick,
                                detail: "state \(state(of: clock)), expected \(record.state) (1 paused, 2 finished, 4 backwards)")
            }
            if !close(clock.frame, record.frame, tolerance) {
                return Mismatch(run: run.name, op: op, tick: tick, detail: "getFrame \(clock.frame), expected \(record.frame)")
            }
            for index in timelines.indices {
                let values = timelines[index].value(on: clock)
                let wanted = record.values[index]
                let got = Array(values.prefix(members[index].components))
                if got.count != wanted.count || zip(got, wanted).contains(where: { !close($0, $1, tolerance) }) {
                    return Mismatch(run: run.name, op: op, tick: tick,
                                    detail: "\(members[index].key) = \(got), expected \(wanted) at time \(clock.time)")
                }
            }
            return nil
        }

        if let mismatch = compare(op: -1, tick: 0, fired: []) { return mismatch }
        for (index, op) in run.ops.enumerated() {
            switch op {
            case .advance, .cycle:
                for tick in 0..<op.ticks {
                    let fired = timelines[0].clock.advance(by: rate * op.delta(at: tick)).map(\.name)
                    if let mismatch = compare(op: index, tick: tick, fired: fired) { return mismatch }
                }
                continue
            case .play: timelines[0].clock.play()
            case .pause: timelines[0].clock.pause()
            case .stop: timelines[0].clock.stop()
            case .setFrame(let frame): timelines[0].clock.setFrame(frame)
            case .rate(let value): rate = value
            }
            if let mismatch = compare(op: index, tick: 0, fired: []) { return mismatch }
        }
        if checked != run.records.count {
            return Mismatch(run: run.name, op: run.ops.count, tick: 0,
                            detail: "checked \(checked) of \(run.records.count) records: the ops don't reach them")
        }
        return nil
    }

    /// Relative to the value's size above 1, absolute below.
    static func close(_ value: Float, _ expected: Float, _ tolerance: Float) -> Bool {
        abs(value - expected) <= tolerance * max(1, abs(expected))
    }

    static func state(of clock: SceneTimelineClock) -> Int {
        (clock.flags.contains(.paused) ? 1 : 0) | (clock.flags.contains(.finished) ? 2 : 0)
            | (clock.flags.contains(.reversed) ? 4 : 0)
    }

    // MARK: - Decoding the fixture

    static func load(_ url: URL) throws -> SceneJSON {
        try JSONDecoder().decode(SceneJSON.self, from: Data(contentsOf: url))
    }

    static func runs(_ json: SceneJSON?) throws -> [Run] {
        try (json?.oracleArray ?? []).map { run in
            Run(name: run[oracle: "name"]?.oracleString ?? "?",
                ops: try (run[oracle: "ops"]?.oracleArray ?? []).map(op),
                records: try (run[oracle: "records"]?.oracleArray ?? []).map(record),
                events: try (run[oracle: "events"]?.oracleArray ?? []).map { entry in
                    let fields = try fields(entry, count: 3)
                    return (try int(fields[0]), try int(fields[1]), (fields[2].oracleArray ?? []).compactMap(\.oracleString))
                })
        }
    }

    private static func op(_ json: SceneJSON) throws -> Op {
        let fields = json.oracleArray ?? []
        switch fields.first?.oracleString {
        case "advance": return .advance(try float(fields[1]), count: try int(fields[2]))
        case "cycle": return .cycle(try (fields[1].oracleArray ?? []).map(float), count: try int(fields[2]))
        case "play": return .play
        case "pause": return .pause
        case "stop": return .stop
        case "setFrame": return .setFrame(try float(fields[1]))
        case "rate": return .rate(try float(fields[1]))
        default: throw OracleError.malformed("op \(json)")
        }
    }

    private static func record(_ json: SceneJSON) throws -> Record {
        let fields = try fields(json, count: 6)
        return Record(op: try int(fields[0]), tick: try int(fields[1]), time: try float(fields[2]),
                      state: try int(fields[3]), frame: try float(fields[4]),
                      values: try (fields[5].oracleArray ?? []).map { try ($0.oracleArray ?? []).map(float) })
    }

    private static func fields(_ json: SceneJSON, count: Int) throws -> [SceneJSON] {
        guard let fields = json.oracleArray, fields.count == count else { throw OracleError.malformed("\(json)") }
        return fields
    }

    static func float(_ json: SceneJSON) throws -> Float {
        guard let number = json.oracleNumber else { throw OracleError.malformed("number \(json)") }
        return Float(number)
    }

    static func int(_ json: SceneJSON) throws -> Int {
        guard let number = json.oracleNumber, number == number.rounded() else { throw OracleError.malformed("int \(json)") }
        return Int(number)
    }

    enum OracleError: Error {
        case malformed(String)
    }
}

extension SceneJSON {
    subscript(oracle key: String) -> SceneJSON? { oracleObject?[key] }

    var oracleObject: [String: SceneJSON]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var oracleArray: [SceneJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var oracleString: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var oracleNumber: Double? {
        if case .number(let number) = self { return number }
        return nil
    }
}
