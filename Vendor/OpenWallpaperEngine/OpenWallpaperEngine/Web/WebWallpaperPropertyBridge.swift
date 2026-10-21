import Foundation

extension Notification.Name {
    /// Posted by the sidebar when a user property changes. `object` is the wallpaper directory
    /// path; `userInfo` holds `key` and `value` (the stored string).
    static let wallpaperUserPropertyChanged = Notification.Name("WallpaperUserPropertyChanged")
}

/// Builds the JavaScript that delivers project.json user properties and audio to a web wallpaper,
/// the way Wallpaper Engine does (`window.wallpaperPropertyListener.applyUserProperties` and
/// `window.wallpaperRegisterAudioListener`).
enum WebWallpaperPropertyBridge {
    struct Property: Equatable {
        var type: String
        var defaultValue: String
        /// A combo's option values (as stored) with the JSON type the author gave each one.
        var optionKinds: [String: OptionKind] = [:]
    }

    /// The JSON type of a combo option's authored `value`: WE hands the page the option's value
    /// as authored (`"value": 3` arrives as the number 3, so a page's `case 3:` matches).
    enum OptionKind: Equatable {
        case integer, number, bool, string

        init(_ value: Any) {
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool
                } else {
                    self = CFNumberIsFloatType(number) ? .number : .integer
                }
            } else {
                self = .string
            }
        }
    }

    /// Declared properties from a project.json root object, keyed by name.
    static func declaredProperties(projectRoot: [String: Any]) -> [String: Property] {
        let raw = ((projectRoot["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
        var result: [String: Property] = [:]
        for (key, entry) in raw {
            let type = (entry["type"] as? String)?.lowercased() ?? "text"
            // Notice rows carry no value WE would deliver.
            guard type != "text", type != "group" else { continue }
            var value = entry["value"].map(sceneUserPropertyString)
            if value == nil, type == "combo",
               let first = (entry["options"] as? [[String: Any]])?.first?["value"] {
                value = sceneUserPropertyString(first)
            }
            var property = Property(type: type, defaultValue: value ?? (type == "bool" ? "false" : ""))
            if type == "combo" {
                for option in (entry["options"] as? [[String: Any]]) ?? [] {
                    guard let optionValue = option["value"] else { continue }
                    property.optionKinds[sceneUserPropertyString(optionValue)] = OptionKind(optionValue)
                }
            }
            result[key] = property
        }
        return result
    }

    static func declaredProperties(wallpaperDirectory: URL) -> [String: Property] {
        // Optional: a wallpaper without a readable project.json has no properties (its load reports why).
        guard let root = try? WEProject.json(in: wallpaperDirectory) else { return [:] }
        return declaredProperties(projectRoot: root)
    }

    /// The JSON value WE hands the page by type alone: numbers for sliders, booleans for bools, and
    /// the raw string ("r g b" for colors) otherwise. Combos go through `jsonValue(_:value:)`.
    static func jsonValue(type: String, value: String) -> Any {
        switch type {
        case "bool":
            return value.lowercased() == "true" || value == "1"
        case "slider":
            return Double(value).map { $0.rounded() == $0 && abs($0) < 1e15 ? NSNumber(value: Int64($0)) : NSNumber(value: $0) } ?? value
        case "file", "directory":
            // WE's pages prefix `file:///`; its paths start with the drive, these with no slash.
            return WebDirectoryProperty.pagePath(value)
        default:
            return value
        }
    }

    /// The JSON value of `value` for `property`: a combo's value keeps its option's authored type
    /// (a value that isn't one of the options, as an editable combo allows, stays a string).
    static func jsonValue(_ property: Property, value: String) -> Any {
        guard property.type == "combo", let kind = property.optionKinds[value] else {
            return jsonValue(type: property.type, value: value)
        }
        switch kind {
        case .integer:
            return Int64(value).map { NSNumber(value: $0) } ?? Double(value).map { NSNumber(value: $0) } ?? value
        case .number:
            return Double(value).map { NSNumber(value: $0) } ?? value
        case .bool:
            return value.lowercased() == "true" || value == "1"
        case .string:
            return value
        }
    }

    /// `{key: {value: …}}` for the given stored values (keys absent from `properties` are skipped).
    static func payload(properties: [String: Property], values: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            guard let property = properties[key] else { continue }
            result[key] = ["type": property.type, "value": jsonValue(property, value: value)]
        }
        return result
    }

    /// Stored values merged over project defaults, for every declared property.
    static func currentValues(properties: [String: Property], stored: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for (key, property) in properties {
            values[key] = stored[key] ?? property.defaultValue
        }
        return values
    }

    /// Delivers user properties through the bootstrap's listener trap. `full` is the whole set
    /// (sent once the page has loaded; the trap hands it to the listener now, or when the page
    /// assigns one later); otherwise only the changed values, which reach a listener that has
    /// already had the full set (a listener assigned later gets the merged full set instead).
    static func applyUserPropertiesScript(_ payload: [String: Any], full: Bool = false) -> String? {
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let function = full ? "__oweSetUserProperties" : "__oweApplyUserProperties"
        return "window.\(function)&&window.\(function)(\(json));"
    }

    /// WE's `wallpaperPropertyListener.setPaused(isPaused)`: the wallpaper was paused or resumed.
    static func setPausedScript(_ paused: Bool) -> String {
        """
        (function(){var l=window.wallpaperPropertyListener;\
        if(l&&typeof l.setPaused==='function'){try{l.setPaused(\(paused));}catch(e){console.error(e);}}})();
        """
    }

    /// WE's `___wpxPause()` / `___wpxUnpause()` (its `___STAHP` script), called after `setPaused`.
    static func wpxPauseScript(_ paused: Bool) -> String {
        paused ? "window.___wpxPause&&window.___wpxPause();" : "window.___wpxUnpause&&window.___wpxUnpause();"
    }

    /// Injected at document start, modelled on WE's `___STAHP` script: while paused, animation
    /// frame, interval and timeout callbacks are queued (at most 1000 each) and replayed on
    /// unpause; CSS animations, playing media and running AudioContexts are paused and only the
    /// ones it paused are resumed.
    static let pauseScript = """
    (function(){
      if (window.___wpxPause) return;
      var RAF = window.requestAnimationFrame.bind(window), INT = window.setInterval.bind(window),
          TIM = window.setTimeout.bind(window), CAP = 1000;
      var state = { isPaused: false }, pending = { raf: [], int: [], tim: [] };
      var paused = { anims: [], media: [], audio: [] }, contexts = [];
      window.___wpxRAF = RAF; window.___wpxINT = INT; window.___wpxTIM = TIM;
      var run = function(fn, args){ if (typeof fn === 'function') fn.apply(window, args); else eval(String(fn)); };
      window.requestAnimationFrame = function(fn){
        return RAF(function(t){
          if (state.isPaused) { if (pending.raf.length < CAP) pending.raf.push(fn); return; }
          fn(t);
        });
      };
      window.setInterval = function(fn, ms){
        var args = Array.prototype.slice.call(arguments, 2);
        return INT(function(){
          if (state.isPaused) { if (pending.int.length < CAP) pending.int.push([fn, args]); return; }
          run(fn, args);
        }, ms);
      };
      window.setTimeout = function(fn, ms){
        var args = Array.prototype.slice.call(arguments, 2);
        return TIM(function(){
          if (state.isPaused) { if (pending.tim.length < CAP) pending.tim.push([fn, args]); return; }
          run(fn, args);
        }, ms);
      };
      ['AudioContext', 'webkitAudioContext'].forEach(function(name){
        var Base = window[name];
        if (typeof Base !== 'function' || typeof WeakRef !== 'function') return;
        var Wrapped = function(){
          var ctx = new (Function.prototype.bind.apply(Base, [null].concat(Array.prototype.slice.call(arguments))))();
          contexts.push(new WeakRef(ctx));
          return ctx;
        };
        Wrapped.prototype = Base.prototype;
        window[name] = Wrapped;
      });
      var style = null;
      window.___wpxPause = function(){
        if (state.isPaused) return; state.isPaused = true;
        if (!style) {
          style = document.createElement('style');
          style.textContent = '.wpxPausePseudoAnimationAll,.wpxPausePseudoAnimationAll *,.wpxPausePseudoAnimationAll *::before,.wpxPausePseudoAnimationAll *::after{animation-play-state:paused!important}';
          (document.head || document.documentElement).appendChild(style);
        }
        document.documentElement.classList.add('wpxPausePseudoAnimationAll');
        if (document.getAnimations) document.getAnimations().forEach(function(a){
          if (a.playState === 'running') { a.pause(); paused.anims.push(a); }
        });
        document.querySelectorAll('video,audio').forEach(function(m){
          if (!m.paused) { m.pause(); paused.media.push(m); }
        });
        contexts = contexts.filter(function(r){
          var c = r.deref(); if (!c) return false;
          if (c.state === 'running') { c.suspend(); paused.audio.push(c); }
          return true;
        });
      };
      window.___wpxUnpause = function(){
        if (!state.isPaused) return; state.isPaused = false;
        document.documentElement.classList.remove('wpxPausePseudoAnimationAll');
        paused.anims.forEach(function(a){ try { a.play(); } catch(e) {} });
        paused.media.forEach(function(m){ try { var p = m.play(); if (p && p.catch) p.catch(function(){}); } catch(e) {} });
        paused.audio.forEach(function(c){ try { c.resume(); } catch(e) {} });
        paused = { anims: [], media: [], audio: [] };
        var raf = pending.raf, int = pending.int, tim = pending.tim;
        pending = { raf: [], int: [], tim: [] };
        raf.forEach(function(fn){ window.requestAnimationFrame(fn); });
        int.concat(tim).forEach(function(c){ try { run(c[0], c[1]); } catch(e) { console.error(e); } });
      };
    })();
    """

    static func applyGeneralPropertiesScript(fps: Int) -> String {
        "window.__oweApplyGeneralProperties&&window.__oweApplyGeneralProperties({fps:\(fps)});"
    }

    /// 128 values: 64 left then 64 right, each clamped to 0…1.
    static func audioArray(left: [Float], right: [Float]) -> [Float] {
        func band(_ values: [Float]) -> [Float] {
            (0..<64).map { index in index < values.count ? min(max(values[index], 0), 1) : 0 }
        }
        return band(left) + band(right)
    }

    static func audioDeliveryScript(_ samples: [Float]) -> String {
        let list = samples.map { value -> String in
            value == 0 ? "0" : String(format: "%.4f", value)
        }.joined(separator: ",")
        return "window.__oweDeliverAudio&&window.__oweDeliverAudio([\(list)]);"
    }

    static let audioMessageName = "oweAudioListener"
    static let frameMessageName = "oweFrameIntervals"

    /// One heartbeat message: whether the page was visible and its frame intervals since the last.
    struct Heartbeat: Equatable {
        var visible: Bool
        var intervals: [TimeInterval]
    }

    /// Decodes `{visible, intervals}`; malformed intervals are dropped, a malformed body is nil.
    static func heartbeat(from body: Any) -> Heartbeat? {
        guard let object = body as? [String: Any], let visible = object["visible"] as? Bool else { return nil }
        return Heartbeat(visible: visible, intervals: frameIntervals(from: object["intervals"] ?? []))
    }

    /// The frame intervals (seconds) a heartbeat message carries; anything malformed is dropped.
    static func frameIntervals(from body: Any) -> [TimeInterval] {
        guard let values = body as? [Any] else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.doubleValue }.filter { $0.isFinite && $0 > 0 }
    }

    /// Injected at document start: WE's audio registration and the watchdog's heartbeat. The
    /// media listeners are `WebWallpaperMediaBridge`'s.
    static let bootstrapScript = """
    (function(){
      if (window.__oweBridge) return; window.__oweBridge = true;
      var audio = [];
      window.wallpaperRegisterAudioListener = function(cb){
        if (typeof cb !== 'function') return;
        audio.push(cb);
        try { window.webkit.messageHandlers.\(audioMessageName).postMessage(audio.length); } catch(e) {}
      };
      window.__oweDeliverAudio = function(values){
        for (var i = 0; i < audio.length; i++) { try { audio[i](values); } catch(e) { console.error(e); } }
      };
      // WE hands a page its properties once it has loaded and its wallpaperPropertyListener
      // exists. A page may assign the listener late (after load, from a timer or an async
      // script), so the assignment is trapped: a listener that hasn't had the full set gets it
      // (the merged current values) the moment it is assigned; one that has gets only changes.
      var listener = window.wallpaperPropertyListener, user = null, general = null;
      var userSent = null, generalSent = null;
      var call = function(l, name, arg){
        if (l && typeof l[name] === 'function') { try { l[name](arg); } catch(e) { console.error(e); } return true; }
        return false;
      };
      var copy = function(o){ var r = {}; for (var k in o) r[k] = o[k]; return r; };
      var flush = function(){
        if (!listener) return;
        if (general && generalSent !== listener && call(listener, 'applyGeneralProperties', copy(general))) generalSent = listener;
        if (user && userSent !== listener && call(listener, 'applyUserProperties', copy(user))) userSent = listener;
      };
      try {
        Object.defineProperty(window, 'wallpaperPropertyListener', {
          configurable: true, enumerable: true,
          get: function(){ return listener; },
          set: function(value){
            listener = value; flush();
            if (window.__oweDirectoryListenerAssigned) window.__oweDirectoryListenerAssigned();
          }
        });
      } catch(e) {}
      window.__oweSetUserProperties = function(all){ user = copy(all); userSent = null; flush(); };
      window.__oweApplyUserProperties = function(changed){
        if (!user) return; // not loaded yet: the full set, read after load, carries it
        for (var k in changed) user[k] = changed[k];
        if (listener && userSent === listener) call(listener, 'applyUserProperties', changed); else flush();
      };
      window.__oweApplyGeneralProperties = function(values){
        var had = general !== null && generalSent === listener;
        general = general ? general : {};
        for (var k in values) general[k] = values[k];
        if (had && listener) call(listener, 'applyGeneralProperties', values); else flush();
      };
      // Heartbeat for the render watchdog, posted once a second: whether the page is visible and
      // its requestAnimationFrame intervals since the last post. A hidden page gets no frame
      // callbacks, so the gap across a hide is not a frame. A page whose script hangs posts
      // nothing, which the watchdog notices while the page should be visible.
      // The originals, so the heartbeat keeps its own clock when the pause script queues the page's.
      var RAF = window.___wpxRAF || window.requestAnimationFrame.bind(window);
      var INT = window.___wpxINT || window.setInterval.bind(window);
      var last = 0, intervals = [];
      document.addEventListener('visibilitychange', function(){ last = 0; });
      var beat = function(t){
        if (document.visibilityState === 'visible') { if (last) intervals.push((t - last) / 1000); last = t; }
        else { last = 0; }
        RAF(beat);
      };
      RAF(beat);
      INT(function(){
        var message = { visible: document.visibilityState === 'visible', intervals: intervals };
        try { window.webkit.messageHandlers.\(frameMessageName).postMessage(message); } catch(e) {}
        intervals = [];
      }, 1000);
    })();
    """
}
