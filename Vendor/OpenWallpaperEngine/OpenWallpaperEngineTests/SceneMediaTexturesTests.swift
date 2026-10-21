import Metal
import XCTest
@testable import OpenWallpaperEngine

/// A8: the artwork's texture is made once per image, off the render thread, and the render
/// thread only reads the finished one.
final class SceneMediaTexturesTests: XCTestCase {
    private func state(artwork: Int?) -> MediaSessionState {
        var state = MediaSessionState()
        state.thumbnail = .init(artwork: artwork, colors: nil, png: artwork.map { Data([UInt8(truncatingIfNeeded: $0)]) })
        return state
    }

    func testMakesEachArtworkOnceOffTheCallersThread() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = SceneScriptReplayMediaSource()
        let lock = NSLock()
        var made: [Data] = []
        var onMain: [Bool] = []
        let textures = SceneMediaTextures(source: source) { png in
            lock.withLock {
                made.append(png)
                onMain.append(Thread.isMainThread)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            return device.makeTexture(descriptor: descriptor)
        }
        source.send(state(artwork: 1))
        source.send(state(artwork: 1))
        textures.waitForUploads()
        let first = try XCTUnwrap(textures.texture(.mediaThumbnail))
        XCTAssertNil(textures.texture(.mediaPreviousThumbnail))
        source.send(state(artwork: 2))
        textures.waitForUploads()
        XCTAssertTrue(textures.texture(.mediaPreviousThumbnail) === first, "the old artwork moves to the previous thumbnail")
        XCTAssertNotNil(textures.texture(.mediaThumbnail))
        XCTAssertFalse(textures.texture(.mediaThumbnail) === first)
        lock.withLock {
            XCTAssertEqual(made, [Data([1]), Data([2])], "each image is made once")
            XCTAssertFalse(onMain.contains(true))
        }
        source.send(state(artwork: nil))
        XCTAssertNil(textures.texture(.mediaThumbnail))
    }

    func testSameStorageIsIdentityNotEquality() {
        let data = Data((0..<64).map { UInt8($0) })
        XCTAssertTrue(MacMediaSessionSource.sameStorage(data, data))
        XCTAssertFalse(MacMediaSessionSource.sameStorage(data, Data(Array(data))))
    }
}
