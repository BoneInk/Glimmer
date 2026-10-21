import Foundation

/// The runtime half of Chromium-feature detection, injected into WebKit pages at document start.
///
/// It reports the TypeErrors and ReferenceErrors the page raises: uncaught ones, rejected
/// promises, and errors the page catches and logs with `console.error` (WE's own bridge logs a
/// listener's error that way). WebKit's message names the expression that came back undefined
/// ("undefined is not an object (evaluating 'navigator.serial.requestPort')", "Can't find
/// variable: EyeDropper"), so a probe of a missing API that the page then uses shows up here
/// without the script changing what the page sees: nothing is defined on `navigator` or
/// `window`, so a page's own `'serial' in navigator` checks keep working. The app matches the
/// messages against `ChromiumFeatureCatalog` (`features(fromMessage:)`).
enum ChromiumFeatureProbe {
    static let messageName = "oweChromiumFeature"
    /// At most this many distinct errors are reported per page.
    static let maxReports = 50

    static let script = """
    (function(){
      if (window.__oweChromiumProbe) return; window.__oweChromiumProbe = true;
      var seen = {}, count = 0;
      var report = function(type, message){
        if (type !== 'TypeError' && type !== 'ReferenceError') return;
        message = String(message || '').slice(0, 500);
        if (seen[message] || count >= \(maxReports)) return;
        seen[message] = true; count++;
        try { window.webkit.messageHandlers.\(messageName).postMessage({ type: type, message: message }); } catch(e) {}
      };
      var fromError = function(error){
        if (error && typeof error === 'object' && typeof error.name === 'string') report(error.name, error.message);
      };
      window.addEventListener('error', function(event){
        if (event.error) { fromError(event.error); return; }
        var match = /^(?:Uncaught )?(TypeError|ReferenceError):\\s*([\\s\\S]*)$/.exec(String(event.message || ''));
        if (match) report(match[1], match[2]);
      }, true);
      window.addEventListener('unhandledrejection', function(event){ fromError(event.reason); });
      var log = console.error;
      console.error = function(){
        for (var i = 0; i < arguments.length; i++) fromError(arguments[i]);
        return log.apply(console, arguments);
      };
    })();
    """

    /// The catalog features one `{type, message}` report names.
    static func features(fromMessage body: Any) -> [String] {
        guard let object = body as? [String: Any], let type = object["type"] as? String,
              let message = object["message"] as? String else { return [] }
        return ChromiumFeatureCatalog.features(inError: type, message: message).map(\.id)
    }
}
