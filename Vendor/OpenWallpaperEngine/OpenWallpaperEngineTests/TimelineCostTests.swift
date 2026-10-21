import XCTest
@testable import OpenWallpaperEngine

/// What the timelines cost the render thread per frame (docs/timeline-plan.md T6, test-risks TL20):
/// `SceneRendererAnimations.advance` and the frame's reads (every layer's animated fields, every
/// animated material constant, every layer's sprite frame and, with scripts, their `IAnimation`
/// states), measured as thread CPU time.
///
/// The numbers that matter come from an optimised build (`SWIFT_OPTIMIZATION_LEVEL=-O`); the
/// assertions only guard against order-of-magnitude regressions, with room for an unoptimised
/// build (`slowdown`: Debug solves a Bézier about 100× slower).
/// Set `OWE_TIMELINE_COST_REPORT` to a path to get the table as a file.
final class TimelineCostTests: XCTestCase {
    private static let warmUpFrames = 600
    private static let measuredFrames = 600
    private static let delta: Float = 1 / 60
    #if DEBUG
    private static let slowdown = 25.0
    #else
    private static let slowdown = 1.0
    #endif

    /// Every animated library scene through the real loader: per-frame p50 / p99 / max.
    func testTheLibrarysTimelinesCostLittlePerFrame() throws {
        let items = try TimelineLibraryScenes.items()
        try XCTSkipIf(items.isEmpty, "wallpaper library not present")
        var report = "wallpaper\ttimelines\tsprite layers\tp50 µs\tp99 µs\tmax µs\n"
        var over: [String] = []
        for item in items {
            let content = try TimelineLibraryScenes.content(of: item)
            let frame = Frame(content: content)
            for _ in 0..<Self.warmUpFrames { frame.run() }
            var samples: [Double] = []
            for _ in 0..<Self.measuredFrames {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                frame.run()
                samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1000)
            }
            let sorted = samples.sorted()
            let p99 = Self.percentile(sorted, 0.99)
            report += [item.id, String(frame.timelineCount), String(frame.spriteLayers.count),
                       Self.format(Self.percentile(sorted, 0.5)), Self.format(p99),
                       Self.format(sorted.last ?? 0)].joined(separator: "\t") + "\n"
            if p99 > 50 * Self.slowdown { over.append("\(item.id): \(Self.format(p99)) µs") }
        }
        print("Timeline cost per frame, library:\n\(report)")
        if let path = ProcessInfo.processInfo.environment["OWE_TIMELINE_COST_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(over.isEmpty, "p99 over TL20's 50 µs budget (×\(Self.slowdown) unoptimised): \(over)")
    }

    /// Many timelines (two per layer: a 600-frame `alpha` loop and a three-channel 600-frame
    /// `origin` mirror): the steady cost grows with the count, not with the length of the channels.
    /// A Debug timing bound that CI's slower runners overshoot, so it runs nightly and locally.
    func testManyTimelinesCostLittlePerFrame() throws {
        try SlowTests.require()
        var lines: [String] = []
        for count in [20, 128, 1000] {
            let frame = Frame(document: Self.syntheticScene(layers: count / 2))
            for _ in 0..<Self.warmUpFrames { frame.run() }
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for _ in 0..<Self.measuredFrames { frame.run() }
            let perFrame = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1000 / Double(Self.measuredFrames)
            lines.append("\(count) timelines: \(Self.format(perFrame)) µs")
            XCTAssertLessThan(perFrame, Double(count) * Self.slowdown / 2, "\(count) timelines")
        }
        print("Timeline cost per frame, synthetic: \(lines.joined(separator: ", "))")
    }

