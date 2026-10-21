import Foundation

/// WE's media integration for web wallpapers: `window.wallpaperRegisterMedia…Listener` and
/// `window.wallpaperMediaIntegration`, fed from the app's `MediaSessionSource`.
///
/// The shapes are WE's (`webwallpaper64.exe` and docs.wallpaperengine.io › Web › Media):
/// - status `{enabled}`; playback `{state}` with `wallpaperMediaIntegration.PLAYBACK_STOPPED/PLAYING/PAUSED`
///   = 0/1/2;
/// - properties `{title, subTitle, albumArtist, albumTitle, artist, genres, contentType}`, strings;
/// - thumbnail `{thumbnail, primaryColor, secondaryColor, tertiaryColor, textColor, highContrastColor}`:
///   the cover as a `data:image/png;base64,` URL (`wallpaper64.exe`) and each colour as `#RRGGBB`,
///   upper-case hex (`webwallpaper64.exe` `0x14000b100`: "#" then "%02X" of red, green, blue);
/// - timeline `{position, duration}` in seconds.
///
/// A page's first listener subscribes it; it then gets the current state as a script does after its
/// `init` (`MediaSessionState.initialChanges`), and every change after. A listener registered later
/// gets its kind's latest event at once. [?: without a cover, WE's web event is unknown; it gets an
/// empty `thumbnail` and black colours, as SceneScript's does.]
enum WebWallpaperMediaBridge {
    static let messageName = "oweMediaListener"

    /// Injected at document start, before the page's own scripts register their listeners.
    static let bootstrapScript = """
    (function(){
      if (window.__oweMediaBridge) return; window.__oweMediaBridge = true;
      window.wallpaperMediaIntegration = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
      var listeners = { status: [], properties: [], thumbnail: [], playback: [], timeline: [] };
      var latest = {};
      var call = function(listener, event){ try { listener(event); } catch(e) { console.error(e); } };
      var register = function(kind){
        return function(listener){
          if (typeof listener !== 'function') return;
          listeners[kind].push(listener);
          if (latest[kind]) call(listener, latest[kind]);
          try { window.webkit.messageHandlers.\(messageName).postMessage(kind); } catch(e) {}
        };
      };
      window.wallpaperRegisterMediaStatusListener = register('status');
      window.wallpaperRegisterMediaPropertiesListener = register('properties');
      window.wallpaperRegisterMediaThumbnailListener = register('thumbnail');
      window.wallpaperRegisterMediaPlaybackListener = register('playback');
      window.wallpaperRegisterMediaTimelineListener = register('timeline');
      window.__oweDeliverMedia = function(kind, event){
        latest[kind] = event;
        var list = listeners[kind] || [];
        for (var i = 0; i < list.length; i++) call(list[i], event);
      };
    })();
    """

    /// The listener kind and WE's event object for one change.
    static func event(for change: MediaSessionState.Change) -> (kind: String, event: [String: Any]) {
        switch change {
        case .status(let enabled):
            return ("status", ["enabled": enabled])
        case .playback(let playback):
            return ("playback", ["state": playback.rawValue])
        case .properties(let properties):
            return ("properties", ["title": properties.title, "subTitle": properties.subTitle,
                                   "albumArtist": properties.albumArtist, "albumTitle": properties.albumTitle,
                                   "artist": properties.artist, "genres": properties.genres,
                                   "contentType": properties.contentType])
        case .thumbnail(let thumbnail):
            let colors = thumbnail.colors
            let url = thumbnail.png.map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
            return ("thumbnail", ["thumbnail": url,
                                  "primaryColor": cssColor(colors?.primary), "secondaryColor": cssColor(colors?.secondary),
                                  "tertiaryColor": cssColor(colors?.tertiary), "textColor": cssColor(colors?.text),
                                  "highContrastColor": cssColor(colors?.highContrast)])
        case .timeline(let timeline):
            return ("timeline", ["position": timeline.position, "duration": timeline.duration])
        }
    }

    /// The script that hands one change to the page's listeners, or nil if it can't be encoded.
    static func deliveryScript(_ change: MediaSessionState.Change) -> String? {
        let (kind, event) = event(for: change)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        } catch {
            OWELog.error(.web, "The media \(kind) event can't be encoded for the page: \(error)")
            return nil
        }
        return "window.__oweDeliverMedia&&window.__oweDeliverMedia('\(kind)',\(String(decoding: data, as: UTF8.self)));"
    }

    /// `#RRGGBB` for a colour in 0…1; black for none.
    static func cssColor(_ color: SIMD3<Float>?) -> String {
        let color = color ?? .zero
        func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.x), byte(color.y), byte(color.z))
    }
}
