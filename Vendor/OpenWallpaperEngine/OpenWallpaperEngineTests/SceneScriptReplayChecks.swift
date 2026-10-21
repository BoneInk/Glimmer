import Foundation
@testable import OpenWallpaperEngine

/// The WP9 assertions over a replay result (docs/scenescript-plan.md §5 WP9 (a)–(f)), as findings a
/// test compares with its expected-failure list. Each finding names the script (corpus hash) or the
/// wallpaper it is about.
enum SceneScriptReplayChecks {
    enum Check: String, CaseIterable {
        /// A compile error, a module body or callback that threw, or a runtime-internal error.
        case exception
        /// The watchdog stopped the runtime.
        case watchdog
        /// A text site or a string write showed "undefined" or "NaN", or was not a string.
        case text
        /// A numeric or vector site, a table field or a `shared` number was not finite.
        case finite
        /// A script of an animating class left its value unchanged where the class says it changes.
        case change
        /// The median CPU time of a frame exceeded the budget.
        case budget
    }

    struct Finding: CustomStringConvertible {
        var check: Check
        /// The script's corpus hash, or the wallpaper id for wallpaper-wide findings.
        var key: String
        var message: String

        var description: String { "[\(check.rawValue)] \(key): \(message)" }
    }

    /// WE's target for a whole scene's scripts (plan §4.6).
    static let budgetMilliseconds = 0.5
    /// The test fails only past twice the target: the full suite loads the machine, and the
    /// target itself is tracked in the replay report and the optimisation pass.
    static let failureMilliseconds = budgetMilliseconds * 2

    /// What a script's source says it does, for the per-class change expectations (plan WP9 (e)).
    enum ScriptClass: String {
        /// Reads audio buffers in `update`: varies under the tone, settles under silence.
        case audio
        /// Formats `Date` into a text: changes when the clock passes midnight.
        case clock
        /// Sets an effect's visibility from `mediaThumbnailChanged`: follows `hasThumbnail`.
        case mediaThumbnail
        /// Shows media properties in a text: follows the track.
        case mediaText
        /// Anything else: no change expectation.
        case other
    }

    static func scriptClass(of site: SceneScriptReplayWallpaper.Site, type: SceneScriptReplayFieldType) -> ScriptClass {
        let exports = self.exports(of: site.source)
        let source = site.source
        if exports.contains("update"), type.isNumeric, type != .bool, source.contains("registerAudioBuffers") {
            return .audio
        }
        if exports.contains("update"), type == .string, source.contains("Date") { return .clock }
        if exports.contains("mediaThumbnailChanged"), type == .bool, site.field.hasPrefix("effects."),
           source.contains("hasThumbnail") {
            return .mediaThumbnail
        }
        if exports.contains("mediaPropertiesChanged"), type == .string { return .mediaText }
        return .other
    }

    static func exports(of source: String) -> Set<String> {
        do {
            var scanner = SceneScriptModuleScanner(tokens: try SceneScriptTokenizer.tokenize(source))
            return Set(try scanner.scan().exports.map(\.name))
        } catch {
            return []
        }
    }

    static func findings(_ result: SceneScriptReplayHarness.Result,
                         options: SceneScriptReplayHarness.Options) -> [Finding] {
        var findings: [Finding] = []
        let hashByID = Dictionary(result.sites.map { ($0.id, $0.site.hash) }, uniquingKeysWith: { first, _ in first })
        let fieldByID = Dictionary(result.sites.map { ($0.id, $0.site.field) }, uniquingKeysWith: { first, _ in first })

        for (index, error) in result.errors.enumerated() {
            let frame = index < result.errorFrames.count ? result.errorFrames[index] : -1
            let when = frame < 0 ? "load" : "frame \(frame)"
            let key = hashByID[error.scriptID] ?? result.wallpaperID
            let site = fieldByID[error.scriptID].map { " on \($0)" } ?? ""
            switch error.kind {
            case .terminated:
                findings.append(Finding(check: .watchdog, key: key, message: "\(error.callback)\(site): \(error.message)"))
            case .compile, .runtime, .internal:
                let line = error.line.map { " line \($0)" } ?? ""
                findings.append(Finding(check: .exception, key: key,
                                        message: "\(error.kind.rawValue) in \(error.callback)\(line)\(site) (\(when)): \(error.message)"))
            }
        }
        if result.halted, !result.errors.contains(where: { $0.kind == .terminated }) {
            findings.append(Finding(check: .watchdog, key: result.wallpaperID, message: "the runtime halted"))
        }

        for record in result.sites {
            findings += siteFindings(record, options: options)
        }
        // Table and string problems a site finding does not already name (another script's
        // writes, `shared`).
        let reported = Set(findings.compactMap { finding -> String? in
            guard let record = result.sites.first(where: { $0.site.hash == finding.key }), let slot = record.slot else {
                return nil
            }
            return "\(slot) \(finding.check.rawValue) \(record.site.field)"
        })
        var textSlots = Set<String>()
        for write in result.strings where write.value.contains("undefined") || write.value.contains("NaN") {
            let place = "\(write.slot) text \(write.field.rawValue)"
            guard !reported.contains(place), textSlots.insert(place).inserted else { continue }
            findings.append(Finding(check: .text, key: result.wallpaperID,
                                    message: "slot \(write.slot) \(write.field.rawValue) set to \"\(write.value.prefix(80))\""))
        }
        for entry in result.nonFinite {
            if let slot = entry.slot, reported.contains("\(slot) finite \(entry.field)") { continue }
            let place = entry.slot.map { "slot \($0) \(entry.field)" } ?? entry.field
            findings.append(Finding(check: .finite, key: result.wallpaperID,
                                    message: "\(place) from frame \(entry.frame): \(entry.value.prefix(60))"))
        }
        // The median CPU time of the script thread: other processes on a shared machine add
        // spikes and waits, not script cost.
        if result.percentile(0.5, cpu: true) >= failureMilliseconds {
            findings.append(Finding(check: .budget, key: result.wallpaperID,
                                    message: String(format: "p50 %.3f ms CPU/frame (wall p50 %.3f, p99 %.3f)",
                                                    result.percentile(0.5, cpu: true), result.percentile(0.5),
                                                    result.percentile(0.99))))
        }
        return deduplicated(findings)
    }

