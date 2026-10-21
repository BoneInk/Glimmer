import WebKit

/// Mutes a web wallpaper's page. A `WKWebView` can't be shown in two windows, so a web wallpaper
/// keeps a page per display, and only the page on its audible display plays sound
/// (`WallpaperAudioRouting`).
///
/// WebKit mutes a whole page (media elements and Web Audio) through `_setPageMuted:`, which has no
/// public equivalent on macOS; where that is missing, the page's media elements are muted by
/// script, now and as they are added (Web Audio then still plays).
enum WebPageAudio {
    /// `_WKMediaAudioMuted`, the audio bit of `_WKMediaMutedState`.
    private static let audioMuted: UInt = 1
    private static let setPageMuted = NSSelectorFromString("_setPageMuted:")
    private static var reportedMissingMute = false

    /// Mutes or unmutes `webView`'s page.
    static func setMuted(_ muted: Bool, on webView: WKWebView) {
        if webView.responds(to: setPageMuted), let method = webView.method(for: setPageMuted) {
            typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(method, to: SetPageMuted.self)(webView, setPageMuted, muted ? audioMuted : 0)
        } else if !reportedMissingMute {
            reportedMissingMute = true
            OWELog.error(.web, "WKWebView has no _setPageMuted:; muting web wallpapers' media elements by script only")
        }
        webView.evaluateJavaScript(mediaScript(muted: muted), completionHandler: nil)
    }

    /// Mutes every media element of the page and those it adds later; unmuting restores only
    /// the elements this muted, so a page's own muted video stays muted.
    static func mediaScript(muted: Bool) -> String {
        """
        (function(){window.__oweMuted=\(muted);\
        var apply=function(){document.querySelectorAll('video,audio').forEach(function(m){\
        if(window.__oweMuted&&!m.muted){m.muted=true;m.__oweMuted=true;}\
        else if(!window.__oweMuted&&m.__oweMuted){m.muted=false;m.__oweMuted=false;}});};\
        apply();\
        if(!window.__oweMuteObserver&&document.documentElement){window.__oweMuteObserver=new MutationObserver(apply);\
        window.__oweMuteObserver.observe(document.documentElement,{childList:true,subtree:true});}})();
        """
    }
}
