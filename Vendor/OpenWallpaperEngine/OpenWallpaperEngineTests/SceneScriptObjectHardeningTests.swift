import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Regression tests for the object model's findings in docs/test-risks.md (SF3, SF10–SF13) and
/// the WP7 integration notes (instance bindings, `registerAsset`).
final class SceneScriptObjectHardeningTests: XCTestCase {
    private func fixture() throws -> SceneScriptObjectFixture {
        try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptObjectModelTests.sceneDescription(),
                                                               describe: SceneScriptObjectModelTests.describe))
    }

    // MARK: - SF10: non-finite numbers never reach Int(...)

    func testNonFiniteNumbersInCommandsNeverTrap() throws {
        let f = try fixture()
        f.runtime.load()
        f.evaluate("""
            var snow = thisScene.getLayer('snow');
            snow.emitParticles(NaN); snow.emitParticles(Infinity); snow.emitParticles(1e30);
            snow.emitParticles(-5); snow.emitParticles(2.7); snow.emitParticles(1e39);
            """)
        let OP = SceneScriptCommandRing.Opcode.self
        // Scripts can push any opcode with any numbers through the ring (S28).
        for opcode in [OP.objectSort, .materialSetProperty, .materialSetConstant, .materialExecuteFunction, .particlesEmit,
                       .animationSetFrame] {
            for bad in ["NaN", "Infinity", "-Infinity", "1e39", "-1e30"] {
                f.evaluate("__rt.push(\(opcode.rawValue), 3, [\(bad), \(bad), 1], ['x'])")
                f.evaluate("__rt.push(\(opcode.rawValue), 0, [\(bad), \(bad), 1], ['x'])")
            }
        }
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = f.host.takeCommands()
        let emitted = commands.compactMap { command -> Int? in
            guard case .emitParticles(3, let count) = command else { return nil }
            return count
        }
        let maximum = SceneScriptObjectModel.maximumEmitCount
        XCTAssertEqual(Array(emitted.prefix(5)), [maximum, maximum, 0, 2, maximum],
                       "NaN emits nothing; the rest is floored and clamped")
        for command in commands {
            switch command {
            case .setMaterialProperty(_, let effect, let material, _, _):
                XCTAssertTrue(effect >= 0 && (material ?? 0) >= 0)
            case .executeMaterialFunction(_, let effect, _):
                XCTAssertGreaterThanOrEqual(effect, 0)
            case .animation(_, .setFrame(let frame)):
                XCTAssertTrue(frame.isFinite)
            default: break
            }
        }
    }

    func testNumbersConvertWithoutTrapping() {
        XCTAssertNil(SceneScriptNumber.integer(Float.nan, clampedTo: 0...10))
        XCTAssertEqual(SceneScriptNumber.integer(Float.infinity, clampedTo: 0...10), 10)
        XCTAssertEqual(SceneScriptNumber.integer(-Float.infinity, clampedTo: 0...10), 0)
        XCTAssertEqual(SceneScriptNumber.integer(Double(1e300), clampedTo: 0...Int.max), Int.max)
        XCTAssertEqual(SceneScriptNumber.integer(Float(-2.7), clampedTo: -5...5), -2)
        XCTAssertNil(SceneScriptNumber.index(Float.infinity, in: 0...10))
        XCTAssertNil(SceneScriptNumber.index(Float(11), in: 0...10))
        XCTAssertEqual(SceneScriptNumber.index(Float(10.5), in: 0...10), 10)
        XCTAssertEqual(SceneScriptNumber.index(Double(-1), in: -1...10), -1)
    }

    // MARK: - SF3: scripts can't free or detach the shared memory

    func testTransferringASharedBufferCopiesAndSwiftKeepsWriting() throws {
        let f = try fixture()
        f.runtime.load()
        f.evaluate("""
            var layer = thisScene.getLayer('background');
            var buffers = [layer._t, layer._d, __rt.ring.header, __rt.ring.records, __rt.ring.args,
                           thisScene.getLayer(0).getEffect(0)._t];
            shared.copies = buffers.map(function (array) {
                return typeof array.buffer.transfer === 'function' ? array.buffer.transfer() : null;
            });
            shared.copies = null;
            """)
        JSGarbageCollect(f.runtime.context.jsGlobalContextRef)
        XCTAssertEqual(f.evaluate("buffers.every(function (a) { return a.length > 0; })")?.toBool(), true,
                       "pinned buffers are copied, not detached")
        f.store.table[0, .alpha] = [0.25]
        XCTAssertEqual(f.evaluate("layer.alpha")?.toDouble(), 0.25, "Swift's writes still reach scripts")
        f.evaluate("layer.alpha = 0.5")
        XCTAssertEqual(f.table(0, .alpha), [0.5])
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.runtime.state, .loaded)
        XCTAssertTrue(f.store.sharedBuffers.allSatisfy { !$0.isDetached })
    }

    func testMemoryOutlivesTheSwiftOwnerWhileJavaScriptHoldsIt() throws {
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler())
        var buffer = SceneScriptSharedBuffer<Float>(count: 4, in: runtime.context)
        runtime.context.setObject(buffer?.value, forKeyedSubscript: "kept" as NSString)
        buffer?[2] = 7
        buffer = nil
        JSGarbageCollect(runtime.context.jsGlobalContextRef)
        runtime.context.evaluateScript("kept[1] = 3;")
        XCTAssertEqual(runtime.context.evaluateScript("kept[2] + kept[1]")?.toDouble(), 10,
                       "the typed array's reference keeps the bytes")
    }

    // MARK: - SF11, SF12: destroyLayer

    func testDestroyRunsWhileTheLayerIsStillInTheScene() throws {
        let f = try fixture()
        f.add("clock-script", slot: 1, """
            function destroy() {
                shared.found = thisScene.getLayer(thisLayer.name) === thisLayer;
                thisLayer.alpha = 0.25;
                shared.alpha = thisLayer.alpha;
            }
            """)
        f.runtime.load()
        f.evaluate("thisScene.destroyLayer('clock')")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.evaluate("shared.found + ',' + shared.alpha")?.toString(), "true,0.25")
        XCTAssertEqual(f.host.takeCommands(), [.destroy(slot: 1)])
    }

    func testScriptIdsRemovedByDestroyLayerCanBeReused() throws {
        let f = try fixture()
        f.add("bar/visible", slot: 1, "function update(value) { return value; }")
        f.runtime.load()
        f.evaluate("thisScene.destroyLayer('clock')")
        f.runtime.frame(deltaTime: 1.0 / 60)
        f.add("bar/visible", slot: 2, "function init() { shared.second = true; }")
        f.runtime.load()
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(f.evaluate("shared.second")?.toBool(), true)
    }

    // MARK: - SF13: angles

    func testAnglesRoundTripInDegrees() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.runtime.load()
        XCTAssertEqual(f.evaluate("thisScene.getLayer('background').angles.z")?.toDouble(), 90,
                       "radians from the scene read back as the float conversion gives them")
        XCTAssertEqual(f.evaluate("""
            var bg = thisScene.getLayer('background');
            bg.angles = new Vec3(0, 12.5, 45);
            [bg.angles.y, bg.angles.z].join()
            """)?.toString(), "12.5,45")
        let z = f.evaluate("""
            var a = bg.angles; a.z = 0; bg.angles = a;
            for (var i = 0; i < 100000; i++) { var v = bg.angles; v.z += 0.36; bg.angles = v; }
            bg.angles.z
            """)?.toDouble() ?? 0
        XCTAssertEqual(z, 36_000, accuracy: 0.01)
        f.store.table[0, .angles] = [0, 0, Float.pi]
        XCTAssertEqual(f.evaluate("bg.angles.z")?.toDouble(), 180, "radians written natively win over the cache")
    }

    // MARK: - Integration: bindings and assets

    func testTheInstanceBindingMakesThisObject() throws {
        let f = try fixture()
        f.runtime.add(SceneScriptInstance(id: "fx", source: "function init() { shared.isEffect = thisObject === thisLayer.getEffect(0); }",
                                          objectSlot: 0, binding: .effect(slot: 0, effect: 0, property: "visible")))
        f.runtime.load()
        XCTAssertEqual(f.evaluate("shared.isEffect")?.toBool(), true)
    }

    func testRegisterAssetHandlesCreateLayers() throws {
        let f = try fixture()
        f.add("bars", slot: 0, """
            var handle = engine.registerAsset('models/bar.json', true);
            function init() {
                shared.config = handle.toConfigString();
                shared.bar = thisScene.createLayer(handle) !== null;
                try { engine.registerAsset('models/bar.json'); } catch (e) { shared.message = e.message; }
            }
            """)
        f.runtime.load()
        XCTAssertEqual(f.evaluate("[shared.config, shared.bar, shared.message].join('|')")?.toString(),
                       "models/bar.json|true|registerAsset can only be called from global scope.")
        XCTAssertEqual(f.host.takeCommands().first, .create(slot: 5, source: .asset("models/bar.json")),
                       "commands issued while loading run before the first frame (SF5)")
    }
}
