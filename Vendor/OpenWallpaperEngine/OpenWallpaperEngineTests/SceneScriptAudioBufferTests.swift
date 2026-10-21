import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// `engine.registerAudioBuffers` (docs/scenescript-plan.md WP5): live left/right/average arrays at
/// 16, 32 and 64 bands, refilled before every frame, and WE's global-scope and resolution rules.
final class SceneScriptAudioBufferTests: XCTestCase {
    private var spectrum = AudioSpectrumSnapshot.silent

    private func makeRuntime(_ source: String, spectrum: (() -> AudioSpectrumSnapshot)? = nil) throws -> SceneScriptRuntime {
        let audio = SceneScriptAudioBuffersExtension(spectrum: spectrum ?? { [unowned self] in self.spectrum })
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler(),
                                             extensions: [audio])
        runtime.add(SceneScriptInstance(id: "audio", source: source, initialValue: 0))
        runtime.load()
        return runtime
    }

    private func evaluate(_ script: String, in runtime: SceneScriptRuntime) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    func testBuffersHoldTheFrameSpectrumAndStayTheSameObjects() throws {
        let runtime = try makeRuntime("""
            const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
            const wide = engine.registerAudioBuffers(64);
            let first;
            function init(value) { first = audio.left; return value; }
            function update(value) {
                shared.same = first === audio.left && first.buffer === audio.left.buffer;
                shared.seen = [audio.left[3], audio.right[3], audio.average[3], wide.left[63], wide.average[0]];
                shared.shape = [audio.left.length, audio.right.length, audio.average.length, wide.left.length,
                                audio.left instanceof Float32Array];
                return value;
            }
            """)
        spectrum.left16[3] = 0.25
        spectrum.right16[3] = 0.75
        spectrum.average16[3] = 0.5
        spectrum.left64[63] = 1.5
        spectrum.average64[0] = 0.125
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.seen.join(' ')", in: runtime)?.toString(), "0.25 0.75 0.5 1.5 0.125")
        XCTAssertEqual(evaluate("shared.shape.join(' ')", in: runtime)?.toString(), "16 16 16 64 true")

        spectrum.left16[3] = 0.875
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.seen[0]", in: runtime)?.toDouble(), 0.875, "refilled in place every frame")
        XCTAssertEqual(evaluate("shared.same", in: runtime)?.toBool(), true)
    }

    func testALeftOnlyToneLeavesTheRightSilentAtEveryResolution() throws {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000)
        let length = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let tone = (0..<length).map { 0.5 * Float(sin(2 * Double.pi * 150 * Double($0) / Double(length))) }
        let quiet = [Float](repeating: 0, count: length)
        tone.withUnsafeBufferPointer { left in quiet.withUnsafeBufferPointer { analyzer.ingest(left: left, right: $0) } }
        // The renderer advances the analyzer once per frame; here the source does.
        let runtime = try makeRuntime("""
            const buffers = [16, 32, 64].map(function (n) { return engine.registerAudioBuffers(n); });
            function update(value) {
                shared.peaks = buffers.map(function (b) {
                    return [Math.max.apply(null, b.left), Math.max.apply(null, b.right), Math.max.apply(null, b.average)];
                });
                return value;
            }
            """, spectrum: { analyzer.advanceFrame(deltaTime: 1.0 / 60) })
        for _ in 0..<120 { runtime.frame(deltaTime: 1.0 / 60) }
        for (index, resolution) in [16, 32, 64].enumerated() {
            let peaks = try XCTUnwrap(evaluate("shared.peaks[\(index)]", in: runtime)?.toArray() as? [Double])
            XCTAssertGreaterThan(peaks[0], 0.5, "left at \(resolution)")
            XCTAssertLessThan(peaks[1], 0.01, "right at \(resolution)")
            XCTAssertEqual(peaks[2], peaks[0] / 2, accuracy: 0.05, "average at \(resolution)")
        }
    }

    func testRegistrationsShareMemoryButNotBuffers() throws {
        let audio = SceneScriptAudioBuffersExtension(spectrum: { [unowned self] in self.spectrum })
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler(),
                                             extensions: [audio])
        runtime.add(SceneScriptInstance(id: "writer", source: """
            const audio = engine.registerAudioBuffers(16);
            function update(value) {
                audio.average[0] = 99;
                if (typeof audio.left.buffer.transfer === 'function') { shared.moved = audio.left.buffer.transfer(); }
                return value;
            }
            """))
        runtime.add(SceneScriptInstance(id: "reader", source: """
            const audio = engine.registerAudioBuffers(16);
            function update(value) {
                shared.read = [audio.average[0], audio.left.length, audio.left[1], audio.left.buffer !== audio.right.buffer];
                return value;
            }
            """))
        runtime.load()
        spectrum.left16[1] = 0.5
        runtime.frame(deltaTime: 1.0 / 60)
        // WE hands every registration the scene's one store (scenescript64.dll 0x181655405), so a
        // write reaches later scripts until the next refill; a transfer detaches only the writer's.
        XCTAssertEqual(runtime.context.evaluateScript("shared.read.join(' ')")?.toString(), "99 16 0.5 true")
        runtime.context.evaluateScript("shared.moved = undefined;")
        JSGarbageCollect(runtime.context.jsGlobalContextRef)
        spectrum.left16[1] = 0.25
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.context.evaluateScript("shared.read.join(' ')")?.toString(), "99 16 0.25 true",
                       "the refill still lands after the writer's buffer was moved and collected")
    }

    func testOnlySixteenThirtyTwoAndSixtyFour() throws {
        let runtime = try makeRuntime("""
            try { engine.registerAudioBuffers(128); } catch (error) { shared.error = error.message; }
            shared.defaulted = engine.registerAudioBuffers().left.length;
            shared.truncated = engine.registerAudioBuffers(32.9).left.length;
            """)
        XCTAssertEqual(evaluate("shared.error", in: runtime)?.toString(), "Resolution must be either 16, 32 or 64.")
        XCTAssertEqual(evaluate("shared.defaulted", in: runtime)?.toInt32(), 16, "no number: the DLL uses 16")
        XCTAssertEqual(evaluate("shared.truncated", in: runtime)?.toInt32(), 32, "read as an int32")
        XCTAssertTrue(runtime.isEnabled("audio"))
    }

    func testOnlyAtGlobalScope() throws {
        let runtime = try makeRuntime("""
            function init(value) {
                try { engine.registerAudioBuffers(16); } catch (error) { shared.error = error.message; }
                return value;
            }
            """)
        XCTAssertEqual(evaluate("shared.error", in: runtime)?.toString(),
                       "registerAudioBuffers can only be called from global scope.")
    }
}
