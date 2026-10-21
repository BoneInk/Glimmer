import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Every animated library scene (docs/timeline-plan.md T6) loaded through the real loader and
/// drawn headlessly by the real renderer, its scripts running, the clock stepped 1/60 s a frame.
/// What each frame drew (`SceneDrawProbe`) is checked against the timelines:
///
/// - Every timeline's drawn value (a layer's `alpha`, `origin`, `scale`, `angles.z`; a material
///   constant's uniform) equals the reference model's (`TimelineLibraryExpectations`: the
///   `load-60` run of `Timeline/library-expected.json`, or of the script run now for an item that
///   changed since) at its record ticks while its clock follows that run, and the set's own value
///   once a script moved the clock. A field a script owns that frame is the script's, not checked.
/// - Every sprite layer draws its texture's shared clock (a reference clock stepped whenever the
///   texture is drawn) or its script's override, and its frame changes.
/// - Halfway, a song with artwork starts (the replay media source), which is what most library
///   timelines wait for: thumbnail fades on effect constants, media titles' origins and alphas.
/// - Nothing drawn is NaN or infinite, and every animated site the renderer binds is in the set (TL1).
/// - Pacing: every draw advances the timelines exactly once, by exactly the frame's delta. The draw's
///   CPU time is reported (p50, p99, max after a second's warm-up; Debug numbers are the whole
///   renderer's, not the timelines', which `TimelineCostTests` measures), with a guard against
///   hitches outside the frames that answer the song's start.
///
/// Skipped when the library is absent (CI); `OWE_LIBRARY` replaces the roots.
final class TimelineLibraryRenderTests: XCTestCase {
    private static let frames = 180
    private static let warmUpFrames = 60
    /// When the song starts.
    private static let mediaFrame = 90
    private static let step = 1.0 / 60
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-timeline-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testEveryAnimatedLibrarySceneDrawsItsTimelines() throws {
        let items = try TimelineLibraryScenes.items()
        try XCTSkipIf(items.isEmpty, "wallpaper library not present")
        let roots = TimelineLibrarySweepTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        var scannedItems = Set<String>()
        let found = try TimelineLibrarySweepTests.findTimelines(roots: roots, scannedItems: &scannedItems)
        let expectations = try TimelineLibraryExpectations(found: found, scannedItems: scannedItems, roots: roots)
        LibraryReport.attach("Timeline library: beyond library-expected.json", expectations.notes)
        var report = "wallpaper\tsites vs model\tsites vs set\tscript-owned\tnot drawn\tsprite layers\tp50 ms\tp99 ms\tmax ms\n"
        for item in items {
            let result = try sweep(item, groups: expectations.groups(of: item.id), tolerance: expectations.tolerance)
            report += result.row + "\n"
        }
        print("Timeline library render sweep (\(Self.frames) frames at 60 Hz):\n\(report)")
    }

    // MARK: - One scene

    private struct Result {
        var row: String
    }

    /// A timeline the reference model has records for, as the renderer names it.
    private struct Member {
        var site: SceneAnimationSite
        var owner: SceneAnimationSite
        var width: Int
        var index: Int
    }

