import Foundation

/// Decides whether a web wallpaper should be posting heartbeats: only while its page says it is
/// visible, its window is on screen, the displays are awake and the playback rules don't pause
/// it. WebKit stops or throttles a page's timers otherwise, and a paused page may stop drawing, so
/// silence then is not a hang. A page the live screen saver draws (`heldForScreenSaver`) is seen
/// whatever covers its window.
struct WebHeartbeatGate: Equatable {
    var pageVisible = true
    var windowVisible = true
    var displaysAwake = true
    var playing = true
    var heldForScreenSaver = false

    var expectsHeartbeats: Bool { heldForScreenSaver || (pageVisible && windowVisible && displaysAwake && playing) }
}
