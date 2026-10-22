import Foundation
import WebKit

/// Native lock-screen output mute covers HTML media and Web Audio without
/// changing authored scripts or suspending video decoding.
@MainActor
enum WebWallpaperMutedMediaPolicy {
    static func apply(to view: WKWebView) throws {
        // WebKit's _WKMediaAudioMuted flag. This SPI is confined to the
        // experimental silent renderer and checked before use.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard view.responds(to: selector), let implementation = view.method(for: selector),
              view.responds(to: NSSelectorFromString("_mediaMutedState")) else {
            throw WebWallpaperFailure(message: "当前 WebKit 不支持锁屏网页静音播放。")
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(implementation, to: Setter.self)(view, selector, 1)
        let state = (view.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0
        guard state & 1 == 1 else {
            throw WebWallpaperFailure(message: "无法确认锁屏网页已静音。")
        }
    }
}
