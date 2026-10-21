import Foundation
import JavaScriptCore
@testable import OpenWallpaperEngine

/// Replays one wallpaper's scripts on the SceneScript runtime (docs/scenescript-plan.md WP9): the
/// real compiler, WE's prelude, the engine, audio, media and object-model extensions, over fake
/// sources driven by a fixed schedule, and records what a test asserts on.
///
/// The schedule (frames at 60 fps):
/// - clock: `startDate` + scene time; the default starts 8 s before a new year, so every date and
///   time field of a clock changes during the run;
/// - audio: silence until `toneFrames.lowerBound`, a moving two-channel tone until its end, then
///   silence again;
/// - cursor: WP10's cursor pass with the renderer's stand-in (each object's world transform is its
///   own origin and scale, an image or text without a size is 64 × 64). The cursor moves on a
///   Lissajous path; from each of `clickFrames` it clicks every Solid object with scripts in turn:
///   over it, button down, button up, away, one step per frame;
/// - media: enabled and playing with a thumbnail at 30, timeline ticks, paused at 240, stopped
///   without thumbnail and with new properties at 360, playing with a new thumbnail at 480;
/// - user properties: every flag flipped, every slider at its maximum and every combo on another
///   option at 420, all back at 540.
final class SceneScriptReplayHarness {
    struct Options {
        var frames = 600
        var deltaTime = 1.0 / 60
        var startDate: Date = SceneScriptReplayHarness.defaultStartDate
        var toneFrames = 150..<450
        var clickFrames = [300, 460]
        var configuration = SceneScriptRuntime.Configuration.standard
    }

    /// 23:59:52 local time on 31 December 2026.
    static let defaultStartDate: Date = {
        var components = DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 52)
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    /// What happened to one site over the run.
    struct SiteRecord {
        var id: String
        var site: SceneScriptReplayWallpaper.Site
        var type: SceneScriptReplayFieldType
        /// The object table slot of the site's object, nil for scene-level sites.
        var slot: Int?
        /// One sample per frame (after the frame): see `SceneScriptReplaySupport.sample()`.
        var samples: [Any] = []
    }

    struct NonFinite {
        /// Nil for `shared` members.
        var slot: Int?
        /// A table field name, or `shared.<key>`.
        var field: String
        var frame: Int
        var value: String
    }

    struct Result {
        var wallpaperID: String
        var sites: [SiteRecord]
        var errors: [SceneScriptError]
        /// The frame each of `errors` was first reported in; -1 for the load.
        var errorFrames: [Int]
        var halted: Bool
        var loadMilliseconds: Double
        /// Wall-clock time per frame.
        var frameMilliseconds: [Double]
        /// CPU time of the script thread per frame: what the scripts cost, without the waits a
        /// loaded machine adds. The budget check uses it.
        var frameCPUMilliseconds: [Double]
        /// Strings written through `setString` commands (text, font, …), with their slot and field.
        var strings: [(slot: Int, field: SceneScriptStringField, value: String)]
        /// Table fields and `shared` numbers that were not finite, each once, at the first check
        /// (every 60 frames) that saw it.
        var nonFinite: [NonFinite]
        var commandCount: Int
        var createdLayers: Int
        /// `shared`'s numeric members after the last frame.
        var sharedNumbers: [String: Double]

        var meanFrameMilliseconds: Double {
            frameMilliseconds.isEmpty ? 0 : frameMilliseconds.reduce(0, +) / Double(frameMilliseconds.count)
        }

        func percentile(_ fraction: Double, cpu: Bool = false) -> Double {
            let times = cpu ? frameCPUMilliseconds : frameMilliseconds
            guard !times.isEmpty else { return 0 }
            let sorted = times.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
    }

    let wallpaper: SceneScriptReplayWallpaper
    let options: Options

    init(wallpaper: SceneScriptReplayWallpaper, options: Options = Options()) {
        self.wallpaper = wallpaper
        self.options = options
    }

    // MARK: - Run

    /// Runs the replay on a `SceneScriptThread` of its own, as the renderer will (plan §4.5): the
    /// runtime is created, loaded, stepped and torn down on that queue. Frames are stepped
    /// synchronously, one after the other, so the replay is deterministic.
    func run(prelude: SceneScriptPrelude) throws -> Result {
        let thread = SceneScriptThread(label: "replay \(wallpaper.id)")
        return try thread.sync { try replay(prelude: prelude) }
    }