    // MARK: - Per site

    private static func siteFindings(_ record: SceneScriptReplayHarness.SiteRecord,
                                     options: SceneScriptReplayHarness.Options) -> [Finding] {
        var findings: [Finding] = []
        let key = record.site.hash
        let place = record.site.field
        if record.type == .string {
            if let (frame, value) = record.samples.enumerated().lazy.compactMap({ frame, sample -> (Int, String)? in
                guard let text = sample as? String else { return (frame, "\(sample is NSNull ? "undefined" : "\(sample)")") }
                return text.contains("undefined") || text.contains("NaN") ? (frame, text) : nil
            }).first {
                findings.append(Finding(check: .text, key: key, message: "\(place) at frame \(frame): \"\(value.prefix(80))\""))
            }
        } else {
            let bad = record.samples.indices.filter { !finite(record.samples[$0]) }
            if let first = bad.first {
                let value = "\(record.samples[first])".split(whereSeparator: \.isWhitespace).joined(separator: " ")
                findings.append(Finding(check: .finite, key: key,
                                        message: "\(place) not finite in \(bad.count) frames from frame \(first): \(value.prefix(60))"))
            }
        }

        let samples = record.samples
        guard samples.count == options.frames else { return findings }
        switch scriptClass(of: record.site, type: record.type) {
        case .audio:
            let tone = options.toneFrames.clamped(to: 0..<samples.count)
            if distinctCount(samples[tone]) < 3 {
                findings.append(Finding(check: .change, key: key, message: "\(place): audio-driven value did not vary under the tone (\(excerpt(samples, tone)))"))
            }
            let tail = max(tone.upperBound, samples.count - 30)..<samples.count
            if tail.count > 1, spread(samples[tail]) > 0.1 * spread(samples[tone]) + 1e-6 {
                findings.append(Finding(check: .change, key: key, message: "\(place): audio-driven value still varies under silence (\(excerpt(samples, tail)))"))
            }
        case .clock:
            if distinctCount(samples[...]) < 2 {
                findings.append(Finding(check: .change, key: key, message: "\(place): clock text never changed across midnight"))
            }
        case .mediaThumbnail:
            // No thumbnail from 360, a new one at 480: the visibility must differ at some point.
            let without = samples[375]
            if !samples[480..<540].contains(where: { !equal($0, without) }) {
                findings.append(Finding(check: .change, key: key,
                                        message: "\(place): effect visibility ignores hasThumbnail (\(excerpt(samples, 360..<540)))"))
            }
        case .mediaText:
            // New properties at 360 (stopped) and 480 (playing): the text must follow at some point.
            let before = samples[350]
            if !samples[360...].contains(where: { !equal($0, before) }) {
                findings.append(Finding(check: .change, key: key,
                                        message: "\(place): text did not follow the media properties (\(excerpt(samples, 340..<600)))"))
            }
        case .other:
            break
        }
        return findings
    }

    static func finite(_ sample: Any) -> Bool {
        switch sample {
        case let number as NSNumber: return number.doubleValue.isFinite
        case let array as [Any]: return array.allSatisfy { ($0 as? NSNumber)?.doubleValue.isFinite == true }
        case is NSNull: return true
        default: return false
        }
    }

    /// Five samples across `range`, for messages.
    private static func excerpt(_ samples: [Any], _ range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        let step = max(1, range.count / 5)
        return stride(from: range.lowerBound, to: range.upperBound, by: step).prefix(5).map { index in
            "\(index): " + "\(samples[index])".split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40)
        }.joined(separator: ", ")
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }

    private static func distinctCount(_ samples: ArraySlice<Any>) -> Int {
        Set(samples.map { "\($0)" }).count
    }

    /// The largest change of any component across `samples`.
    private static func spread(_ samples: ArraySlice<Any>) -> Double {
        func numbers(_ sample: Any) -> [Double] {
            if let number = sample as? NSNumber { return [number.doubleValue] }
            return (sample as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        }
        let rows = samples.map(numbers)
        guard let width = rows.map(\.count).min(), width > 0 else { return 0 }
        return (0..<width).map { column in
            let values = rows.map { $0[column] }.filter(\.isFinite)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }.max() ?? 0
    }

    private static func deduplicated(_ findings: [Finding]) -> [Finding] {
        var seen = Set<String>()
        return findings.filter { seen.insert($0.description).inserted }
    }
}
