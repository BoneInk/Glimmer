import Cocoa
import MetalKit
import CryptoKit

enum SceneFontRegistry {
    private static let lock = NSLock()
    private static var fonts: [String: String] = [:]

    static func register(_ font: CGFont, names: [String]) {
        guard let postScriptName = CTFontCopyPostScriptName(CTFontCreateWithGraphicsFont(font, 0, nil, nil)) as String? else { return }
        lock.lock()
        for name in names where !name.isEmpty { fonts[name] = postScriptName }
        lock.unlock()
    }

    /// An installed font under the names a scene gives it (`systemfont_cambria` → Times New Roman,
    /// `SceneFontResolver.weSystemFonts`), so a user's per-layer font seeded with that name finds it.
    static func register(postScriptName: String, names: [String]) {
        lock.lock()
        for name in names where !name.isEmpty { fonts[name] = postScriptName }
        lock.unlock()
    }

    static func font(named name: String, size: CGFloat) -> NSFont? {
        lock.lock()
        let fontName = fonts[name]
        lock.unlock()
        guard let fontName else { return nil }
        return NSFont(name: fontName, size: size)
    }
}
