import JavaScriptCore
import MetalKit
import WebKit
import XCTest
@testable import OpenWallpaperEngine

/// Every user property of every scene and web wallpaper in the library (`OWE_LIBRARY`), changed to
/// a clearly different valid value (a flipped bool, a slider at its far end, another combo
/// option, a contrasting colour, other text) and checked to change something:
///
/// - **Live**: two copies of the wallpaper drawn headlessly in lockstep (the same clock, each its
///   own property store); one takes the change through the app's path (the running store, the
///   scripts' `applyUserProperties`, then the rebuild or reload `SceneChangeImpact` asks for, which
///   the other copy repeats unchanged), and the two frames are compared.
/// - **Fresh**: the wallpaper loaded with the new value stored, against a load with its
///   defaults, both drawn the same frames.
///
/// A property works when either frame differs beyond the wallpaper's own noise (two identical
/// copies compared), or its bound target does: the drawn layers, their opacity and colour, the
/// effects' visibility and live constants, and, for a scene with scripts,
/// `engine.userProperties` (what `applyUserProperties` is given). One that changes nothing is
/// broken, filed under the kind of binding that carries it (`UserPropertySweepBindings.Kind`),
/// except where nothing visible is expected now: a script took the value, an audio setting, a
/// binding on something not drawn, a property nothing reads, or a web page that took the value.
/// Those are listed as unclear, to be inspected.
///
/// Web wallpapers are pages on their own clocks, so their frames are compared against two
/// unchanged copies' noise, and the page's listener is checked to take the value without throwing.
///
/// Runs only with `OWE_PROPERTY_SWEEP=1` and the library; writes a Markdown report to
/// `OWE_PROPERTY_SWEEP_REPORT` (default: the temporary directory). `OWE_PROPERTY_SWEEP_ITEMS`
/// (comma-separated folder names) limits the wallpapers; `OWE_PROPERTY_SWEEP_RESUME=1` keeps the
/// rows already in the report's `.tsv` and sweeps only the rest.
final class UserPropertySweepTests: XCTestCase {
    private static let size = SIMD2(256, 144)
    private static let warmUpFrames = 20
    private static let changeFrames = 20
    private static let step = 1.0 / 30
    /// A pixel differs when a channel moves by more than this (of 255).
    private static let pixelTolerance = 12
    /// The fraction of differing pixels that counts as a change, over twice the noise.
    private static let changedFraction = 0.001

    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-property-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    // MARK: - Rows

    enum Status: String {
        case working, broken, unclear
    }

    struct Row {
        var wallpaper: String
        var title: String
        var type: String
        var property: String
        var propertyType: String
        var from: String
        var to: String
        var status: Status
        var kind: String
        var note: String
        var sites: [String]

        var tsv: String {
            [wallpaper, title, type, property, propertyType, from, to, status.rawValue, kind, note, sites.joined(separator: " | ")]
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }

        init(wallpaper: String, title: String, type: String, property: String, propertyType: String, from: String,
             to: String, status: Status, kind: String, note: String, sites: [String]) {
            (self.wallpaper, self.title, self.type, self.property, self.propertyType) = (wallpaper, title, type, property, propertyType)
            (self.from, self.to, self.status, self.kind, self.note, self.sites) = (from, to, status, kind, note, sites)
        }