    private func sweep(_ item: TimelineLibraryScenes.Item, groups: [SceneJSON], tolerance: Float) throws -> Result {
        let content = try TimelineLibraryScenes.content(of: item)
        let media = SceneScriptReplayMediaSource()
        let scene = try Scene(content: content, services: services(media: media))
        defer { scene.close(item.directory) }
        let renderer = scene.renderer
        let probe = SceneDrawProbe()
        renderer.drawProbe = probe
        let set = try XCTUnwrap(renderer.animations, "\(item.id): no timelines")
        let objects = SceneScriptSceneDescriber.objects(of: content.timelines?.document ?? .null)

        // The groups of this scene's own document, their records by the tick they follow.
        var runs: [(members: [Member], records: [Int: TimelineOracle.Record], record: TimelineOracle.Record?)] = []
        for group in groups {
            let file = group[oracle: "file"]?.oracleString ?? ""
            guard file == "scene.json" || file.hasSuffix("::scene.json") else { continue }
            let paths = (group[oracle: "paths"]?.oracleArray ?? []).compactMap(\.oracleString)
            let widths = try (group[oracle: "components"]?.oracleArray ?? []).map(TimelineOracle.int)
            let sites = paths.map { Self.site($0, objects: objects) }
            guard let owner = sites.first ?? nil else { continue }
            var members: [Member] = []
            for (index, site) in sites.enumerated() {
                let site = try XCTUnwrap(site, "\(item.id) \(paths[index]): not a site")
                XCTAssertTrue(set.contains(site), "\(item.id): \(site) isn't in the set (TL1)")
                members.append(Member(site: site, owner: owner, width: widths[index], index: index))
            }
            guard let run = try TimelineOracle.runs(group[oracle: "runs"]).first(where: { $0.name == "load-60" }) else {
                XCTFail("\(item.id) \(paths): no load-60 run")
                continue
            }
            var records: [Int: TimelineOracle.Record] = [:]
            for record in run.records where record.op == 0 { records[record.tick] = record }
            runs.append((members, records, run.records.first { $0.op == -1 }))
        }
        // TL1: every constant the renderer binds to a timeline is in the set.
        for layer in content.layers {
            for plan in renderer.effectPlans(ofLayer: layer.id) {
                for pass in plan.passes {
                    for constant in pass.constants.dynamic {
                        guard let site = constant.source.animationSite else { continue }
                        XCTAssertTrue(set.contains(site), "\(item.id): the renderer binds \(site), which the set lacks (TL1)")
                    }
                }
            }
        }

        // Sprite layers: a reference clock per texture, stepped whenever a layer draws it.
        var spriteLayers: [(id: Int, texture: String)] = []
        var references: [String: SceneTextureAnimationClock] = [:]
        for layer in content.layers {
            guard let texture = layer.textureKey, let id = Int(layer.id), case .animated(let animation) = layer.source,
                  animation.frames.count > 1 else { continue }
            spriteLayers.append((id, texture))
            if references[texture] == nil { references[texture] = SceneTextureAnimationClock(frames: animation.frames) }
        }
        var spriteChanges: [Int: Set<Int32>] = [:]

        var checkedModel = Set<SceneAnimationSite>(), checkedSet = Set<SceneAnimationSite>(), owned = Set<SceneAnimationSite>()
        var undrawn = Set<SceneAnimationSite>()
        var frameTimes: [Double] = []
        for frame in 0...Self.frames {
            if frame == Self.mediaFrame { media.send(Self.song) }
            let counter = set.frameCounter
            let start = CACurrentMediaTime()
            scene.draw()
            let milliseconds = (CACurrentMediaTime() - start) * 1000
            if frame > Self.warmUpFrames { frameTimes.append(milliseconds) }
            XCTAssertEqual(set.frameCounter, counter + 1, "\(item.id) frame \(frame): one advance per draw")
            XCTAssertEqual(set.lastDelta, frame == 0 ? 0 : Float(Self.step), "\(item.id) frame \(frame)")
            if !(Self.mediaFrame..<Self.mediaFrame + 10).contains(frame), frame > 0 {
                XCTAssertLessThan(milliseconds, 1000, "\(item.id) frame \(frame): a hitch")
            }
            for (id, layer) in probe.layers {
                let values = [layer.opacity, layer.brightness, layer.local.origin.x, layer.local.origin.y,
                              layer.local.scale.x, layer.local.scale.y, layer.local.angle,
                              layer.color.x, layer.color.y, layer.color.z, layer.color.w]
                XCTAssertTrue(values.allSatisfy(\.isFinite), "\(item.id) frame \(frame): layer \(id) draws \(layer)")
            }
            for (site, value) in probe.constants {
                XCTAssertTrue(value.allSatisfy(\.isFinite), "\(item.id) frame \(frame): \(site) = \(value)")
            }

            // Timelines: frame n is n advances of 1/60 after the anchor, the model's tick n − 1.
            for run in runs {
                let record = frame == 0 ? run.record : run.records[frame - 1]
                guard let record, let clock = set.state(of: run.members[0].owner) else { continue }
                let followsModel = TimelineOracle.close(clock.time, record.time, tolerance)
                    && Self.state(clock.flags) == record.state
                for member in run.members {
                    let expected = followsModel ? record.values[member.index]
                        : Array((set.value(of: member.site) ?? []).prefix(member.width))
                    switch drawn(member.site, renderer: renderer, probe: probe) {
                    case .none:
                        undrawn.insert(member.site)
                    case .some(.scriptOwned):
                        owned.insert(member.site)
                    case .some(.value(let value, let first)):
                        let compared = zip(value, expected.dropFirst(first))
                        XCTAssertFalse(compared.contains { !TimelineOracle.close($0, $1, max(tolerance, 1e-4)) },
                                       "\(item.id) frame \(frame): \(member.site) drew \(value), expected \(expected)"
                                       + (followsModel ? " (the model's)" : " (the set's; a script moved the clock)"))
                        if followsModel { checkedModel.insert(member.site) } else { checkedSet.insert(member.site) }
                    }
                }
            }

            // Sprites.
            let delta = frame == 0 ? 0 : Float(Self.step)
            var drawnTextures = Set<String>()
            for layer in spriteLayers where probe.layers[String(layer.id)] != nil { drawnTextures.insert(layer.texture) }
            for texture in drawnTextures { references[texture]?.advance(tick: UInt64(frame + 1), delta: delta) }
            for layer in spriteLayers {
                guard let drawn = probe.spriteFrames[layer.id], let state = set.textures.state(object: layer.id) else { continue }
                spriteChanges[layer.id, default: []].insert(drawn)
                let expected = state.control.overridden ? state.control.frame : references[layer.texture]?.frame
                XCTAssertEqual(drawn, expected, "\(item.id) frame \(frame): sprite layer \(layer.id)"
                               + (state.control.overridden ? " (its script's override)" : " (its texture's clock)"))
            }
        }
        for layer in spriteLayers where (spriteChanges[layer.id]?.count ?? 0) == 1 {
            let state = set.textures.state(object: layer.id)
            XCTAssertTrue(state?.control.overridden == true && state?.control.playing == false,
                          "\(item.id): sprite layer \(layer.id) never changed frame, and no script holds it")
        }

        let sorted = frameTimes.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))]
        let never = undrawn.subtracting(checkedModel).subtracting(checkedSet).subtracting(owned)
        for site in never.sorted(by: { $0.description < $1.description }) {
            let id = site.owner.objectID.map(String.init) ?? ""
            print("\(item.id): \(site) never drawn: layer drawn \(probe.layers[id] != nil), visible \(renderer.scripts.isVisible(id)), "
                  + "plans \(renderer.effectPlans(ofLayer: id).map { plan in (plan.effectIndex, plan.visible, plan.passes.map { pass in pass.constants.dynamic.map { ($0.uniform, $0.source.animationSite?.description ?? "-", pass.variant?.uniforms?.members[$0.uniform] != nil) } }) })")
        }
        let ownedOnly: Int = owned.subtracting(checkedModel).count
        let median: String = Self.format(sorted[sorted.count / 2])
        let worst: String = Self.format(sorted.last ?? 0)
        var columns: [String] = [item.id, String(checkedModel.count), String(checkedSet.count), String(ownedOnly)]
        columns.append(String(never.count))
        columns.append(String(spriteLayers.count))
        columns.append(median)
        columns.append(Self.format(p99))
        columns.append(worst)
        let row = columns.joined(separator: "\t")
        return Result(row: row)
    }

    private enum Drawn {
        /// The drawn components, starting at the timeline's component `first`.
        case value([Float], first: Int)
        case scriptOwned
    }

    /// What the frame drew of the timeline at `site`; nil when nothing drew it (a hidden layer, a
    /// group or particle system, a chain still compiling).
    private func drawn(_ site: SceneAnimationSite, renderer: SceneMetalRenderer, probe: SceneDrawProbe) -> Drawn? {
        switch site.owner {
        case .object(let id):
            let script = renderer.scripts.object(String(id))
            guard let layer = probe.layers[String(id)] else { return nil }
            switch site.key {
            case "alpha": return script?.owns(.alpha) == true ? .scriptOwned : .value([layer.opacity], first: 0)
            case "origin":
                return script?.owns(.origin) == true ? .scriptOwned : .value([layer.local.origin.x, layer.local.origin.y], first: 0)
            case "scale":
                return script?.owns(.scale) == true ? .scriptOwned : .value([layer.local.scale.x, layer.local.scale.y], first: 0)
            case "angles":
                // Only `angles.z` is drawn.
                return script?.owns(.angles) == true ? .scriptOwned : .value([layer.local.angle], first: 2)
            default: return nil
            }
        case let .material(id, effect, _):
            if renderer.scripts.object(String(id))?.constants[effect]?.contains(where: {
                $0.name.lowercased() == site.key.lowercased()
            }) == true {
                return .scriptOwned
            }
            return probe.constants[site].map { .value($0, first: 0) }
        case .scene, .particleInstance, .effect, .animationLayer:
            return nil
        }
    }

    private static func state(_ flags: SceneTimelineClock.Flags) -> Int {
        (flags.contains(.paused) ? 1 : 0) | (flags.contains(.finished) ? 2 : 0) | (flags.contains(.reversed) ? 4 : 0)
    }

    /// The site a reference-model path names (`objects/<index>/<key>`,
    /// `objects/<index>/effects/<e>/passes/<p>/constantshadervalues/<key>`, `general/<key>`).
    private static func site(_ path: String, objects: [[String: SceneJSON]]) -> SceneAnimationSite? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "general" { return SceneAnimationSite(owner: .scene, key: parts[1]) }
        guard parts.count >= 3, parts[0] == "objects", let index = Int(parts[1]), index < objects.count else { return nil }
        let id = SceneScriptSceneDescriber.objectID(objects[index], index: index)
        if parts.count == 3 { return SceneAnimationSite(owner: .object(id), key: parts[2]) }
        if parts.count == 4, parts[2] == "instanceoverride" { return SceneAnimationSite(owner: .particleInstance(id), key: parts[3]) }
        guard parts.count == 8, parts[2] == "effects", let effect = Int(parts[3]), parts[4] == "passes",
              let pass = Int(parts[5]), parts[6] == "constantshadervalues" else { return nil }
        return SceneAnimationSite(owner: .material(object: id, effect: effect, pass: pass), key: parts[7])
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private func services(media: SceneScriptReplayMediaSource) -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: media, spectrum: { .silent })
    }

    /// A song playing, with its title and artwork.
    private static var song: MediaSessionState {
        var state = MediaSessionState()
        state.enabled = true
        state.playback = .playing
        state.properties = .init(title: "Sweep Song", artist: "Sweep Artist", albumTitle: "Sweep Album", contentType: "audio")
        state.thumbnail = .init(artwork: 1, colors: .init(primary: SIMD3(0.8, 0.2, 0.1), secondary: SIMD3(0.1, 0.3, 0.7),
                                                          tertiary: SIMD3(0.9, 0.9, 0.2), text: SIMD3(1, 1, 1),
                                                          highContrast: SIMD3(0, 0, 0)))
        state.timeline = .init(position: 0, duration: 200)
        return state
    }

    /// A content on one offscreen view, its clock stepped 1/60 s per draw; the first draw anchors it.
    private final class Scene {
        let renderer: SceneMetalRenderer
        let view: MTKView
        private var now: CFTimeInterval = 1000

        init(content: SceneMetalContent, services: SceneScriptServices) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 144), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: 256, height: 144)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "timeline-sweep"))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(renderer.hasContent)
            now -= TimelineLibraryRenderTests.step
        }

        func draw() {
            now += TimelineLibraryRenderTests.step
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            RunLoop.main.run(until: Date())
        }

        func close(_ directory: URL) {
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }
    }
}
