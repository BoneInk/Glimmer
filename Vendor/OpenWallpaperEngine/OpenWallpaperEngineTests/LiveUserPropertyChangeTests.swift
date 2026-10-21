import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A user property changed on a running, still scene (`Scenes/binding-kinds`, a frozen clock, idle
/// skipping on) through the app's change path (`SceneFrameHarness.changeProperties`, as
/// `SceneWallpaperInstance` applies it): the frame demand wakes, the next frame is encoded, and it
/// draws the change. One case per kind the property sweep reported as live-dead (layer and effect
/// `visible`, a combo's `condition` on `visible`, an object field, an effect constant, a colour).
@MainActor
final class LiveUserPropertyChangeTests: XCTestCase {
    private struct Case {
        let name: String
        /// Applied first, each settled before the next (a colour is only seen on a shown layer).
        let steps: [[String: String]]
        let impact: SceneChangeImpact
        let shows: (Pixels) -> Bool
    }

    private let cases: [Case] = [
        Case(name: "effect visible", steps: [["showeffect": "false"]], impact: .none,
             shows: { $0.rgb(32, 32).x == 0 }),
        Case(name: "layer visible (combo condition)", steps: [["layer": "2"]], impact: .none,
             shows: { $0.rgb(96, 32) == SIMD3(0, 255, 0) }),
        Case(name: "object field", steps: [["fade": "0.5"]], impact: .none,
             shows: { abs(Int($0.rgb(32, 32).z) - 128) < 8 }),
        Case(name: "effect constant", steps: [["red": "0.5"]], impact: .none,
             shows: { abs(Int($0.rgb(32, 32).x) - 128) < 8 }),
        Case(name: "colour", steps: [["layer": "2"], ["ink": "1 0 0"]], impact: .none,
             shows: { $0.rgb(96, 32) == SIMD3(255, 0, 0) }),
        Case(name: "combo", steps: [["greenmode": "1"]], impact: .none,
             shows: { abs(Int($0.rgb(160, 32).y) - 128) < 8 }),
    ]

    func testALiveChangeWakesAStillSceneAndDrawsIt() throws {
        _ = try Fixtures.assets()
        for change in cases {
            Fixtures.removeStoredSettings(for: Self.directory)
            let harness = try SceneFrameHarness(directory: Self.directory, size: Self.size)
            defer { harness.close() }
            try XCTSkipIf(harness.model.metalContent()?.layers.first?.weEffects.isEmpty ?? true,
                          "no shader toolchain for the fixture's effects")
            harness.renderer.skipsIdleFrames = true
            let before = try settle(harness)
            XCTAssertFalse(change.shows(before), "\(change.name): the fixture already shows the change")

            for (index, values) in change.steps.enumerated() {
                // A still scene draws nothing more: the clock is frozen and nothing changed.
                let idle = harness.renderer.encodedFrames
                harness.draw(frames: 2, step: 0)
                XCTAssertEqual(harness.renderer.encodedFrames, idle, "\(change.name): a still scene keeps drawing")

                XCTAssertEqual(try harness.changeProperties(values), change.impact, "\(change.name): no whole-scene rebuild")
                harness.draw(frames: 1, step: 0)
                XCTAssertGreaterThan(harness.renderer.encodedFrames, idle,
                                     "\(change.name): the change didn't wake the frame demand")
                let after = try settle(harness, until: index == change.steps.count - 1 ? change.shows : { _ in true })
                if index == change.steps.count - 1 {
                    XCTAssertTrue(change.shows(after), "\(change.name): the change isn't drawn")
                }
            }
            XCTAssertEqual(harness.renderer.bindingRevisions.staleReuses, 0, change.name)
        }
    }

    /// The sweep's old path, scripts alone: the bindings never hear of the change, so the frame
    /// doesn't either. Kept as the reason `changeProperties` exists.
    func testScriptsAloneLeaveTheBindingsBehind() throws {
        _ = try Fixtures.assets()
        Fixtures.removeStoredSettings(for: Self.directory)
        let harness = try SceneFrameHarness(directory: Self.directory, size: Self.size)
        defer { harness.close() }
        try XCTSkipIf(harness.model.metalContent()?.layers.first?.weEffects.isEmpty ?? true,
                      "no shader toolchain for the fixture's effects")
        let revisions = harness.renderer.bindingRevisions
        WallpaperServices.shared.setUserProperties(["showeffect": "false"], wallpaper: harness.model.propertyStoreKey,
                                                   replacing: false)
        harness.renderer.scripts.userPropertiesDidChange(["showeffect"])
        XCTAssertEqual(harness.renderer.bindingRevisions.revision(of: "1"), revisions.revision(of: "1"))
        try harness.changeProperties(["showeffect": "false"])
        XCTAssertNotEqual(harness.renderer.bindingRevisions.revision(of: "1"), revisions.revision(of: "1"))
    }

    // MARK: - Fixture

    private static let size = SIMD2(256, 64)
    private static var directory: URL { Fixtures.url("Scenes/binding-kinds") }

    /// Draws with a frozen clock until nothing is compiling, rasterising or being swapped in and
    /// `ready` holds (at most 60 s); returns the last frame drawn.
    private func settle(_ harness: SceneFrameHarness, until ready: (Pixels) -> Bool = { _ in true }) throws -> Pixels {
        let renderer = harness.renderer
        let deadline = Date().addingTimeInterval(60)
        var settled = 0
        var pixels = Pixels(bytes: [])
        repeat {
            harness.draw(frames: 1, step: 0)
            if renderer.hasContent, renderer.pendingReplacements == 0, !renderer.hasPendingEffectPipelines,
               renderer.pendingTextRasters == 0 { settled += 1 } else { settled = 0 }
            pixels = Pixels(view: harness.view)
        } while (settled < 3 || !ready(pixels)) && Date() < deadline
        return pixels
    }

    private struct Pixels {
        let bytes: [UInt8]

        init(bytes: [UInt8]) { self.bytes = bytes }

        init(view: MTKView) {
            var bytes = [UInt8](repeating: 0, count: LiveUserPropertyChangeTests.size.x * LiveUserPropertyChangeTests.size.y * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: LiveUserPropertyChangeTests.size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, LiveUserPropertyChangeTests.size.x,
                                                                         LiveUserPropertyChangeTests.size.y),
                                                   mipmapLevel: 0)
            self.bytes = bytes
        }

        /// (r, g, b) at a view pixel from the top left; black before anything is read.
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let index = (y * LiveUserPropertyChangeTests.size.x + x) * 4
            guard bytes.indices.contains(index + 2) else { return .zero }
            return SIMD3(bytes[index + 2], bytes[index + 1], bytes[index])
        }
    }
}
