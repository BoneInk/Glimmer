import Foundation
import WebKit

/// Native page output mute covers HTML media and Web Audio without
/// changing authored scripts or suspending video decoding.
@MainActor
enum WebWallpaperMutedMediaPolicy {
    static func apply(to view: WKWebView) throws {
        try setMuted(true, on: view)
    }

    static func setMuted(_ muted: Bool, on view: WKWebView) throws {
        // WebKit's _WKMediaAudioMuted flag. This SPI is confined to the
        // page audio adapter and checked before use.
        let selector = NSSelectorFromString("_setPageMuted:")
        let getter = NSSelectorFromString("_mediaMutedState")
        guard view.responds(to: selector), let implementation = view.method(for: selector),
              view.responds(to: getter), let getterImplementation = view.method(for: getter) else {
            throw WebWallpaperFailure(message: "当前 WebKit 不支持网页声音控制。")
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        let read = unsafeBitCast(getterImplementation, to: Getter.self)
        let current = read(view, getter)
        let target = muted ? current | 1 : current & ~UInt(1)
        unsafeBitCast(implementation, to: Setter.self)(view, selector, target)
        guard read(view, getter) == target else {
            throw WebWallpaperFailure(message: "无法确认网页声音设置已生效。")
        }
    }
}