    private func replay(prelude: SceneScriptPrelude) throws -> Result {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appending(path: "owe-replay-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do {
                if FileManager.default.fileExists(atPath: storageDirectory.path) {
                    try FileManager.default.removeItem(at: storageDirectory)
                }
            } catch {
                OWELog.error(.script, "Removing \(storageDirectory.path) failed: \(error)")
            }
        }
        var clock = options.startDate
        var spectrum = AudioSpectrumSnapshot.silent
        let scriptHost = SceneScriptReplayScriptHost(wallpaperID: wallpaper.id, prelude: prelude)
        let objectHost = try SceneScriptReplayObjectHost(wallpaper: wallpaper)
        let cursor = SceneScriptCursorExtension()
        let media = SceneScriptReplayMediaSource()
        let engine = SceneScriptEngineExtension(storage: SceneScriptStorage(directory: storageDirectory),
                                                environment: environment, now: { clock },
                                                consoleSink: { _, _ in })
        let audio = SceneScriptAudioBuffersExtension(spectrum: { spectrum })
        let model = SceneScriptObjectModel(host: objectHost)
        let binding = SceneScriptBindingExtension()
        let support = SceneScriptReplaySupport()
        let runtime = try SceneScriptRuntime(host: scriptHost, compiler: SceneScriptModuleTransformer(),
                                             extensions: [engine, audio, SceneScriptMediaExtension(source: media), model,
                                                          binding, cursor, support],
                                             configuration: options.configuration)
        support.setClock(clock)

        var slotsByObjectIndex: [Int: Int] = [:]
        for (index, object) in wallpaper.objects.enumerated() {
            if let slot = model.slot(forObjectID: object.id) {
                slotsByObjectIndex[index] = slot
                objectHost.objectIDsBySlot[slot] = object.id
            }
        }
        // Property binding (WP8) as a wallpaper sets it up: types, initial values and resolved
        // `scriptproperties` from SceneScriptSiteBuilder, matched to this walk's sites by object and path.
        var built = try Self.builtSites(wallpaper)
        var records: [SiteRecord] = []
        for (index, site) in wallpaper.sites.enumerated() {
            let slot = site.objectIndex.flatMap { slotsByObjectIndex[$0] }
            let object = site.objectIndex.map { wallpaper.objects[$0] }
            let id = "\(wallpaper.id)/\(object.map { "\($0.name)#\($0.id)" } ?? "scene")/\(site.field)#\(index)"
            let type = SceneScriptReplayFieldType(field: site.field, value: site.value)
            let objectBinding = SceneScriptObjectBinding(fieldPath: site.field, slot: slot)
            if let objectBinding { support.bind(scriptID: id, type: type, binding: objectBinding) }
            let key = "\(site.objectIndex ?? -1)|\(site.field)"
            guard var bound = built[key]?.first else {
                throw SceneScriptReplayWallpaper.LoadError(description: "\(wallpaper.id): the builder has no site \(key)")
            }
            built[key]?.removeFirst()
            bound.instance.id = id
            bound.instance.objectSlot = slot
            bound.instance.binding = objectBinding
            binding.add([bound], to: runtime)
            records.append(SiteRecord(id: id, site: site, type: type, slot: slot))
        }

        let loadStart = DispatchTime.now().uptimeNanoseconds
        runtime.load(userProperties: wallpaper.userProperties)
        let loadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000
        var errorFrames = Array(repeating: -1, count: scriptHost.errors.count)

        var frameMilliseconds: [Double] = []
        var frameCPUMilliseconds: [Double] = []
        var strings: [(slot: Int, field: SceneScriptStringField, value: String)] = []
        var nonFinite: [NonFinite] = []
        var commandCount = 0
        let slotsWithScripts = Array(Set(records.compactMap { record in
            record.site.objectIndex.flatMap { slotsByObjectIndex[$0] }
        })).sorted()
        func isHitTestable(_ slot: Int) -> Bool {
            objectHost.objectIDsBySlot[slot].flatMap { objectHost.kinds[$0] }.map { $0 == .image || $0 == .text } == true
        }
        // Only Solid image and text layers are hit (§1.9 P7); the cursor visits each one with scripts.
        let clickTargets = slotsWithScripts.filter { slot in
            isHitTestable(slot) && model.store.map { $0.table[slot, .solid].first ?? 0 } ?? 0 != 0
        }
        let hitTestable = slotsByObjectIndex.sorted { $0.key < $1.key }.map(\.value).filter(isHitTestable)

