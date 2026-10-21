import AppKit
import AVFoundation
import Foundation

@main struct VideoPlaybackPreferencesTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            checks += 1
            precondition(result, label)
        }
        func close(_ lhs: Float?, _ rhs: Float) -> Bool { abs((lhs ?? -100) - rhs) < 0.0001 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gw-video-preferences-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorage(root: root)
        try storage.prepareDirectories()
        let video = storage.mediaDirectory.appendingPathComponent("fixture.mp4")
        try await SyntheticVideoWriter.write(to: video)
        let a = WallpaperItem(title: "A", filePath: video.path)
        let b = WallpaperItem(title: "B", filePath: video.path)
        // Nil optional keys are omitted: this is the old library shape, before preferences existed.
        let old = LibraryDocument(items: [a, b])
        let oldData = try LibraryPersistence.makeEncoder().encode(old)
        check(!String(decoding: oldData, as: UTF8.self).contains("videoPlaybackPreferences"), "old JSON has no new preference key")
        try oldData.write(to: storage.libraryFile)
        let store = VideoLibraryStore(storage: storage)
        check(store.items.count == 2 && store.lastError == nil, "old library loads without quarantine")
        check(store.videoPlaybackPreferences(for: a.id) == nil, "old item inherits defaults")
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        func display(_ id: String, number: UInt32) -> DisplayDescriptor {
            DisplayDescriptor(id: id, displayID: number, localizedName: id, frame: frame,
                              visibleFrame: frame, backingScaleFactor: 1, isPrimary: number == 1,
                              pixelSize: frame.size)
        }
        let registry = DisplayRegistry(snapshot: [display("one", number: 1), display("two", number: 2)])
        store.updateSettings(for: "one") { $0 = DisplayPlaybackSettings(isPaused: false, isMuted: true, volume: 0.2, rate: 1.1, gravity: .fill) }
        store.updateSettings(for: "two") { $0 = DisplayPlaybackSettings(isPaused: true, isMuted: false, volume: 0.8, rate: 0.9, gravity: .fit) }
        let playback = DesktopPlaybackController(store: store, displayRegistry: registry, storage: storage, previewOnly: true)
        defer { playback.tearDownAll() }
        check(playback.apply(item: a, to: ["one"]) == nil, "real A AVQueuePlayer starts in isolated host")
        check(playback.apply(item: b, to: ["two"]) == nil, "real B AVQueuePlayer starts in isolated host")
        let bSettings = playback.session(for: "two")!.settings
        let preferences = VideoPlaybackPreferences(isMuted: false, volume: 0.37, rate: 1.5, gravity: .fit)
        playback.updateVideoPlaybackPreferences(preferences, itemID: a.id)
        let first = playback.session(for: "one")!
        check(first.player?.isMuted == false && close(first.player?.volume, 0.37), "A changes actual mute and volume")
        check(close(first.player?.defaultRate, 1.5) && close(first.player?.rate, 1.5), "A changes actual default and running rate")
        check(first.playerLayer?.videoGravity == .resizeAspect, "A changes actual layer gravity")
        check(playback.session(for: "two")!.settings == bSettings, "B session remains untouched")
        check(store.videoPlaybackPreferences(for: b.id) == nil, "B persisted preference remains independent")
        check(store.settings(for: "one").volume == 0.2, "wallpaper edit preserves display defaults")
        check(playback.apply(item: a, to: ["two"]) == nil, "second display applies A through effective resolver")
        check(playback.session(for: "two")!.settings.isPaused && playback.session(for: "two")!.player?.rate == 0, "screen pause wins over A preference")
        let changed = VideoPlaybackPreferences(isMuted: false, volume: 0.62, rate: 0.75, gravity: .fill)
        playback.updateVideoPlaybackPreferences(changed, itemID: a.id)
        for id in ["one", "two"] {
            let session = playback.session(for: id)!
            check(close(session.player?.volume, 0.62) && close(session.player?.defaultRate, 0.75), "A preference refreshes real player on \(id)")
            check(session.playerLayer?.videoGravity == .resizeAspectFill, "A gravity refreshes \(id)")
        }
        check(playback.session(for: "two")!.player?.rate == 0, "updating shared A keeps screen two paused")
        playback.applyPolicyState(isBlocked: true) { _ in true }
        playback.updateVideoPlaybackPreferences(preferences, itemID: a.id)
        check(playback.sessions.values.allSatisfy { $0.player?.rate == 0 }, "preferences cannot bypass policy suspension")
        check(!store.settings(for: "one").isPaused && store.settings(for: "two").isPaused, "policy does not rewrite screen user intent")
        playback.applyPolicyState(isBlocked: false) { !store.settings(for: $0).isPaused }
        check(close(playback.session(for: "one")!.player?.rate, 1.5) && playback.session(for: "two")!.player?.rate == 0, "resume uses updated rate and screen pause intent")
        playback.setVolume(0.44, displayID: "one")
        check(playback.sessions.values.allSatisfy { close($0.player?.volume, 0.44) }, "explicit current-playback volume command stays effective with override")
        check(store.settings(for: "one").volume == 0.44 && store.settings(for: "two").volume == 0.8, "explicit command changes only target screen default")
        playback.setMuted(true, displayID: "one")
        check(playback.sessions.values.allSatisfy { $0.player?.isMuted == true }, "explicit mute reaches every active instance of overridden wallpaper")
        playback.setMuted(false, displayID: "one")
        check(playback.sessions.values.allSatisfy { $0.player?.isMuted == false }, "explicit unmute is not swallowed by wallpaper override")
        playback.setRate(0.8, displayID: "one")
        check(close(first.player?.rate, 0.8) && close(playback.session(for: "two")!.player?.defaultRate, 0.8), "explicit speed reaches shared players")
        check(playback.session(for: "two")!.player?.rate == 0, "explicit speed keeps second screen paused")
        playback.setGravity(.fill, displayID: "one")
        check(playback.sessions.values.allSatisfy { $0.playerLayer?.videoGravity == .resizeAspectFill }, "explicit gravity reaches shared players")
        playback.updateVideoPlaybackPreferences(VideoPlaybackPreferences(isMuted: false, volume: 0.44, rate: 1.5, gravity: .fit), itemID: a.id)
        var defaults = store.settings(for: "one")
        defaults.volume = 0.91; defaults.rate = 2.5; defaults.gravity = .fill
        playback.updateSettings(defaults, displayID: "one")
        check(close(first.player?.volume, 0.44) && close(first.player?.defaultRate, 1.5), "full screen defaults update preserves wallpaper override")
        playback.applySettingsToAll(from: "one")
        check(playback.sessions.values.allSatisfy { close($0.player?.volume, 0.44) }, "copy display defaults does not erase wallpaper override")
        playback.resetSettings(displayID: "one")
        check(close(first.player?.volume, 0.44), "reset screen defaults preserves wallpaper override")
        store.updateSettings(for: "two") { $0.isPaused = true }
        playback.applyStoredSettingsToSessions()
        check(playback.session(for: "two")!.player?.rate == 0 && close(first.player?.volume, 0.44), "stored profile refresh resolves overrides and pause")
        store.updateAppSettings { $0.autoApplyOnLaunch = true }
        store.flush()
        let expected = store.videoPlaybackPreferences(for: a.id)
        playback.tearDownAll()
        let restored = VideoLibraryStore(storage: storage)
        check(restored.videoPlaybackPreferences(for: a.id) == expected && restored.items.count == 2, "restart reload preserves wallpaper preferences")
        let restarted = DesktopPlaybackController(store: restored, displayRegistry: registry, storage: storage, previewOnly: true)
        defer { restarted.tearDownAll() }
        restarted.restoreAssignmentsIfNeeded()
        check(restarted.sessions.count == 2 && restarted.sessions.values.allSatisfy { close($0.player?.volume, 0.44) }, "restart restores actual players through same effective resolver")
        check(restarted.session(for: "two")!.player?.rate == 0, "restart preserves screen pause")
        restarted.updateVideoPlaybackPreferences(nil, itemID: a.id)
        check(close(restarted.session(for: "one")!.player?.volume, Float(restored.settings(for: "one").volume)), "inherit reset applies screen one default")
        check(close(restarted.session(for: "two")!.player?.volume, Float(restored.settings(for: "two").volume)), "inherit reset applies screen two default")
        let isolated = DesktopPlaybackController(store: restored, displayRegistry: registry, storage: storage, previewOnly: true, writesToLibrary: false)
        defer { isolated.tearDownAll() }
        _ = isolated.apply(item: a, to: ["one"])
        let bytesBefore = try Data(contentsOf: storage.libraryFile)
        isolated.updateVideoPlaybackPreferences(changed, itemID: a.id)
        check(close(isolated.session(for: "one")!.player?.volume, 0.62), "isolated preview can update actual player")
        let bytesAfter = try Data(contentsOf: storage.libraryFile)
        check(restored.videoPlaybackPreferences(for: a.id) == nil && bytesAfter == bytesBefore, "isolated preview edits do not write library or live store")
        check(VideoPlaybackPreferences(isMuted: false, volume: .nan, rate: .infinity).volume == 1, "nonfinite preference input is normalized")
        print("VideoPlaybackPreferencesTests: \(checks) checks passed; real AVQueuePlayer/AVPlayerLayer, virtual display descriptors, temp-only library and generated video, no desktop windows")
    }
}
