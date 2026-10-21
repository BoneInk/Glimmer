import AVFoundation
import JavaScriptCore
import Metal
import XCTest
import simd
@testable import OpenWallpaperEngine

/// `IImageLayer.getVideoTexture` (objects-layers.js) and its way to the layer's player, plus the
/// script fixtures in `Tests/Fixtures/SceneScript/members`, one per member that used to be a stub.
final class SceneScriptVideoTextureTests: XCTestCase {
    private func scene() -> SceneScriptSceneDescription {
        var background = SceneScriptObjectDescription.make(.image, id: 1, name: "background")
        background.videoDuration = 2
        background.values[.playing] = [1]
        let clock = SceneScriptObjectDescription.make(.text, id: 2, name: "clock", parentID: 1)
        let group = SceneScriptObjectDescription.make(.group, id: 5, name: "group")
        var puppet = SceneScriptObjectDescription.make(.image, id: 6, name: "puppet")
        puppet.rig = SceneScriptRigTests.rig
        let plain = SceneScriptObjectDescription.make(.image, id: 7, name: "plain", values: [.size: [200, 100]])
        return SceneScriptSceneDescription(objects: [background, clock, group, puppet, plain])
    }

    private func fixture() throws -> SceneScriptObjectFixture {
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: scene()))
        f.runtime.load()
        return f
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? { f.evaluate(script)?.toString() }

    private func videoCommands(_ f: SceneScriptObjectFixture) -> [SceneScriptObjectCommand] {
        f.host.takeCommands().filter {
            if case .video = $0 { return true }
            return false
        }
    }

    func testMemberFixtures() throws {
        _ = try Fixtures.assets()
        for member in ["setParent", "lookAt", "lookAtYaw", "rotateObjectSpace", "transformAttachmentToTexture", "getVideoTexture"] {
            let f = try fixture()
            // The plain layer sits 50 left of and 25 below the puppet's bind-pose grip (31, 7).
            let slot = try XCTUnwrap(f.model.slot(forObjectID: 7))
            let base = SceneScriptObjectTable.index(slot: slot, field: SceneScriptObjectTable.Layout.worldMatrix)
            let world = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-19, -18, 0, 1)))
            for column in 0..<4 { for row in 0..<4 { f.store.table.values[base + column * 4 + row] = world[column][row] } }
            let source = try String(contentsOf: Fixtures.url("SceneScript/members/\(member).js"), encoding: .utf8)
            XCTAssertEqual(string(f, source), "ok", member)
        }
    }

    /// WE's `IVideoTexture` doesn't extend `IObject`, so it has no `getAnimation` (lib.sceneScript.d.ts);
    /// the copy of `IAnimationLayer.getAnimation` it once carried threw a TypeError.
    func testVideoTextureHasNoGetAnimation() throws {
        let f = try fixture()
        XCTAssertEqual(string(f, "typeof thisScene.getLayer('background').getVideoTexture().getAnimation"), "undefined")
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
    }

    /// The renderer's write of the player's state into the layer's row before a frame.
    private func player(_ f: SceneScriptObjectFixture, time: Float, playing: Bool) throws {
        let slot = try XCTUnwrap(f.model.slot(forObjectID: 1))
        f.store.table.values[slot * SceneScriptObjectTable.Layout.stride + SceneScriptObjectTable.Layout.videoTime] = time
        f.store.table.values[slot * SceneScriptObjectTable.Layout.stride + SceneScriptObjectField.playing.offset] = playing ? 1 : 0
        f.runtime.frame(deltaTime: 1.0 / 30)
    }

    /// The clock is the player's: time and playing come from the renderer, so they can't drift.
    func testVideoTextureClockIsThePlayersAndCallbacksFollowIt() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate("""
            var video = thisScene.getLayer('background').getVideoTexture(), ends = 0;
            video.addEndedCallback(function () { ends += 1; });
            """)
        try player(f, time: 0.5, playing: true)
        try player(f, time: 1.9, playing: true)
        XCTAssertEqual(string(f, "[video.getCurrentTime(), ends].join()"), "1.899999976158142,0")
        try player(f, time: 0.2, playing: true)
        XCTAssertEqual(string(f, "[ends, video.isPlaying()].join()"), "1,true", "a loop's wrap is its end")
        f.evaluate("video.setCurrentTime(0.1);")
        XCTAssertEqual(string(f, "Math.round(video.getCurrentTime() * 10)"), "1", "a seek reads back at once")
        try player(f, time: 0.1, playing: true)
        XCTAssertEqual(string(f, "ends"), "1", "and is no end")

        f.evaluate("video.loop = false;")
        try player(f, time: 1.5, playing: true)
        try player(f, time: 2, playing: false)
        XCTAssertEqual(string(f, "[ends, video.isPlaying()].join()"), "2,false", "a video that doesn't loop holds its end")
        f.evaluate("video.play();")
        XCTAssertEqual(string(f, "[video.isPlaying(), video.getCurrentTime()].join()"), "true,0", "and restarts on play")
    }

    func testVideoTextureCommandsReachTheHost() throws {
        let f = try fixture()
        let slot = try XCTUnwrap(f.model.slot(forObjectID: 1))
        _ = f.host.takeCommands()
        f.evaluate("""
            var video = thisScene.getLayer('background').getVideoTexture();
            video.pause(); video.play(); video.stop(); video.setCurrentTime(0.5); video.rate = 0.5; video.loop = false;
            video.setCurrentTime(NaN); video.rate = 'x';
            """)
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(videoCommands(f), [.video(slot: slot, .pause), .video(slot: slot, .play), .video(slot: slot, .stop),
                                          .video(slot: slot, .seek(0.5)), .video(slot: slot, .rate(0.5)),
                                          .video(slot: slot, .loop(false))])
    }

    func testCommandDecoding() {
        XCTAssertEqual(SceneVideoTextureCommand(numbers: [3, -1]), .seek(0))
        XCTAssertEqual(SceneVideoTextureCommand(numbers: [5, 1]), .loop(true))
        XCTAssertNil(SceneVideoTextureCommand(numbers: [3]))
        XCTAssertNil(SceneVideoTextureCommand(numbers: [9]))
        XCTAssertNil(SceneVideoTextureCommand(numbers: [4, .nan]))
    }

    /// An embedded video decodes only while the wallpaper plays (host rate) and the script wants it.
    func testEmbeddedVideoFollowsTheWallpapersPlayback() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stream = try XCTUnwrap(VideoTextureStream.embedded(mp4: try Self.movie(), device: device))
        XCTAssertEqual(stream.player.rate, 1, "plays from the start")
        stream.setHostRate(0)
        XCTAssertEqual(stream.player.rate, 0, "paused, covered or frozen: the decoder stops")
        stream.setHostRate(1)
        XCTAssertEqual(stream.player.rate, 1)
        stream.perform(.pause)
        stream.setHostRate(1)
        XCTAssertEqual(stream.player.rate, 0, "a script's pause holds")
        XCTAssertFalse(stream.isPlaying)
        stream.perform(.rate(0.5))
        stream.perform(.play)
        stream.setHostRate(2)
        XCTAssertEqual(stream.player.rate, 1, "the script's rate times the wallpaper's")
        stream.stop()
    }

    /// A one-second 16×16 H.264 movie.
    static func movie() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return try Data(contentsOf: url)
    }

    /// The length a video texture reports comes from its MP4's `mvhd` (version 0 and 1).
    func testMP4Duration() {
        func movie(version: UInt8, timescale: UInt32, duration: UInt64) -> Data {
            func be(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(count - 1 - $0))) } }
            let times = version == 1 ? be(0, 16) + be(UInt64(timescale), 4) + be(duration, 8)
                : be(0, 8) + be(UInt64(timescale), 4) + be(duration, 4)
            let mvhd = [version, 0, 0, 0] + times
            let mvhdBox = be(UInt64(mvhd.count + 8), 4) + Array("mvhd".utf8) + mvhd
            let ftyp = be(16, 4) + Array("ftypisom".utf8) + be(0, 4)
            return Data(ftyp + be(UInt64(mvhdBox.count + 8), 4) + Array("moov".utf8) + mvhdBox)
        }
        XCTAssertEqual(MP4Duration.seconds(of: movie(version: 0, timescale: 600, duration: 1500)), 2.5)
        XCTAssertEqual(MP4Duration.seconds(of: movie(version: 1, timescale: 1000, duration: 4000)), 4)
        XCTAssertNil(MP4Duration.seconds(of: Data("not a movie".utf8)))
    }
}
