//
//  VideoWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import AVKit
import SwiftUI
import Combine

/// One video wallpaper (AVKit path), running once for every display that shows it
/// (`WallpaperViewModel.videoInstances`): one player decodes the video, which each display's
/// `AVPlayerView` shows, and one plays its sound.
@MainActor
class VideoWallpaperViewModel: ObservableObject {
    /// Whether the soundtrack plays: the app's audio output (`WallpaperAudioRouting`).
    private var playsAudio: Bool
    private unowned let wallpaperViewModel: WallpaperViewModel

    @Published var currentWallpaper: WEWallpaper {
        didSet {
            preparePlayers(for: currentWallpaper)
            updateMusicSyncCapture()
        }
    }

    /// A copy of the video AVFoundation can play is being made (`RepairedVideoCache`).
    @Published private(set) var isPreparingVideo = false
    /// The file the players read, kept while they do: from memory, it owns the bytes.
    private var videoFile: VideoFileSource?
    /// Finds the file the players open, off the main thread.
    private var preparation: Task<Void, Never>?
    /// Identifies the preparation in flight; nil once its file is open.
    private var pendingPreparation: UUID?
    private var stopped = false
    /// The file the players have open (a repaired copy is a cache entry: `CacheLeases`).
    private var mediaLease: CacheLease?

    var playRate: Float = 0 {
        didSet {
            updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
        }
    }

    var playVolume: Float = 0 {
        didSet {
            self.player.volume = playVolume
            applyAudioVolume()
        }
    }

    /// What the displays showing this video agree on under the playback rules: it plays while any
    /// of them plays (one player serves them all, so a paused display keeps showing it moving) and
    /// is heard unless every one of them is muted, paused or stopped (`DisplayPlaybackRouting`).
    private var displayPlayback: DisplayPlayback {
        wallpaperViewModel.wallpaperPlayback(of: WallpaperInstanceKey(currentWallpaper))
    }

    /// The soundtrack's volume: the app's, or silent while the playback rules mute the video.
    private func applyAudioVolume() {
        audioPlayer.volume = displayPlayback.playsSound ? playVolume : 0
    }

    var player = WallpaperAVPlayer.make()
    private var audioPlayer = WallpaperAVPlayer.make()
    private let ownAudioTap = AudioLevelTap()
    private var cancellables = Set<AnyCancellable>()
    private var itemEndObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var musicSyncObserver: NSObjectProtocol?
    /// Keeps system audio capture on while any music sync of the current wallpaper is on.
    private var musicSyncCaptureLease: AudioCaptureLease?
    /// Samples playback once a second for the render watchdog.
    private var probe = VideoPlaybackProbe()
    private var probeTimer: Timer?

    /// Rates last handed to AVFoundation, so redundant assignments can be skipped.
    private var appliedVideoRate: Float?
    private var appliedAudioRate: Float?
    private var smoothedAudioLevel: Double = 0
    private static let rateEpsilon: Float = 0.01
    private static let audioSmoothing = 0.25

