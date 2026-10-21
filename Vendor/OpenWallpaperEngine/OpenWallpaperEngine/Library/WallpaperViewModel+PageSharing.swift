import Foundation

/// A clone's or stretch's web page runs once in Chromium, as WE renders a clone or span once: the
/// source display loads it and the other members mirror it (`WebPageMirrorView`). WebKit keeps a
/// page per display (`WebPageMirroring.canMirror`).
extension WallpaperViewModel {
    /// The displays whose windows show a page: enabled and not stopped by the playback rules.
    private var pageShownScreens: Set<String> {
        enabledScreens.filter { !playback(onScreen: $0).hidesWindow }
    }

    /// The display whose page `screenId` mirrors on `engine`, or nil when it loads its own.
    func pageSource(of screenId: String, engine: WebEngine) -> String? {
        guard WebPageMirroring.canMirror(engine) else { return nil }
        return layoutResolution.pageSource(of: screenId, shown: pageShownScreens)
    }

    /// The displays showing `screenId`'s page on `engine`: itself and the members mirroring it.
    func pageMembers(of screenId: String, engine: WebEngine) -> [String] {
        guard WebPageMirroring.canMirror(engine) else { return [screenId] }
        return layoutResolution.pageMembers(of: screenId, shown: pageShownScreens)
    }

    /// Whether `screenId`'s page draws: any display showing it does (`DisplayPlayback.shared`).
    func pageRendersFrames(of screenId: String, engine: WebEngine) -> Bool {
        pageMembers(of: screenId, engine: engine).contains { playback(onScreen: $0).rendersFrames }
    }

    /// Whether `screenId`'s page plays the wallpaper's sound: one of its displays is the
    /// wallpaper's audible one, so a shared page is heard once.
    func pagePlaysAudio(of screenId: String, engine: WebEngine) -> Bool {
        pageMembers(of: screenId, engine: engine).contains(where: shouldPlayAudio(on:))
    }
}
