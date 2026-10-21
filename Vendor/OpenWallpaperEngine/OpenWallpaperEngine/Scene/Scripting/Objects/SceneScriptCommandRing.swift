import Foundation
import JavaScriptCore

/// Script requests that need native work (`play`, `setFrame`, `emitParticles`,
/// `setMaterialProperty`, `createLayer`, …), queued in shared memory during the script phase and
/// executed by Swift after it, in order (docs/scenescript-plan.md §4.3).
///
/// JS appends with `__rt.push(opcode, target, numbers?, strings?)`. Each record is
/// `Layout.recordStride` Int32s: opcode, target (object slot or -1), first number, number count,
/// first string, string count. Numbers go into a shared Float32Array; strings, which are rare,
/// into a plain JS array read only for records that have them. A full ring drops further commands
/// for the frame and logs once. Confined to the runtime's thread.
final class SceneScriptCommandRing {
    /// A command kind. Packages declare theirs in their own files, in their own range:
    /// 1–99 runtime, 100–199 engine/timers/storage (WP4), 200–299 audio (WP5), 300–399 media (WP6),
    /// 400–999 object model (WP7), 1000+ later packages.
    struct Opcode: RawRepresentable, Hashable {
        let rawValue: Int32
        init(rawValue: Int32) { self.rawValue = rawValue }
    }

    struct Command {
        var opcode: Opcode
        /// The object slot, or -1.
        var target: Int32
        var numbers: [Float]
        var strings: [String]
    }

    enum Layout {
        static let recordStride = 6
        /// header[0] command count, header[1] numbers used, header[2] overflow flag.
        static let headerCount = 4
    }

    typealias Handler = (Command) -> Void

    let capacity: Int
    private let header: SceneScriptSharedBuffer<Int32>
    private let records: SceneScriptSharedBuffer<Int32>
    private let numbers: SceneScriptSharedBuffer<Float>
    private let rt: JSValue
    private var handlers: [Opcode: Handler] = [:]
    private var reportedUnknown = Set<Int32>()
    private var reportedOverflow = false

    /// Allocates the ring and attaches it to `__rt` (`rt` is the runtime's `__rt` object).
    init?(capacity: Int, numberCapacity: Int, rt: JSValue) {
        guard let context = rt.context,
              let header = SceneScriptSharedBuffer<Int32>(count: Layout.headerCount, in: context),
              let records = SceneScriptSharedBuffer<Int32>(count: capacity * Layout.recordStride, in: context),
              let numbers = SceneScriptSharedBuffer<Float>(count: numberCapacity, in: context) else { return nil }
        self.capacity = capacity
        self.header = header
        self.records = records
        self.numbers = numbers
        self.rt = rt
        rt.invokeMethod("attachRing", withArguments: [header.value, records.value, numbers.value, Layout.recordStride])
    }

    /// The buffers scripts can reach (`__rt.ring`), for `SceneScriptRuntime.watch(_:)`.
    var sharedBuffers: [SceneScriptDetachable] { [header, records, numbers] }

    /// Registers the native side of `opcode`. One handler per opcode.
    func register(_ opcode: Opcode, handler: @escaping Handler) {
        precondition(handlers[opcode] == nil, "SceneScript opcode \(opcode.rawValue) registered twice")
        handlers[opcode] = handler
    }

    var pendingCount: Int { Int(header[0]) }

    /// Executes and clears the queued commands, in the order scripts issued them. A handler that
    /// calls back into JavaScript can push more commands while this runs (S11): they are appended
    /// behind the ones being executed and run in the same drain, before the ring is reset. The
    /// ring's capacity bounds how many a drain can run, so a handler that keeps pushing ends in
    /// the overflow, never in a loop.
    func drain() {
        guard header[0] > 0 || header[2] != 0 else { return }
        var executed = 0
        var usedStrings = false
        while true {
            let count = min(max(0, Int(header[0])), capacity)
            guard executed < count else { break }
            let hasStrings = (executed..<count).contains { records[$0 * Layout.recordStride + 5] > 0 }
            usedStrings = usedStrings || hasStrings
            let strings: [String] = hasStrings
                ? (rt.forProperty("ring")?.forProperty("strings")?.toArray() as? [String] ?? [])
                : []
            for index in executed..<count {
                execute(record: index, strings: strings)
            }
            executed = count
        }
        let overflowed = header[2] != 0
        if overflowed && !reportedOverflow {
            reportedOverflow = true
            OWELog.error(.script, "SceneScript command ring full (\(capacity) commands); later commands were dropped")
        }
        if usedStrings {
            rt.invokeMethod("resetRing", withArguments: [])
        } else {
            // No strings to drop: the header is shared memory, so no call into JavaScript.
            header[0] = 0
            header[1] = 0
            header[2] = 0
        }
    }

    private func execute(record index: Int, strings: [String]) {
        let base = index * Layout.recordStride
        let opcode = Opcode(rawValue: records[base])
        let numberStart = Int(records[base + 2])
        let numberCount = Int(records[base + 3])
        let stringStart = Int(records[base + 4])
        let stringCount = Int(records[base + 5])
        // Scripts can reach the typed arrays, so never trust a record's ranges.
        guard numberStart >= 0, numberCount >= 0, numberStart + numberCount <= numbers.count else { return }
        guard let handler = handlers[opcode] else {
            if reportedUnknown.insert(opcode.rawValue).inserted {
                OWELog.error(.script, "SceneScript command \(opcode.rawValue) has no native handler")
            }
            return
        }
        var commandNumbers: [Float] = []
        commandNumbers.reserveCapacity(numberCount)
        for offset in 0..<numberCount { commandNumbers.append(numbers[numberStart + offset]) }
        var commandStrings: [String] = []
        if stringCount > 0, stringStart >= 0, stringStart + stringCount <= strings.count {
            commandStrings = Array(strings[stringStart..<(stringStart + stringCount)])
        }
        handler(Command(opcode: opcode, target: records[base + 1], numbers: commandNumbers, strings: commandStrings))
    }
}