        for frame in 0..<options.frames {
            clock = options.startDate.addingTimeInterval(Double(frame + 1) * options.deltaTime)
            support.setClock(clock)
            spectrum = options.toneFrames.contains(frame) ? Self.tone(frame: frame) : .silent
            postMedia(frame: frame, to: media)
            postUserProperties(frame: frame, to: runtime)
            if let store = model.store {
                Self.standInForRenderer(store.table, slots: Array(slotsByObjectIndex.values), hitTestable: Set(hitTestable))
                let pointer = cursorPlan(frame: frame, targets: clickTargets, table: store.table)
                engine.input = SceneScriptInput(cursorScreenPosition: screenPoint(pointer.position),
                                                cursorLeftDown: pointer.down)
                cursor.publish(SceneScriptCursorFrame(
                    cursorWorldPosition: SIMD3(pointer.position.x, pointer.position.y, 0), leftButtonDown: pointer.down,
                    layers: SceneScriptCursorLayer.layers(in: store.table,
                                                          drawOrder: hitTestable.map { SceneScriptCursorLayer.TableEntry(slot: $0) },
                                                          parentOf: { _ in nil })))
            }

            let start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            runtime.frame(deltaTime: options.deltaTime)
            frameCPUMilliseconds.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
            frameMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            errorFrames += Array(repeating: frame, count: scriptHost.errors.count - errorFrames.count)

            let samples = support.sample()
            for index in records.indices {
                records[index].samples.append(index < samples.count ? samples[index] : NSNull())
            }
            for command in objectHost.takeCommands() {
                commandCount += 1
                if case .setString(let slot, let field, let value) = command { strings.append((slot, field, value)) }
            }
            if frame % 60 == 59 || frame == options.frames - 1 {
                var found = Self.nonFiniteValues(model: model, slots: Array(slotsByObjectIndex.values), frame: frame)
                for (key, value) in support.sharedNumbers() where !value.isFinite {
                    found.append(NonFinite(slot: nil, field: "shared.\(key)", frame: frame, value: "\(value)"))
                }
                for entry in found where !nonFinite.contains(where: { $0.slot == entry.slot && $0.field == entry.field }) {
                    nonFinite.append(entry)
                }
            }
            if runtime.state == .halted { break }
        }
        let halted = runtime.state == .halted
        let sharedNumbers = Dictionary(support.sharedNumbers(), uniquingKeysWith: { _, last in last })
        runtime.tearDown()
        return Result(wallpaperID: wallpaper.id, sites: records, errors: scriptHost.errors,
                      errorFrames: errorFrames, halted: halted,
                      loadMilliseconds: loadMilliseconds, frameMilliseconds: frameMilliseconds,
                      frameCPUMilliseconds: frameCPUMilliseconds, strings: strings,
                      nonFinite: nonFinite, commandCount: commandCount,
                      createdLayers: objectHost.created, sharedNumbers: sharedNumbers)
    }

    /// The wallpaper's sites as SceneScriptSiteBuilder finds them, by "<object index>|<field path>".
    static func builtSites(_ wallpaper: SceneScriptReplayWallpaper) throws -> [String: [SceneScriptSite]] {
        guard let data = wallpaper.file(wallpaper.documentName) else {
            throw SceneScriptReplayWallpaper.LoadError(description: "\(wallpaper.id): no \(wallpaper.documentName)")
        }
        let project = try SceneScriptSiteBuilder.document(from: JSONSerialization.data(withJSONObject: wallpaper.project))
        let builder = SceneScriptSiteBuilder(wallpaperID: wallpaper.id,
                                             userProperties: SceneScriptUserProperties(project: project))
        return Dictionary(grouping: builder.sites(in: try SceneScriptSiteBuilder.document(from: data))) {
            "\($0.objectIndex ?? -1)|\($0.property.path)"
        }
    }