        init?(tsv line: Substring) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 11, let status = Status(rawValue: columns[7]) else { return nil }
            self.init(wallpaper: columns[0], title: columns[1], type: columns[2], property: columns[3], propertyType: columns[4],
                      from: columns[5], to: columns[6], status: status, kind: columns[8], note: columns[9],
                      sites: columns[10].isEmpty ? [] : columns[10].components(separatedBy: " | "))
        }
    }

    // MARK: - The sweep

    func testEveryUserPropertyChangesTheWallpaper() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OWE_PROPERTY_SWEEP"] == "1", "set OWE_PROPERTY_SWEEP=1 to sweep the library's user properties")
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        _ = try Fixtures.assets()
        let reportURL = URL(fileURLWithPath: environment["OWE_PROPERTY_SWEEP_REPORT"]
                            ?? FileManager.default.temporaryDirectory.appending(path: "property-sweep.md").path)
        let tsvURL = reportURL.deletingPathExtension().appendingPathExtension("tsv")
        var rows: [Row] = []
        if environment["OWE_PROPERTY_SWEEP_RESUME"] == "1", let text = try? String(contentsOf: tsvURL, encoding: .utf8) {
            rows = text.split(separator: "\n").compactMap(Row.init(tsv:))
        } else {
            try? FileManager.default.removeItem(at: tsvURL)
            FileManager.default.createFile(atPath: tsvURL.path, contents: nil)
        }
        let done = Set(rows.map(\.wallpaper))
        let only = environment["OWE_PROPERTY_SWEEP_ITEMS"].map { Set($0.split(separator: ",").map(String.init)) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted()
        for name in names where only?.contains(name) ?? true {
            guard !done.contains(name) else { continue }
            let directory = library.appending(path: name, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let declared = ((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
            let settings = declared.filter { Self.isSetting($0.value) }
            guard !settings.isEmpty else { continue }
            let type = project.type.lowercased()
            var result: [Row]
            let start = Date()
            switch type {
            case "scene":
                result = try autoreleasepool { try sweepScene(name: name, directory: directory, project: project, declared: settings) }
            case "web":
                result = try autoreleasepool { try sweepWeb(name: name, directory: directory, project: project, declared: settings) }
            default:
                continue
            }
            print(String(format: "PropertySweep %@ (%@, %d properties): %.1f s", name, type, result.count, Date().timeIntervalSince(start)))
            if let handle = try? FileHandle(forWritingTo: tsvURL) {
                handle.seekToEndOfFile()
                handle.write(Data(result.map { $0.tsv + "\n" }.joined().utf8))
                try? handle.close()
            }
            rows += result
            try Self.report(rows).write(to: reportURL, atomically: true, encoding: .utf8)
        }
        try Self.report(rows).write(to: reportURL, atomically: true, encoding: .utf8)
        print("PropertySweep report: \(reportURL.path)")
    }

    /// A property the user sets: not a notice row or a group heading.
    private static func isSetting(_ property: [String: Any]) -> Bool {
        let type = (property["type"] as? String ?? "").lowercased()
        return !["", "text", "group"].contains(type)
    }

    private static func defaultValue(_ property: [String: Any]) -> String {
        if let value = property["value"] { return sceneUserPropertyString(value) }
        if property["type"] as? String == "combo", let first = (property["options"] as? [[String: Any]])?.first?["value"] {
            return sceneUserPropertyString(first)
        }
        return ""
    }

    // MARK: - Scenes

    private func services() -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent })
    }

    private func load(_ directory: URL, scope: WallpaperPropertyScope, id: String) throws -> SceneFrameHarness {
        let harness = try SceneFrameHarness(directory: directory, scope: scope, size: Self.size, services: services(),
                                            screenID: "sweep-\(id)")
        return harness
    }

    /// Draws `harnesses` in lockstep with the clock held until no pipeline or script layer is
    /// still being built, then `frames` frames `step` apart.
    private func draw(_ harnesses: [SceneFrameHarness], frames: Int) {
        // Held until five frames in a row found nothing building: a layer can start compiling a
        // frame or two after the content lands.
        let deadline = Date().addingTimeInterval(30)
        var quiet = 0
        while quiet < 5, Date() < deadline {
            for harness in harnesses { harness.draw(frames: 1, step: 0) }
            let building = harnesses.contains { $0.renderer.pipelinesCompiling || $0.renderer.pendingScriptLayers > 0 }
            quiet = building ? 0 : quiet + 1
            if building { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        for _ in 0..<frames {
            for harness in harnesses { harness.draw(frames: 1, step: Self.step) }
        }
    }

    private struct Frame {
        var pixels: [UInt8]
        var target: String
        var scriptValue: String?
        /// Per particle system, what its particles are (`ParticleStats`).
        var particles: [ParticleStats] = []
    }

    /// A particle system's particles in a few numbers: an `instanceoverride` change only reaches
    /// the particles emitted after it, which take seconds to show in the pixels, but is in their
    /// GPU state at once.
    struct ParticleStats {
        var count: Float
        var size: Float
        var alpha: Float
        var lifetime: Float
        var color: SIMD3<Float>

        /// The particles of each system, only those emitted within the last `window` seconds when
        /// given (the ones a change since then reached).
        static func of(_ renderer: SceneMetalRenderer, newerThan window: Float?) -> [ParticleStats] {
            renderer.particleSamples().map { system in
                let particles = window.map { window in system.particles.filter { $0.age <= window } } ?? system.particles
                let n = Float(max(particles.count, 1))
                var stats = ParticleStats(count: Float(particles.count), size: 0, alpha: 0, lifetime: 0, color: .zero)
                for particle in particles {
                    stats.size += particle.size / n
                    stats.alpha += particle.alpha / n
                    stats.lifetime += particle.lifetime / n
                    stats.color += SIMD3(particle.color.x, particle.color.y, particle.color.z) / n
                }
                return stats
            }
        }

        /// The largest relative difference of any number of any system (1 when the systems differ).
        static func difference(_ a: [ParticleStats], _ b: [ParticleStats]) -> Double {
            guard a.count == b.count else { return 1 }
            func relative(_ x: Float, _ y: Float) -> Float { abs(x - y) / max(max(abs(x), abs(y)), 1e-3) }
            var result: Float = 0
            for (x, y) in zip(a, b) {
                result = max(result, relative(x.count, y.count), relative(x.size, y.size), relative(x.alpha, y.alpha),
                             relative(x.lifetime, y.lifetime), relative(x.color.x, y.color.x),
                             relative(x.color.y, y.color.y), relative(x.color.z, y.color.z))
            }
            return Double(result)
        }

        /// Changed: beyond 5% and twice what two unchanged copies differ by.
        static func changed(_ difference: Double, noise: Double) -> Bool { difference > 0.05 + 2 * noise }
    }

    /// How long the live copies are drawn after a change, in scene seconds.
    private static var changeWindow: Float { Float(Double(changeFrames) * step) }

    private func capture(_ harness: SceneFrameHarness, probe: SceneDrawProbe, property: String?,
                         particlesNewerThan window: Float? = nil) -> Frame {
        let size = harness.size
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        harness.view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                       from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        return Frame(pixels: bytes, target: target(harness, probe: probe), scriptValue: property.flatMap { scriptValue($0, harness) },
                     particles: ParticleStats.of(harness.renderer, newerThan: window))
    }

    /// What the property can be bound to, as this frame has it: every object's visibility, the
    /// particle systems, every drawn layer with its opacity and colour, every effect's visibility
    /// and live constants.
    private func target(_ harness: SceneFrameHarness, probe: SceneDrawProbe) -> String {
        let renderer = harness.renderer
        let context = LiveSceneValueContext(animations: renderer.animations, wallpaper: harness.model.propertyStoreKey)
        var lines: [String] = []
        if let content = harness.model.metalContent() {
            lines.append("visible " + content.objectIDs.map { "\($0)=\(renderer.scripts.isVisible(String($0)) ? 1 : 0)" }
                .joined(separator: " "))
            lines.append("particles " + content.particleSystems.map { "\($0.emissionRate)/\($0.maximumParticleCount)" }
                .joined(separator: " "))
            lines.append("clear \(content.clearColor)")
        }
        for (id, layer) in probe.layers.sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "layer %@ a%.3f c%.3f,%.3f,%.3f,%.3f", id, layer.opacity,
                                layer.color.x, layer.color.y, layer.color.z, layer.color.w))
        }
        for id in probe.layers.keys.sorted() {
            for plan in renderer.effectPlans(ofLayer: id) {
                var line = "effect \(id)/\(plan.effectIndex) visible \(plan.visible)"
                for pass in plan.passes {
                    for constant in pass.constants.dynamic {
                        let value = SceneValueResolver.resolve(constant.source, in: context).components
                        line += " \(constant.uniform)=" + value.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    }
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `engine.userProperties[name]` in the scripts, which is what `applyUserProperties` hands them.
    private func scriptValue(_ name: String, _ harness: SceneFrameHarness) -> String? {
        guard harness.renderer.scripts.isRunning,
              let quoted = try? String(data: JSONSerialization.data(withJSONObject: [name]), encoding: .utf8) else { return nil }
        let expression = "(function(){try{return JSON.stringify(engine.userProperties[\(quoted)[0]]);}catch(e){return 'error '+e;}})()"
        return try? harness.evaluate(expression)
    }

    /// The fraction of pixels that differ.
    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for pixel in stride(from: 0, to: a.count, by: 4) {
                    for channel in 0..<3 where abs(Int(a[pixel + channel]) - Int(b[pixel + channel])) > pixelTolerance {
                        changed += 1
                        break
                    }
                }
            }
        }
        return Double(changed) / Double(a.count / 4)
    }

    /// What one path's frames say.
    private enum Outcome {
        case changed, unchanged
        /// Two unchanged copies already differ this much: the frames can't tell.
        case noisy
    }

    /// Above this much noise a path's frames prove nothing either way.
    private static let noisy = 0.25

    private static func outcome(_ difference: Double, noise: Double, target: Bool = false) -> Outcome {
        if target || difference > changedFraction + 2 * noise, noise <= noisy || target { return .changed }
        return noise > noisy ? .noisy : .unchanged
    }

    /// The row's status from its two paths: nil when neither changed (the caller decides).
    private static func verdict(live: Outcome, fresh: Outcome) -> (Status, String)? {
        switch (live, fresh) {
        case (.changed, .changed): return (.working, "")
        case (.changed, .noisy), (.noisy, .changed): return (.working, "one path too noisy to tell; ")
        case (.changed, .unchanged): return (.broken, "fresh load changes nothing; ")
        case (.unchanged, .changed): return (.broken, "live change changes nothing; ")
        case (.noisy, .noisy): return (.unclear, "both paths too noisy to tell; ")
        default: return nil
        }
    }

    /// Sets `values` on `harness`'s store and applies them as `SceneWallpaperInstance` does when the
    /// user edits a property (`SceneFrameHarness.changeProperties`: scripts, then the bindings'
    /// owners, then objects rebuilt alone); returns the whole-content impact left to run.
    private func publish(_ values: [String: String], to harness: SceneFrameHarness) throws -> SceneChangeImpact {
        try harness.changeProperties(values)
    }

    /// The property's editor `condition` (WE shows it only while that holds, e.g.
    /// `visualizer.value == true`) is false with every property at its default: what it drives is
    /// off by default, so nothing visible is expected from changing it alone. Nil when it has no
    /// condition or the condition holds.
    static func offByDefault(_ definition: [String: Any], declared: [String: [String: Any]]) -> String? {
        guard let condition = definition["condition"] as? String,
              !condition.trimmingCharacters(in: .whitespaces).isEmpty,
              let context = JSContext() else { return nil }
        var values: [String: Any] = [:]
        for (name, property) in declared { values[name] = ["value": property["value"] ?? NSNull()] }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else { return nil }
        context.exceptionHandler = { _, _ in }
        let script = "(function(p){with(p){return !!(\(condition));}})(\(json))"
        guard let result = context.evaluateScript(script), result.isBoolean, !result.toBool() else { return nil }
        return condition
    }

    /// The rebuild or reload `impact` asks for, as `SceneWallpaperInstance` runs it.
    private func rebuild(_ harness: SceneFrameHarness, _ impact: SceneChangeImpact) {
        guard impact > .none else { return }
        if impact == .reloadScene { harness.model.reloadCurrentScene() } else { harness.model.invalidateContent() }
        harness.renderer.setContent(harness.model.metalContent())
        let deadline = Date().addingTimeInterval(60)
        while !harness.renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func removeScopedSettings(_ directory: URL, scopes: [WallpaperPropertyScope]) {
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        for scope in scopes {
            for family in WallpaperSettingsIdentity.Family.allCases {
                UserDefaults.app.removeObject(forKey: identity.key(family, scope: scope))
            }
        }
        Fixtures.removeStoredSettings(for: directory)
    }

    /// Stores `values` as the user's for the shared scope, as a saved edit does.
    private func store(_ values: [String: String], _ directory: URL) {
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        UserDefaults.app.set(values, forKey: identity.key(.userProperties, scope: .shared))
        UserDefaults.app.set(true, forKey: identity.key(.explicitUserProperties, scope: .shared))
    }

    private func freshFrame(_ directory: URL, values: [String: String], id: String, property: String?) throws -> Frame {
        Fixtures.removeStoredSettings(for: directory)
        if !values.isEmpty { store(values, directory) }
        let harness = try load(directory, scope: .shared, id: id)
        defer { harness.close() }
        let probe = SceneDrawProbe()
        harness.renderer.drawProbe = probe
        draw([harness], frames: Self.warmUpFrames + Self.changeFrames)
        return capture(harness, probe: probe, property: property)
    }

    private func sweepScene(name: String, directory: URL, project: WEProject,
                            declared: [String: [String: Any]]) throws -> [Row] {
        let scopes: [WallpaperPropertyScope] = [.display("sweep-a"), .display("sweep-b")]
        removeScopedSettings(directory, scopes: scopes)
        defer { removeScopedSettings(directory, scopes: scopes) }
        let sites = UserPropertySweepBindings.sites(directory: directory, sceneFile: project.file, names: Set(declared.keys))

        // Fresh: the defaults twice (the noise; after a first load that fills the caches), then
        // each property on its own.
        _ = try freshFrame(directory, values: [:], id: "d0", property: nil)
        let base = try freshFrame(directory, values: [:], id: "d1", property: nil)
        let again = try freshFrame(directory, values: [:], id: "d2", property: nil)
        let freshNoise = Self.difference(base.pixels, again.pixels)
        let freshTargetStable = base.target == again.target
        let freshParticleNoise = ParticleStats.difference(base.particles, again.particles)

        // Live: a reference and a copy that takes the changes.
        var pair = try [load(directory, scope: scopes[0], id: "a"), load(directory, scope: scopes[1], id: "b")]
        defer { pair.forEach { $0.close() } }
        var probes = [SceneDrawProbe(), SceneDrawProbe()]
        for (harness, probe) in zip(pair, probes) { harness.renderer.drawProbe = probe }
        draw(pair, frames: Self.warmUpFrames)
        let initialNoise = Self.difference(capture(pair[0], probe: probes[0], property: nil).pixels,
                                           capture(pair[1], probe: probes[1], property: nil).pixels)

        var rows: [Row] = []
        for (property, definition) in declared.sorted(by: { $0.key < $1.key }) {
            let type = (definition["type"] as? String ?? "").lowercased()
            let from = Self.defaultValue(definition)
            let propertySites = sites[property] ?? []
            let siteList = propertySites.map { "\($0.kind.rawValue): \($0.path)" }
            func row(_ status: Status, _ kind: String, _ note: String, to: String = "") -> Row {
                Row(wallpaper: name, title: project.title, type: "scene", property: property, propertyType: type, from: from,
                    to: to, status: status, kind: kind, note: note, sites: siteList)
            }
            guard let to = UserPropertySweepValues.changed(type: type, property: definition, current: from) else {
                rows.append(row(.unclear, "not changeable", "no other valid value to set (\(type))"))
                continue
            }

            // Live. The copies drift apart only by randomness; resync them when they have.
            let window = Self.changeWindow
            var before = [capture(pair[0], probe: probes[0], property: property, particlesNewerThan: window),
                          capture(pair[1], probe: probes[1], property: property, particlesNewerThan: window)]
            var noise = Self.difference(before[0].pixels, before[1].pixels)
            if noise > max(0.02, 4 * initialNoise) {
                pair.forEach { $0.close() }
                pair = try [load(directory, scope: scopes[0], id: "a"), load(directory, scope: scopes[1], id: "b")]
                probes = [SceneDrawProbe(), SceneDrawProbe()]
                for (harness, probe) in zip(pair, probes) { harness.renderer.drawProbe = probe }
                draw(pair, frames: Self.warmUpFrames)
                before = [capture(pair[0], probe: probes[0], property: property, particlesNewerThan: window),
                          capture(pair[1], probe: probes[1], property: property, particlesNewerThan: window)]
                noise = Self.difference(before[0].pixels, before[1].pixels)
            }
            let impact = try publish([property: to], to: pair[1])
            rebuild(pair[0], impact)
            rebuild(pair[1], impact)
            draw(pair, frames: Self.changeFrames)
            let reference = capture(pair[0], probe: probes[0], property: property, particlesNewerThan: window)
            let live = capture(pair[1], probe: probes[1], property: property, particlesNewerThan: window)
            let liveDifference = Self.difference(reference.pixels, live.pixels)
            let particleBound = propertySites.contains { $0.kind == .particleOverride }
            // Particles: the ones emitted since the change, compared in their GPU state.
            let liveParticles = ParticleStats.difference(reference.particles, live.particles)
            let liveParticleNoise = ParticleStats.difference(before[0].particles, before[1].particles)
            let liveTarget = reference.target != live.target
                || particleBound && ParticleStats.changed(liveParticles, noise: liveParticleNoise)
            let scriptTook = live.scriptValue != nil && live.scriptValue != before[1].scriptValue
            // Back to the default for the next property.
            let revert = try publish([property: from], to: pair[1])
            rebuild(pair[0], revert)
            rebuild(pair[1], revert)
            draw(pair, frames: Self.changeFrames)

            // Fresh.
            let fresh = try freshFrame(directory, values: [property: to], id: "f", property: property)
            let freshDifference = Self.difference(base.pixels, fresh.pixels)
            let freshParticles = ParticleStats.difference(base.particles, fresh.particles)
            let freshTarget = freshTargetStable && base.target != fresh.target
                || particleBound && ParticleStats.changed(freshParticles, noise: freshParticleNoise)
            var note = String(format: "live Δ%.4f (noise %.4f)%@, fresh Δ%.4f (noise %.4f)%@, impact %@",
                              liveDifference, noise, liveTarget ? " target" : "",
                              freshDifference, freshNoise, freshTarget ? " target" : "", "\(impact)")
            if particleBound {
                note += String(format: ", particles live Δ%.3f (noise %.3f), fresh Δ%.3f (noise %.3f)",
                               liveParticles, liveParticleNoise, freshParticles, freshParticleNoise)
            }
            if live.scriptValue != nil { note += scriptTook ? ", script got it" : ", script value unchanged" }

            let kinds = Set(propertySites.map(\.kind))
            let primary = propertySites.map(\.kind).filter { $0 != .scriptOnly }.min() ?? (kinds.contains(.scriptOnly) ? .scriptOnly : .unknown)
            let verdict = Self.verdict(live: Self.outcome(liveDifference, noise: noise, target: liveTarget),
                                       fresh: Self.outcome(freshDifference, noise: freshNoise, target: freshTarget))
            if verdict?.0 != .working, !propertySites.isEmpty,
               propertySites.allSatisfy({ $0.kind == .particleOverride && $0.path.hasSuffix("instanceoverride/rate") }) {
                // `rate` only drives the turbulence's timing: subtle by design.
                rows.append(row(.unclear, "subtle by design", "particle `rate` only drives turbulence timing; " + note, to: to))
            } else if let (status, reason) = verdict {
                rows.append(row(status, status == .unclear ? "noisy" : primary.rawValue, reason + note, to: to))
            } else if let condition = Self.offByDefault(definition, declared: declared) {
                rows.append(row(.unclear, "off by default",
                                "nothing visible expected: its condition `\(condition)` is false by default; " + note, to: to))
            } else if propertySites.isEmpty {
                rows.append(row(.unclear, "unreferenced", "nothing in the scene reads it; " + note, to: to))
            } else if kinds == [.scriptOnly] {
                rows.append(scriptTook
                            ? row(.unclear, "script-only", "the script took the value, nothing visible yet; " + note, to: to)
                            : row(.broken, "script-only", "the scripts never got the value; " + note, to: to))
            } else if kinds.isSubset(of: [.audio, .scriptOnly]) {
                rows.append(row(.unclear, "audio", "audio setting; " + note, to: to))
            } else if !propertySites.contains(where: { site in
                site.objectID.map { probes[0].layers[$0] != nil } ?? true
            }) && !kinds.contains(.effectConstant) && !kinds.contains(.particleOverride) && !kinds.contains(.layerVisible) {
                rows.append(row(.unclear, primary.rawValue, "bound only to objects not drawn; " + note, to: to))
            } else if kinds.contains(.scriptOnly), scriptTook {
                rows.append(row(.unclear, primary.rawValue, "a script also reads it and took the value; " + note, to: to))
            } else {
                rows.append(row(.broken, primary.rawValue, note, to: to))
            }
        }
        return rows
    }

    // MARK: - Web

    private final class WebPage: NSObject, WKNavigationDelegate {
        let model: WebWallpaperViewModel
        let webView: WKWebView
        let window: NSWindow
        private(set) var finished = false
        private let payload: [String: Any]

        init(wallpaper: WEWallpaper, scope: WallpaperPropertyScope, values: [String: String],
             properties: [String: WebWallpaperPropertyBridge.Property]) {
            model = WebWallpaperViewModel(wallpaper: wallpaper, propertyScope: scope)
            payload = WebWallpaperPropertyBridge.payload(properties: properties, values: values)
            let configuration = WebWallpaperView.makeConfiguration()
            configuration.userContentController.addUserScript(
                WKUserScript(source: UserPropertySweepTests.listenerRecorder, injectionTime: .atDocumentStart,
                             forMainFrameOnly: true))
            model.installBridge(on: configuration.userContentController)
            // The page runs while its offscreen window is covered, as a visible wallpaper does.
            configuration.preferences.inactiveSchedulingPolicy = .none
            configuration.setURLSchemeHandler(model.schemeHandler, forURLScheme: WebWallpaperSchemeHandler.scheme)
            let frame = CGRect(x: 0, y: 0, width: 480, height: 270)
            webView = WKWebView(frame: frame, configuration: configuration)
            window = NSWindow(contentRect: frame.offsetBy(dx: -20000, dy: -20000), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.orderBack(nil)
            super.init()
            webView.navigationDelegate = self
            model.webView = webView
            model.pageWillLoad()
            switch WebWallpaperView.pageLoad(pageFile: model.fileUrl, relativePath: wallpaper.project.file) {
            case .remoteEmbed(let html):
                model.schemeHandler.directory = nil
                webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
            case .scheme(let url):
                model.schemeHandler.directory = model.readAccessURL
                model.schemeHandler.patches = model.compatPatches ?? WebCompatPatches(actions: [])
                webView.load(URLRequest(url: url))
            case nil:
                finished = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // What the app's `didFinish` sends: every property, then the general properties.
            if let script = WebWallpaperPropertyBridge.applyUserPropertiesScript(payload) {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
            webView.evaluateJavaScript(WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: 30), completionHandler: nil)
            finished = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finished = true
        }

        func close() {
            webView.stopLoading()
            window.orderOut(nil)
            window.contentView = nil
        }

        func evaluate(_ script: String) -> String? {
            var result: String?
            var done = false
            webView.evaluateJavaScript(script) { value, _ in
                result = value.map { "\($0)" }
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return result
        }

        func snapshot() -> [UInt8] {
            var image: NSImage?
            var done = false
            webView.takeSnapshot(with: nil) { snapshot, _ in
                image = snapshot
                done = true
            }
            let deadline = Date().addingTimeInterval(10)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let width = 160, height = 90
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return bytes }
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func open(_ wallpaper: WEWallpaper, scope: WallpaperPropertyScope, values: [String: String],
                      properties: [String: WebWallpaperPropertyBridge.Property]) -> WebPage {
        WebPage(wallpaper: wallpaper, scope: scope, values: values, properties: properties)
    }

    private static func settle(_ pages: [WebPage]) {
        let deadline = Date().addingTimeInterval(20)
        while pages.contains(where: { !$0.finished }), Date() < deadline { wait(0.05) }
        wait(1.5)
    }

    /// Installed before any page script runs: whichever script registers
    /// `window.wallpaperPropertyListener` (the page's own, or a separate `js/settings.js`), and
    /// whenever it sets `applyUserProperties`, each call is recorded with the properties it was
    /// given (`window.__oweSweep.calls`) and any throw (`.errors`).
    static let listenerRecorder = """
    (function(){var W=window;var S=W.__oweSweep={calls:[],errors:[]};\
    function wrap(l){if(!l||(typeof l!=='object'&&typeof l!=='function'))return l;\
    var f=l.applyUserProperties;if(typeof f==='function'&&!f.__oweSweep){\
    var g=function(p){try{S.calls.push(Object.keys(p||{}));}catch(e){}\
    try{return f.apply(this,arguments);}catch(e){S.errors.push(String(e));throw e;}};\
    g.__oweSweep=true;try{l.applyUserProperties=g;}catch(e){}}return l;}\
    var current;try{Object.defineProperty(W,'wallpaperPropertyListener',{configurable:true,enumerable:true,\
    get:function(){return wrap(current);},set:function(v){current=v;wrap(v);}});}catch(e){}})();
    """

    /// Whether the page has a listener now ('none' / 'ok'), and clears the recorded calls and errors.
    private static let listenerProbe = """
    (function(){var S=window.__oweSweep;if(S){S.calls=[];S.errors=[];}\
    var l=window.wallpaperPropertyListener;\
    return (l&&typeof l.applyUserProperties==='function')?'ok':'none';})()
    """

    /// Whether `applyUserProperties` was called with `property` since the probe.
    private static func listenerCalled(_ property: String) -> String {
        let name = String(data: (try? JSONSerialization.data(withJSONObject: [property])) ?? Data("[\"\"]".utf8),
                          encoding: .utf8) ?? "[\"\"]"
        return "(function(){var S=window.__oweSweep;if(!S)return 'unknown';var n=\(name)[0];"
            + "return S.calls.some(function(k){return k.indexOf(n)>=0;})?'yes':'no';})()"
    }

    private func sweepWeb(name: String, directory: URL, project: WEProject,
                          declared: [String: [String: Any]]) throws -> [Row] {
        let wallpaper = WEWallpaper(using: project, where: directory)
        let properties = WebWallpaperPropertyBridge.declaredProperties(wallpaperDirectory: directory)
        let defaults = WebWallpaperPropertyBridge.currentValues(properties: properties, stored: [:])
        let scopes: [WallpaperPropertyScope] = [.display("sweep-a"), .display("sweep-b")]
        defer { removeScopedSettings(directory, scopes: scopes) }
        var pair = [open(wallpaper, scope: scopes[0], values: defaults, properties: properties),
                    open(wallpaper, scope: scopes[1], values: defaults, properties: properties)]
        defer { pair.forEach { $0.close() } }
        // Two fresh pages with the defaults: how much two loads differ on their own.
        let unchanged = [open(wallpaper, scope: .display("sweep-d"), values: defaults, properties: properties),
                         open(wallpaper, scope: .display("sweep-f"), values: defaults, properties: properties)]
        Self.settle(pair + unchanged)
        let freshNoise = Self.difference(unchanged[0].snapshot(), unchanged[1].snapshot())
        unchanged.forEach { $0.close() }

        var rows: [Row] = []
        for (property, definition) in declared.sorted(by: { $0.key < $1.key }) {
            let type = (definition["type"] as? String ?? "").lowercased()
            let from = defaults[property] ?? Self.defaultValue(definition)
            func row(_ status: Status, _ kind: String, _ note: String, to: String = "") -> Row {
                Row(wallpaper: name, title: project.title, type: "web", property: property, propertyType: type, from: from,
                    to: to, status: status, kind: kind, note: note, sites: ["web: wallpaperPropertyListener.applyUserProperties"])
            }
            guard let to = UserPropertySweepValues.changed(type: type, property: definition, current: from) else {
                rows.append(row(.unclear, "not changeable", "no other valid value to set (\(type))"))
                continue
            }
            // Noise: the two unchanged pages a moment apart.
            let listener = pair[1].evaluate(Self.listenerProbe) ?? "none"
            Self.wait(0.3)
            let noise = Self.difference(pair[0].snapshot(), pair[1].snapshot())
            // Live: the sidebar's notification, for the copy's store only.
            NotificationCenter.default.post(name: .wallpaperUserPropertyChanged, object: directory.path,
                                            userInfo: ["key": property, "value": to,
                                                       "stores": [scopes[1].runtimeKey(directory: directory)]])
            Self.wait(0.6)
            let liveDifference = Self.difference(pair[0].snapshot(), pair[1].snapshot())
            let error = pair[1].evaluate("(window.__oweSweep&&window.__oweSweep.errors.join('; '))||''") ?? ""
            let called = pair[1].evaluate(Self.listenerCalled(property)) ?? "unknown"
            NotificationCenter.default.post(name: .wallpaperUserPropertyChanged, object: directory.path,
                                            userInfo: ["key": property, "value": from,
                                                       "stores": [scopes[1].runtimeKey(directory: directory)]])
            // Fresh: the page loaded with the new value, next to one with the defaults.
            var values = defaults
            values[property] = to
            let fresh = [open(wallpaper, scope: .display("sweep-d"), values: defaults, properties: properties),
                         open(wallpaper, scope: .display("sweep-f"), values: values, properties: properties)]
            Self.settle(fresh)
            let freshDifference = Self.difference(fresh[0].snapshot(), fresh[1].snapshot())
            fresh.forEach { $0.close() }

            let note = String(format: "live Δ%.4f (noise %.4f), fresh Δ%.4f (noise %.4f)", liveDifference, noise,
                              freshDifference, freshNoise)
            let offByDefault = Self.offByDefault(definition, declared: declared)
            if listener == "none" && called != "yes" {
                rows.append(row(.broken, "web listener", "the page has no wallpaperPropertyListener.applyUserProperties; " + note, to: to))
            } else if !error.isEmpty {
                rows.append(row(.broken, "web listener", "applyUserProperties threw \(error); " + note, to: to))
            } else if called == "no" {
                rows.append(row(.broken, "web listener", "applyUserProperties was never called with it; " + note, to: to))
            } else if let condition = offByDefault, Self.outcome(liveDifference, noise: noise) != .changed {
                rows.append(row(.unclear, "off by default",
                                "nothing visible expected: its condition `\(condition)` is false by default; " + note, to: to))
            } else if let (status, reason) = Self.verdict(live: Self.outcome(liveDifference, noise: noise),
                                                          fresh: Self.outcome(freshDifference, noise: freshNoise)) {
                rows.append(row(status, "web", reason + note, to: to))
            } else {
                rows.append(row(.unclear, "web", "the page took the value, nothing visible; " + note, to: to))
            }
        }
        return rows
    }

    // MARK: - Report

    static func report(_ rows: [Row]) -> String {
        var text = "# User property sweep\n\n"
        let working = rows.filter { $0.status == .working }.count
        let broken = rows.filter { $0.status == .broken }
        let unclear = rows.filter { $0.status == .unclear }
        let wallpapers = Set(rows.map(\.wallpaper)).count
        text += "\(rows.count) properties in \(wallpapers) wallpapers: \(working) working, \(broken.count) broken, \(unclear.count) unclear.\n\n"
        text += "A property works when a frame or its bound target changes, both live (the app's change path) and on a fresh load. "
        text += "Broken ones are grouped by the kind of binding that carries them, so each kind can be fixed once.\n\n"

        text += "## Broken, by binding kind\n\n"
        let byKind = Dictionary(grouping: broken, by: \.kind)
        text += "| kind | broken |\n|---|---|\n"
        for (kind, group) in byKind.sorted(by: { $0.value.count > $1.value.count }) { text += "| \(kind) | \(group.count) |\n" }
        for (kind, group) in byKind.sorted(by: { $0.value.count > $1.value.count }) {
            text += "\n### \(kind) (\(group.count))\n\n"
            for row in group.sorted(by: { ($0.wallpaper, $0.property) < ($1.wallpaper, $1.property) }) {
                text += "- **\(row.wallpaper)** \(escape(row.title)): `\(row.property)` (\(row.propertyType) \(escape(row.from)) → \(escape(row.to))). \(escape(row.note))\n"
                for site in row.sites { text += "  - \(escape(site))\n" }
            }
        }

        text += "\n## Unclear (no visible change; inspect)\n\n"
        let unclearByKind = Dictionary(grouping: unclear, by: \.kind)
        text += "| kind | unclear |\n|---|---|\n"
        for (kind, group) in unclearByKind.sorted(by: { $0.value.count > $1.value.count }) { text += "| \(kind) | \(group.count) |\n" }

        text += "\n## Per wallpaper\n"
        for (wallpaper, group) in Dictionary(grouping: rows, by: \.wallpaper).sorted(by: { $0.key < $1.key }) {
            let first = group[0]
            text += "\n### \(wallpaper) \(escape(first.title)) (\(first.type))\n\n"
            for status in [Status.broken, .unclear, .working] {
                let members = group.filter { $0.status == status }.sorted { $0.property < $1.property }
                guard !members.isEmpty else { continue }
                text += "- \(status.rawValue) (\(members.count)): "
                if status == .working {
                    text += members.map { "`\($0.property)`" }.joined(separator: ", ") + "\n"
                    continue
                }
                text += "\n"
                for row in members {
                    text += "  - `\(row.property)` [\(row.kind)] \(escape(row.note))"
                    if status == .broken, !row.sites.isEmpty { text += " — " + row.sites.map(escape).joined(separator: "; ") }
                    text += "\n"
                }
            }
        }
        return text
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
