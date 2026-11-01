import AppKit
import Foundation

@main @MainActor
enum DisplayPlaybackPolicyIntegrationTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glimmer-Display-Policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1; print("PASS \(name)")
        }
        let storage = AppStorage(root: root.appendingPathComponent("Profile"))
        let store = VideoLibraryStore(storage: storage)
        let videoURL = root.appendingPathComponent("source.mp4")
        try await SyntheticVideoWriter.write(to: videoURL, options: .init(width: 64, height: 64, frameRate: 10, frameCount: 5))
        let item = WallpaperItem(title: "Policy video", filePath: videoURL.path)
        store.add(item); store.flush()
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let registry = DisplayRegistry(snapshot: ["A", "B"].enumerated().map { index, id in
            DisplayDescriptor(id: id, displayID: UInt32(index + 1), localizedName: id, frame: frame,
                visibleFrame: frame, backingScaleFactor: 1, isPrimary: index == 0, pixelSize: frame.size)
        })
        let playback = DesktopPlaybackController(store: store, displayRegistry: registry, storage: storage, previewOnly: true)
        let policy = GWPolicyController(settings: .init(pauseOnMaximizedWindow: true), persistenceEnabled: false)
        let playlist = GWPlaylistRotator(paths: GWPersistencePaths(root: storage.root), persistenceEnabled: false)
        let integration = AppPlaybackIntegration(store: store, playback: playback, policy: policy, playlist: playlist)
        integration.activate()
        defer { playback.tearDownAll(); playlist.stopRotation() }
        check(playback.apply(item: item, to: nil) == nil, "both real video sessions start through the production integration")
        playlist.setItems([item.id]); playlist.startRotation()
        let saved = try Data(contentsOf: storage.libraryFile)
        policy.handle(.maximizedDisplaysChanged(["A"]))
        check(!playback.session(for: "A")!.isPlaying && playback.session(for: "B")!.isPlaying,
              "covering A pauses only A through the real policy callback")
        check(!playlist.isSuspended && playlist.nextFireAt != nil, "playlist continues while B can play")
        check(try Data(contentsOf: storage.libraryFile) == saved, "automatic scoped pause never rewrites saved user intent")
        policy.handle(.maximizedDisplaysChanged(["B"]))
        check(playback.session(for: "A")!.isPlaying && !playback.session(for: "B")!.isPlaying,
              "moving coverage to B resumes A even though the aggregate reason is unchanged")
        playback.setMuted(false, displayID: "B"); playback.setRate(1.5, displayID: "B")
        check(!playback.session(for: "B")!.isPlaying, "audio and speed changes retain B's scoped suspension")
        check(playback.apply(item: item, to: ["B"]) == nil && !playback.session(for: "B")!.isPlaying,
              "replacing B's wallpaper retains its scoped suspension")
        playback.playPause(displayID: "A")
        policy.handle(.systemWillSleep); policy.handle(.systemDidWake)
        check(!playback.isPlayingAnywhere && store.settings(for: "A").isPaused,
              "wake preserves manual A pause and covered B pause")
        policy.handle(.maximizedDisplaysChanged([]))
        check(!playback.session(for: "A")!.isPlaying && playback.session(for: "B")!.isPlaying,
              "uncovering B respects A's saved manual pause")
        policy.handle(.maximizedDisplaysChanged(["A", "B"]))
        check(playlist.isSuspended && playlist.nextFireAt == nil, "covering all displays suspends rotation")
        policy.handle(.maximizedDisplaysChanged([])); playback.resumeAll()
        policy.updateSettings { $0.resumeWhenPolicyLifts = false }
        policy.handle(.maximizedDisplaysChanged(["B"])); policy.handle(.maximizedDisplaysChanged([]))
        check(playback.session(for: "A")!.isPlaying && !playback.session(for: "B")!.isPlaying && !playlist.isSuspended,
              "disabled automatic resume suppresses only B while A and rotation continue")
        playback.playPause(displayID: "A")
        check(!playback.session(for: "B")!.isPlaying, "pausing A cannot release B's manual-resume requirement")
        playback.playPause(displayID: "A")
        check(!playback.session(for: "B")!.isPlaying, "playing A cannot release B's manual-resume requirement")
        playback.playPause(displayID: "B"); playback.playPause(displayID: "B")
        check(playback.session(for: "B")!.isPlaying, "explicit per-display play clears the temporary resume suppression")
        playback.reconcileSessions(onlineDisplayIDs: ["A"], displays: registry.displays.filter { $0.id == "A" })
        policy.handle(.maximizedDisplaysChanged(["A"]))
        check(playlist.isSuspended, "a disconnected B cannot keep rotation running while A is covered")
        print("DisplayPlaybackPolicyIntegrationTests: \(checks) checks passed")
    }
}