    init(wallpaper currentWallpaper: WEWallpaper, wallpaperViewModel: WallpaperViewModel) {
        self.currentWallpaper = currentWallpaper
        self.playsAudio = wallpaperViewModel.playsInstanceAudio
        self.wallpaperViewModel = wallpaperViewModel
        self.player.isMuted = true
        // The default `.pause` drops the rate to 0 at the end, and the rate cache then never sets
        // it back, so the video stopped after one pass. With `.none` it keeps its rate across the
        // seek back to the start.
        self.player.actionAtItemEnd = .none
        self.audioPlayer.actionAtItemEnd = .none
        self.audioPlayer.isMuted = !playsAudio
        // Block-based observers with a weak target, so this instance can still deinit (and stop
        // playback) when the wallpaper view is torn down instead of being kept alive forever.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        }
        musicSyncObserver = NotificationCenter.default.addObserver(forName: .videoMusicSyncAudioLevelDidChange, object: nil, queue: .main) { [weak self] notification in
            self?.videoMusicSyncAudioLevelDidChange(notification)
        }

        startPlaybackProbe()

        wallpaperViewModel.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        wallpaperViewModel.$audioPlayRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Assigning the rate directly here used to restart audio even while paused.
                self?.updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
            }
            .store(in: &cancellables)
        wallpaperViewModel.displayOptions.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel) }
            .store(in: &cancellables)
        VideoMusicSyncStore.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMusicSyncCapture() }
            .store(in: &cancellables)
        wallpaperViewModel.$playVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                self?.playVolume = volume
            }
            .store(in: &cancellables)
        wallpaperViewModel.$displayPlayback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAudioVolume()
                self?.updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
            }
            .store(in: &cancellables)
        wallpaperViewModel.$audioOutputEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.setAudioEnabled(enabled)
            }
            .store(in: &cancellables)
        playVolume = wallpaperViewModel.playVolume
        playRate = wallpaperViewModel.playRate
        preparePlayers(for: currentWallpaper)
    }

    /// Stops playback for good: no display shows the video any more.
    func stop() {
        stopped = true
        preparation?.cancel()
        preparation = nil
        pendingPreparation = nil
        isPreparingVideo = false
        cancellables.removeAll()
        musicSyncCaptureLease = nil
        probeTimer?.invalidate()
        probeTimer = nil
        player.pause()
        audioPlayer.pause()
        player.replaceCurrentItem(with: nil)
        audioPlayer.replaceCurrentItem(with: nil)
        videoFile = nil
    }

    deinit {
        preparation?.cancel()
        player.pause()
        audioPlayer.pause()
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let musicSyncObserver { NotificationCenter.default.removeObserver(musicSyncObserver) }
        probeTimer?.invalidate()
    }

    private func updateMusicSyncCapture() {
        let needed = VideoMusicSyncSettings.isAnyEnabled(currentWallpaper)
        guard needed != (musicSyncCaptureLease != nil) else { return }
        musicSyncCaptureLease = needed ? WallpaperServices.shared.acquireAudioCapture() : nil
    }

    // MARK: - Watchdog

    private func startPlaybackProbe() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePlayback() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func samplePlayback() {
        guard let watchdog = wallpaperViewModel.renderWatchdog, let item = player.currentItem else { return }
        // Optional: an item keeps no access log until playback starts.
        let events = item.accessLog()?.events.filter { $0.numberOfDroppedVideoFrames >= 0 } ?? []
        let video = item.tracks.first { $0.assetTrack?.mediaType == .video }
        let sample = VideoPlaybackProbe.Sample(
            time: CACurrentMediaTime(), mediaTime: item.currentTime().seconds, rate: player.rate,
            droppedFrames: events.isEmpty ? nil : events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames },
            frameRate: Double(video?.currentVideoFrameRate ?? 0))
        if let duration = probe.frameDuration(after: sample) { watchdog.recordFrame(duration: duration) }
    }

    func setAudioEnabled(_ enabled: Bool) {
        playsAudio = enabled
        player.isMuted = true
        audioPlayer.isMuted = !enabled
        updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
    }

    /// The wallpaper's own soundtrack drives music sync whenever you can actually hear it;
    /// otherwise sync follows whatever else is playing on the system.
    var musicSyncLevel: Double {
        !audioPlayer.isMuted && audioPlayer.volume > 0 && ownAudioTap.isMeasuring
            ? ownAudioTap.level
            : WallpaperServices.shared.audioLevel
    }

    func updatePlaybackRates(audioLevel: Double) {
        let paceAmount = VideoMusicSyncSettings.bool(currentWallpaper, "paceEnabled")
            ? VideoMusicSyncSettings.double(currentWallpaper, "paceAmount", default: 0.25)
            : 0
        // The raw level is per-sample noisy; pacing straight off it reads as stutter rather than
        // a pulse. Smoothing is skipped when pacing is off so play/pause stays instant.
        let level = musicSyncLevel
        if paceAmount > 0 {
            smoothedAudioLevel += (level - smoothedAudioLevel) * Self.audioSmoothing
        } else {
            smoothedAudioLevel = level
        }
        // A paused wallpaper stays paused; pacing only modulates a video that is playing. The
        // wallpaper's own playback rate (WE's per-wallpaper option) scales the app's.
        let displayRate = wallpaperViewModel.displayPlaybackRate(of: currentWallpaper)
        // Held for the screen saver: the picture plays at the wallpaper's speed (the last one
        // while paused), silent, whatever the rules and the windows covering it say.
        if heldForScreenSaver {
            let speed = playRate > 0 ? playRate : (wallpaperViewModel.lastPlayRate > 0 ? wallpaperViewModel.lastPlayRate : 1)
            setVideoRate(speed * displayRate)
            setAudioRate(0)
            return
        }
        let rate = displayPlayback.rendersFrames ? playRate * displayRate : 0
        setVideoRate(rate > 0 ? max(0, rate + Float(smoothedAudioLevel * paceAmount)) : 0)
        // Audio runs on a second player, so a paused wallpaper keeps playing sound unless the
        // pause is applied here too.
        setAudioRate(playsAudio && !audioPlayer.isMuted && rate > 0 ? wallpaperViewModel.audioPlayRate * displayRate : 0)
    }

    /// The live screen saver draws this video's frames (`ScreenSaverVideoSharing`): it plays,
    /// silent, while the screen saver runs.
    private(set) var heldForScreenSaver = false

    /// Assigning `AVPlayer.rate` restarts the timebase, so doing it on every audio sample stutters
    /// the video and pitches the audio. Only meaningful changes are forwarded.
    private func setVideoRate(_ rate: Float) {
        if let applied = appliedVideoRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedVideoRate = rate
        player.rate = rate
    }

    private func setAudioRate(_ rate: Float) {
        if let applied = appliedAudioRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedAudioRate = rate
        audioPlayer.rate = rate
    }

    private func playerDidFinishPlaying(_ notification: Notification) {
        wallpaperViewModel.advancePlaylistIfVideoEnds(currentWallpaper)
        probe.reset()
        self.player.seek(to: CMTime.zero)
        self.audioPlayer.seek(to: CMTime.zero)
        // Whatever the players' rates are now, reapply the wanted ones.
        appliedVideoRate = nil
        appliedAudioRate = nil
        updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
    }

    private func systemWillSleep() {
        setVideoRate(0)
        setAudioRate(0)
    }

    private func systemDidWake() {
        updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
    }

    private func videoMusicSyncAudioLevelDidChange(_ notification: Notification) {
        let level = notification.userInfo?["level"] as? Double ?? WallpaperServices.shared.audioLevel
        updatePlaybackRates(audioLevel: level)
    }

    private func observeItemEnd(of item: AVPlayerItem?) {
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            self?.playerDidFinishPlaying(notification)
        }
    }

    /// Opens the wallpaper's video in the players once the file to open is known: a video whose
    /// track AVFoundation refuses as it is plays from its repaired copy, which is made first when
    /// it doesn't exist yet (a few seconds, shown as "Preparing video…").
    ///
    /// WE's "Video loading" set to in memory reads the file into memory here too, off the main
    /// thread (`VideoFileSource`).
    private func preparePlayers(for wallpaper: WEWallpaper) {
        preparation?.cancel()
        pendingPreparation = nil
        isPreparingVideo = false
        let source = wallpaper.mediaURL
        let readMode = wallpaperViewModel.videoReadMode
        guard RepairedVideoCache.mayNeedRepair(source) || readMode == .inMemory else {
            replacePlayers(with: VideoFileSource(url: source, mode: .fromDisk))
            return
        }
        let cache = RepairedVideoCache.current
        let id = UUID()
        pendingPreparation = id
        preparation = Task { [weak self] in
            let file = await Task.detached(priority: .userInitiated) {
                let url = cache.playableURL(for: source) {
                    Task { @MainActor [weak self] in
                        guard let self, self.pendingPreparation == id else { return }
                        self.isPreparingVideo = true
                    }
                }
                return VideoFileSource(url: url, mode: readMode)
            }.value
            guard let self, !Task.isCancelled, !self.stopped, self.pendingPreparation == id else { return }
            self.pendingPreparation = nil
            self.isPreparingVideo = false
            self.replacePlayers(with: file)
        }
    }

    private func replacePlayers(with file: VideoFileSource) {
        let url = file.url
        videoFile = file
        mediaLease = CacheLeases.current.lease(url)
        // New AVPlayers start at rate 0, so the cached values no longer describe them.
        appliedVideoRate = nil
        appliedAudioRate = nil
        probe.reset()
        let videoItem = file.makeItem()
        let audioItem = file.makeItem()
        audioItem.audioTimePitchAlgorithm = .timeDomain

        player.replaceCurrentItem(with: videoItem)
        audioPlayer.replaceCurrentItem(with: audioItem)
        player.isMuted = true
        audioPlayer.isMuted = !playsAudio
        ownAudioTap.attach(to: audioItem)
        observeItemEnd(of: videoItem)
        updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
    }
}

extension VideoWallpaperViewModel: ScreenSaverVideoSharing {
    var sharedPlayer: AVPlayer { player }

    func holdForScreenSaver(_ hold: Bool) {
        guard hold != heldForScreenSaver else { return }
        heldForScreenSaver = hold
        updatePlaybackRates(audioLevel: WallpaperServices.shared.audioLevel)
    }
}