    /// TL20 / TF8: jumping far into cold channels (`setFrame(599)` on 128 timelines of 600
    /// frames) must not cost a frame: nothing samples the frames it skipped.
    func testAJumpIntoColdChannelsIsCheap() throws {
        let frame = Frame(document: Self.syntheticScene(layers: 64))
        let set = try XCTUnwrap(frame.timelines.set)
        for _ in 0..<10 { frame.run() }
        for site in set.sites { set.perform(.setFrame(599), on: site) }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        frame.run()
        let microseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1000
        print("Timeline cost of the first frame after setFrame(599) on 128 timelines: \(Self.format(microseconds)) µs")
        XCTAssertLessThan(microseconds, 2000 * Self.slowdown, "a jump costs a frame")
    }

    // MARK: - Support

    /// One frame of the renderer's timeline work over a content's (or a bare set's) timelines.
    private final class Frame {
        let timelines = SceneRendererAnimations()
        let layerKeys: [String]
        let materialSites: [SceneAnimationSite]
        let spriteLayers: [Int]
        let scripted: Bool
        var timelineCount: Int { timelines.set?.sites.count ?? 0 }

        init(content: SceneMetalContent) {
            timelines.setTimelines(content.timelines, restart: true)
            var sprites: [Int] = []
            for layer in content.layers {
                guard let key = layer.textureKey, let id = Int(layer.id),
                      case .animated(let animation) = layer.source else { continue }
                timelines.registerTexture(object: id, texture: key, frameTimes: animation.frames.map(\.duration))
                sprites.append(id)
            }
            spriteLayers = sprites
            layerKeys = content.layers.map(\.id) + content.motions.keys.sorted()
            materialSites = Self.materialSites(timelines.set)
            scripted = content.scripts != nil
        }

        init(document: SceneJSON) {
            timelines.setTimelines(SceneTimelineSource(wallpaperID: "cost", document: document, signature: ""), restart: true)
            layerKeys = Set((timelines.set?.sites ?? []).compactMap(\.owner.objectID)).sorted().map(String.init)
            materialSites = Self.materialSites(timelines.set)
            spriteLayers = []
            scripted = true
        }

        private static func materialSites(_ set: SceneAnimationSet?) -> [SceneAnimationSite] {
            (set?.sites ?? []).filter { if case .material = $0.owner { return true } else { return false } }
        }

        func run() {
            let events = timelines.advance(by: TimelineCostTests.delta)
            for key in layerKeys { _ = timelines.object(key) }
            let values = timelines.values
            for site in materialSites { _ = values.animationValue(site) }
            for id in spriteLayers { _ = timelines.spriteFrame(object: id, delta: TimelineCostTests.delta) }
            if scripted {
                var input = SceneScriptFrameInput()
                timelines.describe(into: &input, events: events)
            }
        }
    }

    /// `layers` objects, each with a 600-frame `alpha` loop and a three-channel 600-frame `origin`
    /// mirror, on WE's default (ease) handles like the library's keyframes.
    static func syntheticScene(layers: Int) -> SceneJSON {
        func key(_ frame: Int, _ value: Int) -> String {
            #"{"frame": \#(frame), "value": \#(value), "back": {"enabled": true, "x": -1, "y": 0}, "front": {"enabled": true, "x": 1, "y": 0}}"#
        }
        var objects: [String] = []
        for index in 0..<layers {
            let alpha = #""c0": [\#(key(0, 0)), \#(key(300, 1)), \#(key(600, 0))]"#
            let origin = (0..<3).map { channel in
                #""c\#(channel)": [\#(key(0, 0)), \#(key(170, index)), \#(key(450, -3)), \#(key(600, 0))]"#
            }.joined(separator: ", ")
            objects.append(#"{"id": \#(index), "#
                + #""alpha": {"value": 1, "animation": {\#(alpha), "options": {"fps": 60, "length": 600, "mode": "loop"}}}, "#
                + #""origin": {"value": "0 0 0", "animation": {\#(origin), "options": {"fps": 30, "length": 600, "mode": "mirror"}}}}"#)
        }
        let json = #"{"objects": [\#(objects.joined(separator: ","))]}"#
        do {
            return try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        } catch {
            fatalError("the synthetic scene doesn't decode: \(error)")
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
