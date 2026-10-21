import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Effect constants, visibility, text and particle colours apply without a content rebuild, while
/// the user edits properties (`ScenePropertyEditing`) and after. Ending the editing rebuilds once,
/// to exactly what a fresh load draws. Showing the properties with nothing changed changes nothing.
@MainActor
final class SceneLivePropertyTests: XCTestCase {
    func testUserVisibilityFollowsTheProperties() throws {
        let json = #"""
        [{"id": 1, "visible": {"user": "show", "value": true},
          "effects": [{"file": "a.json", "visible": {"user": {"name": "mode", "condition": "Two"}, "value": false}},
                      {"file": "b.json"}]},
         {"id": 2, "visible": false},
         {"id": 3, "text": {"value": "hi"}}]
        """#
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(json.utf8))
        let visibility = SceneUserVisibility(objects: objects)
        var values = ["show": "false", "mode": "two", "_owe_text_3_enabled": "false"]
        var resolved = visibility.resolve { values[$0] }
        XCTAssertEqual(resolved.objects, ["1": false, "2": false, "3": false])
        XCTAssertEqual(resolved.effects, ["1": [0: true]], "only bound effects; a combo matches its option loosely")
        values = ["show": "1", "mode": "1", sceneObjectVisibilityKey(objectID: 2): "true"]
        resolved = visibility.resolve { values[$0] }
        XCTAssertEqual(resolved.objects, ["1": true, "2": true, "3": true])
        XCTAssertEqual(resolved.effects, ["1": [0: false]])
    }

    func testUserEffectVisibilityHidesAndRedrawsTheChain() {
        let scripts = SceneRendererScripts(services: nil, screenID: "live")
        var plans = [SceneEffectPlan(file: "a.json", fbos: [], passes: []), SceneEffectPlan(file: "b.json", fbos: [], passes: [])]
        plans[0].effectIndex = 0
        plans[1].effectIndex = 3
        plans[1].visible = false
        let built = scripts.effects(plans, of: "7")
        XCTAssertEqual(built.hidden, [1])
        scripts.applyUserVisibility(objects: ["7": true], effects: ["7": [0: false, 3: true]])
        let live = scripts.effects(plans, of: "7")
        XCTAssertEqual(live.hidden, [0])
        XCTAssertNotEqual(live.revision, built.revision, "a kept static chain is drawn again")
        scripts.setContent(nil, visibility: [:], parents: [:])
        XCTAssertEqual(scripts.effects(plans, of: "7").hidden, [1], "a new content starts from its plans")
    }

    func testPublishingSendsOnlyRealChanges() {
        let running = ["a": "1", "b": "x"]
        let defaults = ["c": "true", "d": ""]
        XCTAssertEqual(WallpaperPropertyTargets.changes(["a": "1", "c": "true", "d": ""], from: running, defaults: defaults), [:],
                       "a missing key stands for its default")
        XCTAssertEqual(WallpaperPropertyTargets.changes(["a": "2", "c": "false", "e": "0"], from: running, defaults: defaults),
                       ["a": "2", "c": "false", "e": "0"])
    }

    func testEditingEndsOnceItsLastWindowStaysClosed() {
        let editing = ScenePropertyEditing()
        var announced: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: .scenePropertyEditingDidChange, object: editing, queue: nil) { _ in
            MainActor.assumeIsolated { announced.append(editing.isActive) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        editing.begin()
        editing.begin()
        editing.end()
        XCTAssertTrue(editing.isActive)
        editing.end()
        editing.begin()  // a panel rebuilt for another wallpaper
        RunLoop.main.run(until: Date().addingTimeInterval(ScenePropertyEditing.endDelay + 0.2))
        XCTAssertTrue(editing.isActive)
        editing.end()
        RunLoop.main.run(until: Date().addingTimeInterval(ScenePropertyEditing.endDelay + 0.2))
        XCTAssertFalse(editing.isActive)
        XCTAssertEqual(announced, [true, false])
    }

    /// Opening the properties panel of a running wallpaper, with nothing changed, rebuilds nothing:
    /// it used to hand the wallpaper every value it shows, a label's "" among them, which a
    /// visibility read and so rebuilt the whole scene.
    func testOpeningThePropertiesRebuildsNothing() throws {
        let directory = Fixtures.url("Scenes/live-properties")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/live-properties/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        let model = SceneContentLoader(wallpaper: wallpaper)
        let key = model.propertyStoreKey
        let running = WallpaperServices.shared.userProperties(wallpaper: key)
        XCTAssertEqual(running["showeffect"], "true")
        var posted: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .sceneUserPropertiesDidChange, object: nil, queue: nil) { note in
            guard note.userInfo?["wallpaper"] as? String == key else { return }
            posted.append(note.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        posted.removeAll()
        let panel = SceneUserPropertiesModel(wallpaper: wallpaper, scopes: [.shared])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(panel.properties.isEmpty)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: key), running)
        XCTAssertEqual(posted.map { model.impact(of: $0) }.filter { $0 > .none }, [], "rebuilds: \(posted)")
        // A real change still reaches the wallpaper.
        panel.set("0.5", forID: "red")
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: key)["red"], "0.5")
    }

    // MARK: - Rendered

    /// While editing, the effect's constant, its visibility and a layer's combo visibility show at
    /// once, without a rebuild; the rebuild when editing ends draws what the live frame drew, and
    /// what a fresh load of those properties draws.
    func testLiveChangesMatchAFreshLoadAfterTheReconcile() throws {
        _ = try Fixtures.assets()
        let fixture = try LiveFixture()
        defer { fixture.close() }
        var pixels = try fixture.render { $0.rgb(32, 32).x > 200 }
        XCTAssertEqual(pixels.rgb(32, 32), SIMD3(255, 0, 255), "red set over the blue fill")
        XCTAssertEqual(pixels.rgb(96, 40), SIMD3(0, 0, 0), "the green layer is hidden")

        fixture.change(["red": "0.5"])
        XCTAssertEqual(fixture.model.impact(of: ["red"]), .none)
        pixels = try fixture.render { abs(Int($0.rgb(32, 32).x) - 128) < 4 }
        XCTAssertEqual(Int(pixels.rgb(32, 32).x), 128, accuracy: 3, "a constant is live")

        fixture.change(["showeffect": "false", "layer": "2"])
        pixels = try fixture.render { $0.rgb(32, 32).x == 0 }
        XCTAssertEqual(pixels.rgb(32, 32), SIMD3(0, 0, 255), "the effect is hidden")
        XCTAssertEqual(pixels.rgb(96, 40), SIMD3(0, 255, 0), "the green layer shows")
        let live = pixels

        // Editing ends: the reconcile rebuilds the content.
        fixture.model.invalidateContent()
        fixture.renderer.releaseContent()
        fixture.renderer.setContent(try XCTUnwrap(fixture.model.metalContent()))
        let reconciled = try fixture.render { $0.rgb(96, 40).y > 200 }
        XCTAssertEqual(reconciled.bytes, live.bytes)

        // What a fresh load of the saved properties draws.
        WallpaperPropertyTargets(wallpaper: fixture.wallpaper, scopes: [.shared])
            .save(WallpaperServices.shared.userProperties(wallpaper: fixture.key))
        let fresh = try LiveFixture(keepingSettings: true)
        defer { fresh.close() }
        XCTAssertEqual(try fresh.render { $0.rgb(96, 40).y > 200 }.bytes, reconciled.bytes)
    }

    /// With no window editing properties a change applies the same way, without a rebuild.
    func testWithoutEditingAChangeAppliesInPlace() throws {
        _ = try Fixtures.assets()
        let fixture = try LiveFixture()
        defer { fixture.close() }
        _ = try fixture.render { $0.rgb(32, 32).x > 200 }
        fixture.change(["showeffect": "false", "layer": "2"])
        XCTAssertEqual(fixture.model.impact(of: ["showeffect", "layer"]), .none)
        let live = try fixture.render { $0.rgb(96, 40).y > 200 && $0.rgb(32, 32).x == 0 }
        XCTAssertEqual(live.rgb(32, 32), SIMD3(0, 0, 255))
        XCTAssertEqual(fixture.renderer.bindingRevisions.staleReuses, 0)
    }

    private final class LiveFixture {
        static let size = SIMD2(128, 64)
        let directory = Fixtures.url("Scenes/live-properties")
        let wallpaper: WEWallpaper
        let model: SceneContentLoader
        let renderer: SceneMetalRenderer
        let view: MTKView
        var key: String { model.propertyStoreKey }

        init(keepingSettings: Bool = false) throws {
            if !keepingSettings { Fixtures.removeStoredSettings(for: directory) }
            let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/live-properties/project.json"))
            wallpaper = WEWallpaper(using: project, where: directory)
            model = SceneContentLoader(wallpaper: wallpaper)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "live-properties"))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            let content = try XCTUnwrap(model.metalContent())
            try XCTSkipIf(content.layers.first?.weEffects.isEmpty ?? true, "no shader toolchain for the fixture's effect")
            renderer.setContent(content)
        }

        func close() {
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }

        /// Sets `values` in the running store and hands the renderer the change, as the wallpaper
        /// instance does; a structural change swaps in its rebuilt objects.
        func change(_ values: [String: String]) {
            WallpaperServices.shared.setUserProperties(values, wallpaper: key, replacing: false)
            let update = model.bindingUpdate(for: Array(values.keys))
            renderer.userPropertiesDidChange(Set(values.keys), owners: update.owners)
            if !update.rebuild.isEmpty, let replacement = model.rebuildObjects(update.rebuild) {
                renderer.replaceObjects(replacement)
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
                if renderer.hasContent { drawn += 1 }
                var bytes = [UInt8](repeating: 0, count: Self.size.x * Self.size.y * 4)
                view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: Self.size.x * 4,
                                                       from: MTLRegionMake2D(0, 0, Self.size.x, Self.size.y), mipmapLevel: 0)
                pixels = Pixels(bytes: bytes)
            } while (drawn < frames || !ready(pixels)) && Date() < deadline
            return pixels
        }
    }

    private struct Pixels {
        let bytes: [UInt8]

        /// (r, g, b) at a view pixel from the top left.
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let index = (y * LiveFixture.size.x + x) * 4
            return SIMD3(bytes[index + 2], bytes[index + 1], bytes[index])
        }
    }
}
