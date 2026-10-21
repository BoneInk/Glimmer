import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Each kind of user-property binding (`Scenes/binding-kinds`), changed on a running scene the way
/// the wallpaper instance applies it (`SceneBindingUpdate`: in place, or by rebuilding the object),
/// changes what is drawn, and draws what a fresh load with that value draws.
@MainActor
final class UserPropertyBindingRenderTests: XCTestCase {
    private typealias Pixels = BindingFixture.Pixels

    /// One change: the properties, what the update does, and when the drawn frame shows it.
    private struct Case {
        let name: String
        let values: [String: String]
        let rebuilds: Set<Int>
        let shows: (Pixels) -> Bool
    }

    private let cases: [Case] = [
        Case(name: "transform", values: ["place": "48 32 0"], rebuilds: [], shows: { $0.rgb(72, 32).z > 200 }),
        Case(name: "alpha", values: ["fade": "0.5"], rebuilds: [], shows: { abs(Int($0.rgb(32, 32).z) - 128) < 8 }),
        Case(name: "effect visible", values: ["showeffect": "false"], rebuilds: [], shows: { $0.rgb(32, 32).x == 0 }),
        Case(name: "effect constant", values: ["red": "0.5"], rebuilds: [], shows: { abs(Int($0.rgb(32, 32).x) - 128) < 8 }),
        Case(name: "colour and condition", values: ["ink": "1 0 0", "layer": "2"], rebuilds: [4],
             shows: { $0.rgb(96, 32) == SIMD3(255, 0, 0) }),
        Case(name: "size", values: ["big": "64 64"], rebuilds: [5], shows: { $0.rgb(135, 32).x > 200 }),
        Case(name: "combo", values: ["greenmode": "1"], rebuilds: [5], shows: { abs(Int($0.rgb(160, 32).y) - 128) < 8 }),
    ]

    func testEveryKindChangesTheTargetAndMatchesAFreshLoad() throws {
        _ = try Fixtures.assets()
        for change in cases {
            let fixture = try BindingFixture()
            let before = try fixture.render(frames: 3)
            XCTAssertFalse(change.shows(before), "\(change.name): the fixture already shows the change")
            let update = fixture.model.bindingUpdate(for: Array(change.values.keys))
            XCTAssertEqual(update.impact, .none, "\(change.name): no whole-scene rebuild")
            XCTAssertEqual(update.rebuild, change.rebuilds, change.name)
            try fixture.change(change.values)
            let live = try fixture.render(frames: 3, until: change.shows)
            XCTAssertTrue(change.shows(live), "\(change.name): the change isn't drawn")
            XCTAssertEqual(fixture.renderer.bindingRevisions.staleReuses, 0, change.name)
            fixture.saveProperties()
            fixture.close(keepingSettings: true)

            let fresh = try BindingFixture(keepingSettings: true)
            let loaded = try fresh.render(frames: 3, until: change.shows)
            XCTAssertLessThanOrEqual(live.maximumDifference(from: loaded), 2, "\(change.name): differs from a fresh load")
            fresh.close()
        }
    }

    /// A text's string sizes its raster: the object alone is rebuilt, draws the new string, and
    /// draws what a fresh load does.
    func testTextIsRebuiltAlone() throws {
        _ = try Fixtures.assets()
        let fixture = try BindingFixture()
        let before = try fixture.render(frames: 3) { $0.region(x: 192..<256).contains { $0 > 100 } }
        XCTAssertEqual(fixture.model.bindingUpdate(for: ["caption"]).rebuild, [8])
        try fixture.change(["caption": "ok"])
        let after = try fixture.render(frames: 3) { $0.region(x: 192..<256) != before.region(x: 192..<256) }
        XCTAssertNotEqual(after.region(x: 192..<256), before.region(x: 192..<256))
        fixture.saveProperties()
        fixture.close(keepingSettings: true)
        let fresh = try BindingFixture(keepingSettings: true)
        defer { fresh.close() }
        let loaded = try fresh.render(frames: 3) { $0.region(x: 192..<256).contains { $0 > 100 } }
        XCTAssertLessThanOrEqual(after.maximumDifference(from: loaded), 2, "differs from a fresh load")
    }

    // MARK: - Fixture

    private final class BindingFixture {
        static let size = SIMD2(256, 64)
        let directory = Fixtures.url("Scenes/binding-kinds")
        let wallpaper: WEWallpaper
        let model: SceneContentLoader
        let renderer: SceneMetalRenderer
        let view: MTKView
        var key: String { model.propertyStoreKey }

        init(keepingSettings: Bool = false) throws {
            if !keepingSettings { Fixtures.removeStoredSettings(for: directory) }
            let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/binding-kinds/project.json"))
            wallpaper = WEWallpaper(using: project, where: directory)
            model = SceneContentLoader(wallpaper: wallpaper)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "binding-kinds"))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            let content = try XCTUnwrap(model.metalContent())
            try XCTSkipIf(content.layers.first?.weEffects.isEmpty ?? true, "no shader toolchain for the fixture's effects")
            renderer.setContent(content)
        }

        func close(keepingSettings: Bool = false) {
            renderer.releaseContent()
            if !keepingSettings { Fixtures.removeStoredSettings(for: directory) }
        }

        func saveProperties() {
            WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared])
                .save(WallpaperServices.shared.userProperties(wallpaper: key))
        }

        /// Sets `values` in the running store and applies them as the wallpaper instance does.
        func change(_ values: [String: String]) throws {
            WallpaperServices.shared.setUserProperties(values, wallpaper: key, replacing: false)
            let update = model.bindingUpdate(for: Array(values.keys))
            renderer.userPropertiesDidChange(Set(values.keys), owners: update.owners)
            if !update.rebuild.isEmpty {
                renderer.replaceObjects(try XCTUnwrap(model.rebuildObjects(update.rebuild), "can't be rebuilt alone"))
            }
        }

        /// Draws `frames` frames, then more until `ready` holds (at most 60 s), and returns the last.
        func render(frames: Int = 1, until ready: (Pixels) -> Bool = { _ in true }) throws -> Pixels {
            let deadline = Date().addingTimeInterval(60)
            var drawn = 0
            var pixels = Pixels(bytes: [])
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                // Settled: nothing compiling, rasterising or being swapped in.
                if renderer.hasContent, renderer.pendingReplacements == 0, !renderer.hasPendingEffectPipelines,
                   renderer.pendingTextRasters == 0 { drawn += 1 }
                var bytes = [UInt8](repeating: 0, count: Self.size.x * Self.size.y * 4)
                view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: Self.size.x * 4,
                                                       from: MTLRegionMake2D(0, 0, Self.size.x, Self.size.y), mipmapLevel: 0)
                pixels = Pixels(bytes: bytes)
            } while (drawn < frames || !ready(pixels)) && Date() < deadline
            return pixels
        }

        struct Pixels {
            let bytes: [UInt8]

            /// (r, g, b) at a view pixel from the top left.
            func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
                let index = (y * BindingFixture.size.x + x) * 4
                return SIMD3(bytes[index + 2], bytes[index + 1], bytes[index])
            }

            /// Every byte of the columns `x`, row by row.
            func region(x: Range<Int>) -> [UInt8] {
                (0..<BindingFixture.size.y).flatMap { row in
                    bytes[((row * BindingFixture.size.x + x.lowerBound) * 4)..<((row * BindingFixture.size.x + x.upperBound) * 4)]
                }
            }

            func maximumDifference(from other: Pixels) -> Int {
                zip(bytes, other.bytes).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
            }
        }
    }
}