    // MARK: - Inputs

    /// The project's own size when it declares one, else WE's default, placed stretched.
    private var environment: SceneScriptEngineEnvironment {
        var environment = SceneScriptEngineEnvironment.standard
        environment.placement = .stretch
        if let general = wallpaper.document["general"] as? [String: Any],
           let projection = general["orthogonalprojection"] as? [String: Any],
           let width = (projection["width"] as? NSNumber)?.doubleValue,
           let height = (projection["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 {
            environment.canvasSize = SIMD2(width, height)
        }
        return environment
    }

    /// Music-like spectra: a tone that moves across the bands (the right channel lags the left) plus
    /// a kick every half second that jumps the low bands and decays over a few frames, so both
    /// level-following and beat-detecting scripts react.
    static func tone(frame: Int) -> AudioSpectrumSnapshot {
        let time = Double(frame) / 60
        let sinceKick = frame % 30
        let kick = sinceKick < 6 ? 1 - Double(sinceKick) / 6 : 0
        func bands(_ count: Int, phase: Double) -> [Float] {
            (0..<count).map { band in
                let position = Double(band) / Double(count)
                let wave: Double = sin(time * 5 + position * 9 + phase)
                let low: Double = max(0, 1 - position * 4)
                let level: Double = 0.35 + 0.3 * wave + 0.6 * kick * low
                return Float(min(1, level))
            }
        }
        var snapshot = AudioSpectrumSnapshot(left16: bands(16, phase: 0), right16: bands(16, phase: 1.3),
                                             left32: bands(32, phase: 0), right32: bands(32, phase: 1.3),
                                             left64: bands(64, phase: 0), right64: bands(64, phase: 1.3))
        snapshot.average16 = zip(snapshot.left16, snapshot.right16).map { ($0 + $1) / 2 }
        snapshot.average32 = zip(snapshot.left32, snapshot.right32).map { ($0 + $1) / 2 }
        snapshot.average64 = zip(snapshot.left64, snapshot.right64).map { ($0 + $1) / 2 }
        return snapshot
    }

    /// The cursor this frame, in scene units: on its path, or at the click target's origin.
    private func cursorPlan(frame: Int, targets: [Int], table: SceneScriptObjectTable) -> (position: SIMD2<Float>, down: Bool) {
        for start in options.clickFrames {
            let step = frame - start
            guard step >= 0, step < targets.count * 4 else { continue }
            let origin = table[targets[step / 4], .origin]
            switch step % 4 {
            case 0: return (SIMD2(origin[0], origin[1]), false)
            case 1: return (SIMD2(origin[0], origin[1]), true)
            case 2: return (SIMD2(origin[0], origin[1]), false)
            default: return (SIMD2(-100_000, -100_000), false)
            }
        }
        let time = Double(frame) / 60
        let canvas = environment.canvasSize
        let x: Double = canvas.x * (0.5 + 0.4 * sin(time * 1.3))
        let y: Double = canvas.y * (0.5 + 0.4 * sin(time * 1.7))
        return (SIMD2(Float(x), Float(y)), false)
    }

    /// A scene point as screen pixels from the top-left (the environment places the scene stretched).
    private func screenPoint(_ point: SIMD2<Float>) -> SIMD2<Double> {
        let screen = environment.screenResolution, canvas = environment.canvasSize
        return SIMD2(Double(point.x) * screen.x / canvas.x, screen.y - Double(point.y) * screen.y / canvas.y)
    }

    /// What the renderer keeps current in the table before each frame (WP11), as a stand-in:
    /// each object's world transform is its own origin and scale, and an image or text without a
    /// size gets 64 × 64.
    private static func standInForRenderer(_ table: SceneScriptObjectTable, slots: [Int], hitTestable: Set<Int>) {
        for slot in slots {
            let origin = table[slot, .origin], scale = table[slot, .scale]
            let base = SceneScriptObjectTable.index(slot: slot, field: SceneScriptObjectTable.Layout.worldMatrix)
            let matrix: [Float] = [scale[0], 0, 0, 0, 0, scale[1], 0, 0, 0, 0, 1, 0, origin[0], origin[1], 0, 1]
            for (index, value) in matrix.enumerated() { table.values[base + index] = value }
            if hitTestable.contains(slot), table[slot, .size] == [0, 0] { table[slot, .size] = [64, 64] }
        }
    }

    /// Every `MediaPropertiesEvent` member filled, so a script showing any of them (an album
    /// artist, a subtitle) changes with the track.
    private static let firstTrack = MediaSessionState.Properties(
        title: "Replay Song", artist: "Replay Artist", subTitle: "Replay Subtitle", albumTitle: "Replay Album",
        albumArtist: "Replay Album Artist", genres: "Pop", contentType: "audio")

    private func postMedia(frame: Int, to source: SceneScriptReplayMediaSource) {
        var state = MediaSessionState()
        state.enabled = true
        let colors = ArtworkPalette.Colors(primary: SIMD3(0.8, 0.2, 0.1), secondary: SIMD3(0.1, 0.3, 0.7),
                                           tertiary: SIMD3(0.9, 0.9, 0.2), text: SIMD3(1, 1, 1),
                                           highContrast: SIMD3(0, 0, 0))
        switch frame {
        case 30..<240:
            state.playback = .playing
            state.properties = Self.firstTrack
            state.thumbnail = .init(artwork: 1, colors: colors)
            state.timeline = .init(position: Double((frame - 30) / 60), duration: 200)
        case 240..<360:
            state.playback = .paused
            state.properties = Self.firstTrack
            state.thumbnail = .init(artwork: 1, colors: colors)
            state.timeline = .init(position: 3, duration: 200)
        case 360..<480:
            state.playback = .stopped
            state.properties = .init(title: "Second Song", artist: "Second Artist")
            state.thumbnail = .init()
        case 480...:
            state.playback = .playing
            state.properties = .init(title: "Third Song", artist: "Third Artist", albumTitle: "Third Album",
                                     albumArtist: "Third Album Artist")
            state.thumbnail = .init(artwork: 2, colors: ArtworkPalette.Colors(
                primary: SIMD3(0.2, 0.7, 0.3), secondary: SIMD3(0.5, 0.5, 0.5), tertiary: SIMD3(0.1, 0.1, 0.1),
                text: SIMD3(0, 0, 0), highContrast: SIMD3(1, 1, 1)))
            state.timeline = .init(position: Double((frame - 480) / 60), duration: 180)
        default:
            return
        }
        source.send(state)
    }

    private func postUserProperties(frame: Int, to runtime: SceneScriptRuntime) {
        guard frame == 420 || frame == 540 else { return }
        let changed = frame == 420 ? Self.changedProperties(wallpaper.userProperties) : wallpaper.userProperties
        if !changed.isEmpty { runtime.userPropertiesDidChange(changed) }
    }

    /// Every flag flipped, every slider at its maximum, every combo on another option.
    static func changedProperties(_ properties: [String: Any]) -> [String: Any] {
        var changed: [String: Any] = [:]
        for (key, entry) in properties {
            guard var property = entry as? [String: Any] else { continue }
            switch property["type"] as? String {
            case "bool":
                property["value"] = !((property["value"] as? NSNumber)?.boolValue ?? false)
            case "slider":
                guard let maximum = property["max"] else { continue }
                property["value"] = maximum
            case "combo":
                let options = (property["options"] as? [[String: Any]])?.compactMap { $0["value"] } ?? []
                let current = property["value"].map { "\($0)" }
                guard let other = options.first(where: { "\($0)" != current }) else { continue }
                property["value"] = other
            default:
                continue
            }
            changed[key] = property
        }
        return changed
    }

    // MARK: - Checks

    private static func nonFiniteValues(model: SceneScriptObjectModel, slots: [Int], frame: Int) -> [NonFinite] {
        guard let store = model.store else { return [] }
        var found: [NonFinite] = []
        for slot in slots.sorted() {
            for field in SceneScriptObjectField.allCases {
                let values = store.table[slot, field]
                if values.contains(where: { !$0.isFinite }) {
                    found.append(NonFinite(slot: slot, field: field.rawValue, frame: frame, value: "\(values)"))
                }
            }
        }
        return found
    }
}
