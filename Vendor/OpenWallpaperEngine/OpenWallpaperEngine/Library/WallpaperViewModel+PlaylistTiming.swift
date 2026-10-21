import Foundation

/// When the active playlist changes wallpaper (WE's "Change wallpaper"): on a timer that stands
/// still while the wallpaper is paused (unless "Allow wallpaper to change while paused"), at each
/// time-of-day or day-of-week slot, once per login, or never. Nothing polls: one timer for the next
/// change, and the clock notifications (`PlaylistClockObserver`) for what a timer misses.
extension WallpaperViewModel {
    /// Starts the timer, or the scheduled playlist's next slot, from now.
    func restartPlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        playlistCountdown = nil
        guard persistsWallpapers, playlistEnabled, !isPlaylistSuspended, !isStopped, let playlist = activePlaylist,
              let item = playlist.items[safe: playlistIndex] else {
            playlistClockObserver = nil
            return
        }
        switch playlist.timing {
        case .timer:
            playlistClockObserver = nil
            let type = item.wallpaper.project.type.lowercased()
            if playlist.changeWhenVideoEnds && (type == "video" || type == "remote-video") { return }
            playlistCountdown = PlaylistCountdown(duration: playlist.duration)
            updatePlaylistPause()
        case .daytime, .dayofweek:
            if playlistClockObserver == nil {
                playlistClockObserver = PlaylistClockObserver { [weak self] in self?.applyPlaylistSchedule() }
            }
            let calendar = playlistCalendar()
            guard let next = PlaylistSchedule.nextBoundary(for: playlist.timing, after: playlistClock(),
                                                           ends: playlist.daytimeEnds, calendar: calendar) else { return }
            schedulePlaylistTimer(at: next) { [weak self] in self?.applyPlaylistSchedule() }
        case .logon, .never:
            playlistClockObserver = nil
        }
    }

    /// Whether the playlist's wallpaper is paused: Pause in the status menu, or the playback rules
    /// pausing or stopping every display it shows on.
    var isPlaylistPaused: Bool {
        if playRate == 0 { return true }
        let screens: Set<String> = activePlaylist?.displays.map { Set($0) } ?? selectedScreenIds
        let shown = screens.isEmpty ? selectedScreenIds : screens
        return !shown.isEmpty && shown.allSatisfy { !playback(onScreen: $0).rendersFrames }
    }

    /// Stops or runs a timer playlist's countdown as its wallpaper pauses and plays.
    func updatePlaylistPause() {
        guard var countdown = playlistCountdown, let playlist = activePlaylist else { return }
        let now = playlistClock()
        if isPlaylistPaused && !playlist.changesWhilePaused {
            countdown.pause(at: now)
        } else {
            countdown.run(at: now)
        }
        guard countdown != playlistCountdown || playlistTimer == nil else { return }
        playlistCountdown = countdown
        playlistTimer?.invalidate()
        playlistTimer = nil
        if let fireDate = countdown.fireDate {
            schedulePlaylistTimer(at: fireDate) { [weak self] in self?.advancePlaylistAutomatically() }
        }
    }

    private func schedulePlaylistTimer(at date: Date, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playlistTimer = timer
    }

    /// Shows the item a Time of day or Day of week playlist schedules now, when its slot changed
    /// since it last did (`force`: whatever it last did), and waits for the next slot.
    func applyPlaylistSchedule(force: Bool = false, transitions: Bool = true) {
        guard playlistEnabled, !isPlaylistSuspended, !isStopped, let playlist = activePlaylist,
              let scheduled = playlist.scheduledIndex(at: playlistClock(), calendar: playlistCalendar()) else { return }
        if force || scheduled != playlistScheduledIndex {
            playlistScheduledIndex = scheduled
            playlistIndex = scheduled
            showPlaylistItem(of: playlist, transitions: transitions)
        }
        restartPlaylistTimer()
    }

    /// The app started: the playlist starts as its settings say. A scheduled one shows its slot's
    /// item; "When logging in" moves on one wallpaper; "Always begin with the first wallpaper"
    /// shows the first. Nothing showed before, so nothing transitions.
    func startPlaylistAtLaunch() {
        guard playlistEnabled, !isPlaylistSuspended, let playlist = activePlaylist,
              !playlist.items.isEmpty else { return }
        if let displays = playlist.displays {
            let connected = Set(displays).intersection(connectedScreenIds())
            if !connected.isEmpty { selectedScreenIds = connected }
        }
        switch playlist.timing {
        case .daytime, .dayofweek:
            applyPlaylistSchedule(force: true, transitions: false)
        case .logon:
            playlistIndex = playlist.items.firstIndex { item in
                selectedScreenIds.contains { wallpaper(for: $0).isSameWallpaper(as: item.wallpaper) }
            } ?? playlistIndex
            withoutTransitions { advancePlaylistAutomatically() }
        case .timer where playlist.beginsWithFirst:
            playlistIndex = 0
            showPlaylistItem(of: playlist, transitions: false)
            restartPlaylistTimer()
        case .timer, .never:
            restartPlaylistTimer()
        }
    }

    /// Runs `body` with transitions off: the wallpaper windows show nothing yet to go from.
    private func withoutTransitions(_ body: () -> Void) {
        let saved = transitions
        transitions = nil
        body()
        transitions = saved
    }

    /// Changes a playlist's settings as WE's Playlist Settings dialog saves them
    /// (`WallpaperPlaylist.normalizeSettings`), then restarts its timing.
    func updatePlaylistSettings(_ playlistID: UUID? = nil, _ update: (inout WallpaperPlaylist) -> Void) {
        guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var playlist = playlists[index]
        let timing = playlist.timing
        update(&playlist)
        playlist.normalizeSettings()
        guard playlist != playlists[index] else { return }
        playlists[index] = playlist
        guard id == activePlaylistID else { return }
        if playlist.timing != timing || playlist.timing.isScheduled {
            applyPlaylistSchedule(force: playlist.timing != timing)
        }
        restartPlaylistTimer()
    }

    /// WE's limit for a day-of-week playlist: removes the wallpapers after the seventh.
    func trimToDayOfWeekLimit(_ playlistID: UUID? = nil) {
        updatePlaylistSettings(playlistID) { playlist in
            if playlist.items.count > PlaylistTiming.maxDayOfWeekItems {
                playlist.items.removeSubrange(PlaylistTiming.maxDayOfWeekItems...)
            }
        }
    }
}
