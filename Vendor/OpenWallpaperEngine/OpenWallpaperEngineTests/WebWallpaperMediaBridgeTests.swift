import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Web wallpapers' media listeners get WE's event shapes (`webwallpaper64.exe`, docs.wallpaperengine.io).
final class WebWallpaperMediaBridgeTests: XCTestCase {
    private let colors = ArtworkPalette.Colors(primary: SIMD3(1, 0, 0), secondary: SIMD3(0, 0.5, 1),
                                               tertiary: SIMD3(0, 1, 0), text: SIMD3(1, 1, 1), highContrast: .zero)

    func testEventShapes() {
        XCTAssertEqual(WebWallpaperMediaBridge.event(for: .status(true)).kind, "status")
        XCTAssertEqual(WebWallpaperMediaBridge.event(for: .status(true)).event["enabled"] as? Bool, true)
        XCTAssertEqual(WebWallpaperMediaBridge.event(for: .playback(.paused)).event["state"] as? Int, 2)

        let properties = MediaSessionState.Properties(title: "Song", artist: "Artist", subTitle: "", albumTitle: "Album",
                                                      albumArtist: "Band", genres: "Pop,Rock", contentType: "music")
        let (kind, event) = WebWallpaperMediaBridge.event(for: .properties(properties))
        XCTAssertEqual(kind, "properties")
        XCTAssertEqual(Set(event.keys), ["title", "subTitle", "albumArtist", "albumTitle", "artist", "genres", "contentType"])
        XCTAssertEqual(event["albumArtist"] as? String, "Band")
        XCTAssertEqual(event["contentType"] as? String, "music")

        let timeline = WebWallpaperMediaBridge.event(for: .timeline(.init(position: 12, duration: 200)))
        XCTAssertEqual(timeline.kind, "timeline")
        XCTAssertEqual(timeline.event["position"] as? Double, 12)
        XCTAssertEqual(timeline.event["duration"] as? Double, 200)
    }

    func testThumbnailIsAPNGDataURLWithHexColours() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let thumbnail = MediaSessionState.Thumbnail(artwork: 1, colors: colors, png: png)
        let (kind, event) = WebWallpaperMediaBridge.event(for: .thumbnail(thumbnail))
        XCTAssertEqual(kind, "thumbnail")
        XCTAssertEqual(event["thumbnail"] as? String, "data:image/png;base64,iVBORw==")
        XCTAssertEqual(event["primaryColor"] as? String, "#FF0000")
        XCTAssertEqual(event["secondaryColor"] as? String, "#0080FF", "upper-case hex, rounded")
        XCTAssertEqual(event["tertiaryColor"] as? String, "#00FF00")
        XCTAssertEqual(event["textColor"] as? String, "#FFFFFF")
        XCTAssertEqual(event["highContrastColor"] as? String, "#000000")
        XCTAssertNil(event["hasThumbnail"], "SceneScript's field, not the web's")

        let none = WebWallpaperMediaBridge.event(for: .thumbnail(.init())).event
        XCTAssertEqual(none["thumbnail"] as? String, "")
        XCTAssertEqual(none["primaryColor"] as? String, "#000000")
    }

    /// The bootstrap in a bare JavaScript context: registration, delivery and a late listener.
    func testPageListenersReceiveDeliveriesAndLateListenersTheLatest() throws {
        let context = try XCTUnwrap(JSContext())
        var exceptions: [String] = []
        context.exceptionHandler = { _, value in exceptions.append(value?.toString() ?? "?") }
        context.evaluateScript("""
        var window = this; var registered = [];
        window.webkit = { messageHandlers: { \(WebWallpaperMediaBridge.messageName): { postMessage: function(k){ registered.push(k); } } } };
        """)
        context.evaluateScript(WebWallpaperMediaBridge.bootstrapScript)
        context.evaluateScript("""
        var got = [];
        window.wallpaperRegisterMediaPropertiesListener(function(e){ got.push('early:' + e.title); });
        """)
        let properties = MediaSessionState.Properties(title: "Song", artist: "Artist")
        context.evaluateScript(try XCTUnwrap(WebWallpaperMediaBridge.deliveryScript(.properties(properties))))
        context.evaluateScript(try XCTUnwrap(WebWallpaperMediaBridge.deliveryScript(.playback(.playing))))
        context.evaluateScript("""
        window.wallpaperRegisterMediaPropertiesListener(function(e){ got.push('late:' + e.artist); });
        window.wallpaperRegisterMediaPlaybackListener(function(e){
          got.push('playing:' + (e.state === window.wallpaperMediaIntegration.PLAYBACK_PLAYING));
        });
        """)
        XCTAssertEqual(exceptions, [])
        XCTAssertEqual(context.evaluateScript("got.join(',')")?.toString(), "early:Song,late:Artist,playing:true")
        XCTAssertEqual(context.evaluateScript("registered.join(',')")?.toString(), "properties,properties,playback")
        XCTAssertEqual(context.evaluateScript("""
        [wallpaperMediaIntegration.PLAYBACK_STOPPED, wallpaperMediaIntegration.PLAYBACK_PLAYING,
         wallpaperMediaIntegration.PLAYBACK_PAUSED, typeof wallpaperRegisterMediaStatusListener,
         typeof wallpaperRegisterMediaThumbnailListener, typeof wallpaperRegisterMediaTimelineListener].join(',')
        """)?.toString(), "0,1,2,function,function,function")
    }
}
