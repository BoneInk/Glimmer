import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    /// The wallpaper of the display selected in the UI. Read only: changing wallpapers goes
    /// through `apply(_:)` (chosen by hand) or `setWallpaper(_:for:transition:)`.
    var currentWallpaper: WEWallpaper {
        wallpaper(for: selectedScreenId)
    }

    var displayedWallpaper: WEWallpaper {
        inspectedWallpaper ?? currentWallpaper
    }

    func inspect(_ wallpaper: WEWallpaper) {
        var wallpaper = wallpaper
        wallpaper.project.applyTaggedContentRating()
        inspectedWallpaper = wallpaper
        loadWorkshopDetails(of: wallpaper)
    }

    /// Looks up the Workshop item and author of the wallpaper the Details panel shows. Until a
    /// tile is inspected that is the current wallpaper, which nothing else looks up at launch.
    func loadDisplayedWorkshopDetails() {
        loadWorkshopDetails(of: displayedWallpaper)
    }

    private func loadWorkshopDetails(of wallpaper: WEWallpaper) {
        // A tile tap inspects twice (once via selectWallpaper, once from the tile itself). Clearing
        // and refetching on the second call raced the first request, and Steam rejected the
        // duplicate, so the metadata stayed empty until a later visit read it from cache.
        let isSameWallpaper = workshopDetailsDirectory == wallpaper.wallpaperDirectory
        workshopDetailsDirectory = wallpaper.wallpaperDirectory
        if !isSameWallpaper {
            inspectedWorkshopItem = nil
            inspectedAuthor = nil
        }

        let projectWorkshopId = wallpaper.project.workshopid?.rawValue
        let folderWorkshopId = wallpaper.wallpaperDirectory.lastPathComponent
        let workshopId = (projectWorkshopId?.allSatisfy(\.isNumber) == true ? projectWorkshopId : nil)
            ?? (folderWorkshopId.allSatisfy(\.isNumber) ? folderWorkshopId : nil)
        guard let workshopId else { return }
        guard inFlightWorkshopId != workshopId else { return }

        if let cachedItem = WorkshopMetadataStore.shared.item(for: workshopId) {
            inspectedWorkshopItem = cachedItem
            if let creatorId = cachedItem.creatorId,
               let cachedAuthor = SteamPlayerStore.shared.player(for: creatorId) {
                inspectedAuthor = cachedAuthor
                return
            }
        } else if isSameWallpaper, inspectedWorkshopItem != nil {
            return
        }
        inFlightWorkshopId = workshopId
        Task { [weak self] in
            defer { self?.inFlightWorkshopId = nil }
            // Optional: offline or a failed request falls back to the stored item (the service logs).
            let fetched = try? await WorkshopAPIService().getItemDetails(workshopIds: [workshopId]).first
            guard let self else { return }
            guard let item = fetched ?? WorkshopMetadataStore.shared.item(for: workshopId) else { return }
            guard self.displayedWallpaper.wallpaperDirectory.lastPathComponent == folderWorkshopId else { return }
            self.inspectedWorkshopItem = item
            if let creatorId = item.creatorId,
               let author = try? await WorkshopAPIService().getPlayerSummary(steamId: creatorId) {
                guard self.displayedWallpaper.wallpaperDirectory.lastPathComponent == folderWorkshopId else { return }
                self.inspectedAuthor = author
            }
        }
    }

    /// "Set as Wallpaper" from a menu: the wallpaper becomes the Details panel's, which then
    /// applies it as its Set Wallpaper button does.
    func inspectAndApply(_ wallpaper: WEWallpaper) {
        inspect(wallpaper)
        applyInspectedWallpaper()
    }

    func applyInspectedWallpaper() {
        let wallpaper: WEWallpaper
        do {
            wallpaper = try keepWorkshopPreview?(displayedWallpaper) ?? displayedWallpaper
        } catch {
            // Applying it from the preview cache would lose it at the next cache trim.
            OWELog.error(.workshop, "Can't keep Workshop preview \(displayedWallpaper.wallpaperDirectory.lastPathComponent): \(error)")
            NSAlert(error: error).runModal()
            return
        }
        inspectedWallpaper = wallpaper
        apply(wallpaper)
    }

    func relocateWallpapers(from sourceDirectory: URL, to destinationDirectory: URL) {
        func relocated(_ wallpaper: WEWallpaper) -> WEWallpaper {
            let path = wallpaper.wallpaperDirectory.standardizedFileURL.path
            let sourcePath = sourceDirectory.standardizedFileURL.path + "/"
            guard path.hasPrefix(sourcePath) else { return wallpaper }
            let suffix = String(path.dropFirst(sourcePath.count))
            return WEWallpaper(using: wallpaper.project, where: destinationDirectory.appending(path: suffix))
        }

        wallpapers = wallpapers.mapValues(relocated)
        recentWallpapers = recentWallpapers.map(relocated)
        inspectedWallpaper = inspectedWallpaper.map(relocated)
        saveRecents()
    }

    /// The wallpaper `screenId` (a display or a split display's region) shows: its clone's or
    /// stretch's source display's while it is in one, else its own.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[layoutResolution.source(of: screenId)] ?? Self.defaultWallpaper
    }

    /// Each display's shown wallpaper (`wallpaper(for:)`), for the displays with a selection.
    var displayedWallpapers: [String: WEWallpaper] { layoutResolution.shown(wallpapers) }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String) {
        setWallpaper(wallpaper, for: [screenId])
    }

    /// Sets `wallpaper` on `screenIds`; for a display in a clone or stretch, on its source display,
    /// so every member shows it and the members' own selections stay for when they leave; for a
    /// split display, on each of its regions.
    ///
    /// `transition`: the transition shown on the displays that change, played by `transitions`
    /// (a playlist's own, or Settings' for wallpapers chosen by hand). The change applies at once
    /// without one; with one, as soon as the outgoing pictures are captured, and before any later
    /// change.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenIds: Set<String>,
                      transition: WallpaperChangeTransition = .none) {
        transitions?.flushPending()
        let targets = layoutResolution.targets(of: screenIds)
        let apply: @MainActor () -> Void = { [weak self] in self?.assign(wallpaper, to: targets) }
        let changing = targets.filter { !self.wallpaper(for: $0).isSameWallpaper(as: wallpaper) }
        guard let transitions, !changing.isEmpty,
              let settings = transition.settings(manual: transitions.manualSettings),
              let kind = settings.pick() else {
            apply()
            return
        }
        transitions.perform(kind, duration: settings.duration, on: Set(changing), apply: apply)
    }

    private func assign(_ wallpaper: WEWallpaper, to targets: Set<String>) {
        for screenId in targets.sorted() {
            // The outgoing one too: it may have been restored at launch rather than set.
            wallpaperHistory.push(self.wallpaper(for: screenId), for: screenId)
            wallpaperHistory.push(wallpaper, for: screenId)
            wallpapers[screenId] = wallpaper
        }
        addToRecents(wallpaper)
    }

    var activePlaylist: WallpaperPlaylist? {
        playlists.first { $0.id == activePlaylistID }
    }

    func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = WallpaperPlaylist(name: trimmed)
        playlists.append(playlist)
        activePlaylistID = playlist.id
    }

    @discardableResult
    func createPlaylist(named name: String, wallpapers: [WEWallpaper]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let playlist = WallpaperPlaylist(name: trimmed,
                                          items: wallpapers
                                            .filter { $0.project != .invalid }
                                            .map { WallpaperPlaylistItem(wallpaper: $0) })
        playlists.append(playlist)
        activePlaylistID = playlist.id
        return true
    }

    func addToPlaylist(_ wallpapers: [WEWallpaper], playlistID: UUID) {
        for wallpaper in wallpapers { addToPlaylist(wallpaper, playlistID: playlistID) }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        if activePlaylistID == playlist.id { activePlaylistID = playlists.first?.id }
    }

    func addToPlaylist(_ wallpaper: WEWallpaper, playlistID: UUID? = nil) {
        guard wallpaper.project != .invalid,
              let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }),
              !playlists[index].items.contains(where: { $0.wallpaper.wallpaperDirectory == wallpaper.wallpaperDirectory }) else { return }
        // WE's limit: a day-of-week playlist has a wallpaper per day at most.
        if playlists[index].timing == .dayofweek, playlists[index].items.count >= PlaylistTiming.maxDayOfWeekItems {
            OWELog.info(.app, "Playlist \"\(playlists[index].name)\" is a day-of-week playlist with 7 wallpapers; \"\(wallpaper.project.title)\" wasn't added")
            return
        }
        playlists[index].items.append(WallpaperPlaylistItem(wallpaper: wallpaper))
    }

    func removeFromPlaylist(itemID: UUID, playlistID: UUID? = nil) {
        guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items.removeAll { $0.id == itemID }
    }

    func movePlaylistItem(itemID: UUID, offset: Int, playlistID: UUID? = nil) {
        guard let id = playlistID ?? activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == id }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let destination = itemIndex + offset
        guard playlists[playlistIndex].items.indices.contains(destination) else { return }
        playlists[playlistIndex].items.swapAt(itemIndex, destination)
    }

    /// Drag to reorder: moves the item to `destination` (an index into the items before the move,
    /// as `onMove` gives it) one Move Up or Move Down step at a time.
    func movePlaylistItem(itemID: UUID, toOffset destination: Int, playlistID: UUID? = nil) {
        guard let id = playlistID ?? activePlaylistID,
              let playlist = playlists.first(where: { $0.id == id }),
              let source = playlist.items.firstIndex(where: { $0.id == itemID }) else { return }
        let target = min(destination > source ? destination - 1 : destination, playlist.items.count - 1)
        let step = target > source ? 1 : -1
        for _ in 0..<abs(target - source) { movePlaylistItem(itemID: itemID, offset: step, playlistID: id) }
    }

    /// Renames a playlist; an empty name keeps the old one.
    func renamePlaylist(_ playlistID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].name != trimmed else { return }
        playlists[index].name = trimmed
    }

        func setPlaylistDuration(_ duration: TimeInterval, playlistID: UUID? = nil) {
          guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
          playlists[index].duration = max(duration, 1)
          restartPlaylistTimer()
        }

        func setPlaylistChangeWhenVideoEnds(_ enabled: Bool, playlistID: UUID? = nil) {
          guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
          playlists[index].changeWhenVideoEnds = enabled
          restartPlaylistTimer()
        }

        func advancePlaylistIfVideoEnds(_ wallpaper: WEWallpaper) {
          guard let playlist = activePlaylist, playlist.changeWhenVideoEnds, playlist.timing.usesTimerOptions,
              playlist.items.indices.contains(playlistIndex),
              playlist.items[playlistIndex].wallpaper.wallpaperDirectory == wallpaper.wallpaperDirectory else { return }
          advancePlaylistAutomatically()
        }

    func importVideoWallpaper(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        var destination = fileManager.wallpapersDirectory.appending(path: baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(baseName) \(suffix)")
            suffix += 1
        }
        let fileName = url.lastPathComponent
        let project = WEProject(file: fileName, preview: "preview.jpg", title: baseName, type: "video")
        let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))]) { [weak self] _, cgImage, _, _, _ in
            // AVFoundation can't decode every video it imports (WebM plays through WebKit), so a
            // missing first frame leaves the wallpaper without a preview instead of unimported.
            let previewData = cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [:]) }
            if previewData == nil { OWELog.info(.importer, "No preview frame for \(fileName); importing it without one") }
            DispatchQueue.main.async {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: url, to: destination.appending(path: fileName))
                    if let previewData { try previewData.write(to: destination.appending(path: "preview.jpg"), options: .atomic) }
                    try JSONEncoder().encode(project).write(to: WEProject.url(in: destination), options: .atomic)
                    DispatchQueue.global(qos: .utility).async {
                        WallpaperPreparation.prepareVideo(wallpaperDirectory: destination)
                    }
                } catch {
                    OWELog.error(.importer, "Failed to import video: \(error.localizedDescription)")
                }
            }
        }
    }

    func addRemoteWallpaper(from url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let pathExtension = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        let videoExtensions = ["mp4", "mov", "m4v", "webm"]
        if imageExtensions.contains(pathExtension) {
            importImageAsScene(from: url)
            return
        }
        guard videoExtensions.contains(pathExtension) else { return }
        importRemoteVideo(from: url)
    }

    /// Remote videos used to live only in memory, so the library — which lists folders on disk —
    /// never showed a tile for them. They now get a real wallpaper folder whose project.json keeps
    /// the absolute URL as its file.
    private func importRemoteVideo(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let title = baseName.isEmpty ? (url.host ?? String(localized: "Remote Video", comment: "Title of a video wallpaper added by URL")) : baseName
        var destination = fileManager.wallpapersDirectory.appending(path: title)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(title) \(suffix)")
            suffix += 1
        }
        let finalDestination = destination
        let project = WEProject(file: url.absoluteString, preview: "preview.jpg", title: title, type: "remote-video")
        do {
            try fileManager.createDirectory(at: finalDestination, withIntermediateDirectories: true)
            try JSONEncoder().encode(project)
                .write(to: WEProject.url(in: finalDestination), options: .atomic)
        } catch {
            OWELog.error(.importer, "Failed to add remote video: \(error.localizedDescription)")
            return
        }
        let wallpaper = WEWallpaper(using: project, where: finalDestination)
        setWallpaper(wallpaper, for: selectedScreenIds)
        inspect(wallpaper)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))]) { _, cgImage, _, _, _ in
            guard let cgImage,
                  let previewData = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:]) else { return }
            OWELog.attempt(.importer, "Remote video: preview of \(finalDestination.lastPathComponent)") {
                try previewData.write(to: finalDestination.appending(path: "preview.jpg"), options: .atomic)
            }
        }
    }

    /// Downloads the image and writes a minimal Wallpaper Engine scene around it, so it renders
    /// through the normal scene pipeline and the whole effect stack applies to it.
    private func importImageAsScene(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let title = baseName.isEmpty ? (url.host ?? String(localized: "Image Wallpaper", comment: "Title of an image wallpaper added by URL")) : baseName
        var destination = fileManager.wallpapersDirectory.appending(path: title)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(title) \(suffix)")
            suffix += 1
        }
        let finalDestination = destination

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), image.size.width > 0 else {
                OWELog.error(.importer, "Could not download image at \(url.absoluteString)")
                return
            }
            // The scene texture loader looks for materials/<name>.<ext>, so the bytes are stored
            // under the name the generated material references.
            let textureExtension = ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
                ? url.pathExtension.lowercased()
                : "png"
            let textureData = textureExtension == "png"
                ? (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
                : data
            let width = Int(image.size.width)
            let height = Int(image.size.height)

            let scene: [String: Any] = [
                "camera": [:],
                "general": [
                    "clearcolor": "0 0 0",
                    "orthogonalprojection": ["width": width, "height": height]
                ],
                "objects": [[
                    "id": 0,
                    "name": "Image",
                    "image": "models/image.json",
                    "origin": "\(width / 2) \(height / 2) 0",
                    "scale": "1 1 1",
                    "angles": "0 0 0",
                    "size": "\(width) \(height)",
                    "visible": true
                ]]
            ]
            let model: [String: Any] = ["material": "materials/image.json"]
            let material: [String: Any] = ["passes": [["textures": ["image"]]]]

            do {
                try fileManager.createDirectory(at: finalDestination.appending(path: "models"), withIntermediateDirectories: true)
                try fileManager.createDirectory(at: finalDestination.appending(path: "materials"), withIntermediateDirectories: true)
                try textureData.write(to: finalDestination.appending(path: "materials/image.\(textureExtension)"), options: .atomic)
                try JSONSerialization.data(withJSONObject: scene)
                    .write(to: finalDestination.appending(path: "scene.json"), options: .atomic)
                try JSONSerialization.data(withJSONObject: model)
                    .write(to: finalDestination.appending(path: "models/image.json"), options: .atomic)
                try JSONSerialization.data(withJSONObject: material)
                    .write(to: finalDestination.appending(path: "materials/image.json"), options: .atomic)
                if let preview = NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [:]) {
                    try preview.write(to: finalDestination.appending(path: "preview.jpg"), options: .atomic)
                }
                let project = WEProject(file: "scene.json", preview: "preview.jpg", title: title, type: "scene")
                try JSONEncoder().encode(project)
                    .write(to: WEProject.url(in: finalDestination), options: .atomic)

                guard let self else { return }
                let wallpaper = WEWallpaper(using: project, where: finalDestination)
                self.setWallpaper(wallpaper, for: self.selectedScreenIds)
                self.inspect(wallpaper)
            } catch {
                OWELog.error(.importer, "Failed to build image scene: \(error.localizedDescription)")
            }
        }
    }

    func setContentRating(_ rating: String, for wallpaper: WEWallpaper) {
        guard wallpaper.project.workshopid == nil else { return }
        var updated = wallpaper
        updated.project.contentrating = rating
        guard WallpaperProjectFileEdit.setLogging(["contentrating": rating], inProjectAt: updated.wallpaperDirectory) else { return }
        for key in wallpapers.keys where wallpapers[key]?.wallpaperDirectory == updated.wallpaperDirectory {
            wallpapers[key] = updated
        }
        inspect(updated)
    }

    func nextPlaylistWallpaper() {
        advancePlaylist(skippingFlagged: false)
    }

    /// Timer and video-end advances. Nobody is there to confirm a wallpaper safe restart
    /// flagged, so those are passed over instead of asking.
    func advancePlaylistAutomatically() {
        advancePlaylist(skippingFlagged: true)
    }

    private func advancePlaylist(skippingFlagged: Bool) {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        syncPlaylistIndex(with: playlist)
        let isFlagged = isFlaggedBySafeRestart
        let isSkipped = { (index: Int) -> Bool in
            // "First wallpaper played at startup only": the rotation leaves it out.
            if index == 0 && playlist.leavesOutFirstItem { return true }
            let wallpaper = playlist.items[index].wallpaper
            guard skippingFlagged, isFlagged?(wallpaper) == true else { return false }
            OWELog.info(.app, "Playlist skips \"\(wallpaper.project.title)\": flagged by safe restart")
            return true
        }
        let shown = playlistShownWallpaper(of: playlist)
        // Never the wallpaper shown now (a playlist may list a folder twice) while another can play.
        let next = playlist.nextIndex(after: playlistIndex, shuffle: playlistShuffle, repeats: playlistRepeats) { index in
            shown.map { playlist.items[index].wallpaper.isSameWallpaper(as: $0) } == true || isSkipped(index)
        } ?? playlist.nextIndex(after: playlistIndex, shuffle: playlistShuffle, repeats: playlistRepeats,
                                isSkipped: isSkipped)
        guard let next else {
            if playlistRepeats {
                OWELog.info(.app, "Playlist \"\(playlist.name)\" has nothing left to show: every item is flagged by safe restart")
            } else {
                playlistEnabled = false
            }
            return
        }
        playlistIndex = next
        showPlaylistItem(of: playlist)
        restartPlaylistTimer()
    }

    func previousPlaylistWallpaper() {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        syncPlaylistIndex(with: playlist)
        let count = playlist.items.count
        let shown = playlistShownWallpaper(of: playlist)
        // As Next: passes over items that are the wallpaper shown now, while another exists.
        var index = playlistIndex
        for _ in 0..<count {
            index = (index - 1 + count) % count
            if index == 0 && playlist.leavesOutFirstItem { continue }
            if shown.map({ playlist.items[index].wallpaper.isSameWallpaper(as: $0) }) != true { break }
        }
        playlistIndex = index
        showPlaylistItem(of: playlist)
        restartPlaylistTimer()
    }

    /// Where Next and Previous step from: the selected display's wallpaper when that is one of
    /// the playlist's items, so one applied by hand (or shown on another display before) moves
    /// the position there instead of stepping from a stale one.
    private func syncPlaylistIndex(with playlist: WallpaperPlaylist) {
        guard let screenId = steppingScreenId else { return }
        let shown = wallpaper(for: screenId)
        if playlist.items[safe: playlistIndex]?.wallpaper.isSameWallpaper(as: shown) == true { return }
        if let index = playlist.items.firstIndex(where: { $0.wallpaper.isSameWallpaper(as: shown) }) {
            playlistIndex = index
        }
    }

    /// The wallpaper a step must move away from: the selected display's, else the current item.
    private func playlistShownWallpaper(of playlist: WallpaperPlaylist) -> WEWallpaper? {
        steppingScreenId.map { wallpaper(for: $0) } ?? playlist.items[safe: playlistIndex]?.wallpaper
    }

    /// Shows the playlist's current item on the selected displays (where it is not already
    /// shown) and remembers those displays as the playlist's.
    /// `transitions`: the playlist's own transition, except where nothing showed before (the app
    /// starting).
    func showPlaylistItem(of playlist: WallpaperPlaylist, transitions: Bool = true) {
        guard let item = playlist.items[safe: playlistIndex] else { return }
        let wallpaper = item.wallpaper
        let targets = selectedScreenIds.filter { !self.wallpaper(for: $0).isSameWallpaper(as: wallpaper) }
        if !targets.isEmpty {
            setWallpaper(wallpaper, for: targets, transition: transitions ? .playlist(playlist.transition) : .none)
        }
        let displays = selectedScreenIds.sorted()
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }), playlists[index].displays != displays {
            playlists[index].displays = displays
        }
    }

    /// A playlist's global shortcut: makes it the active playlist and starts it. Rotate
    /// automatically turns on and its wallpaper shows (the first, or where it left off) on the
    /// displays it last used that are connected, else on the selected ones.
    func startPlaylist(id: UUID) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        activePlaylistID = id
        let connected = connectedScreenIds()
        let displays = Set(playlist.displays ?? []).intersection(connected)
        if !displays.isEmpty { selectedScreenIds = displays }
        if !playlist.items.isEmpty {
            // "Always begin with the first wallpaper" starts it at its first item.
            if !playlist.items.indices.contains(playlistIndex)
                || (playlist.timing.usesTimerOptions && playlist.beginsWithFirst) { playlistIndex = 0 }
            if let scheduled = playlist.scheduledIndex(at: playlistClock(), calendar: playlistCalendar()) {
                playlistIndex = scheduled
                playlistScheduledIndex = scheduled
            }
            showPlaylistItem(of: playlist)
        }
        playlistEnabled = true
    }

    func savePlaylists() {
        guard let data = OWELog.attempt(.library, "Saving playlists", { try JSONEncoder().encode(playlists) }) else { return }
        UserDefaults.app.set(data, forKey: "WallpaperPlaylists")
    }

    func savePlaylistSettings() {
        UserDefaults.app.set(activePlaylistID?.uuidString, forKey: "ActiveWallpaperPlaylist")
        UserDefaults.app.set(playlistShuffle, forKey: "WallpaperPlaylistShuffle")
        UserDefaults.app.set(playlistRepeats, forKey: "WallpaperPlaylistRepeats")
        UserDefaults.app.set(playlistEnabled, forKey: "WallpaperPlaylistEnabled")
    }

    func selectScreen(_ screenId: String, extendingSelection: Bool) {
        if extendingSelection {
            if selectedScreenIds.contains(screenId) {
                selectedScreenIds.remove(screenId)
            } else {
                selectedScreenIds.insert(screenId)
            }
        } else {
            selectedScreenIds = [screenId]
        }
        selectedScreenId = screenId
    }

    /// Whether wallpapers show on `screenId`, or on the display a region of a split is on.
    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(DisplayLayoutResolution.screen(of: screenId))
    }

    /// The enabled displays, a split one with its regions, as the playback and audio routing count
    /// them (each region is a display with its own view).
    var routedScreens: Set<String> {
        var screens = enabledScreens
        for (screen, regions) in layoutResolution.regions where enabledScreens.contains(screen) {
            screens.formUnion(regions.map(\.id))
        }
        return screens
    }

    /// Whether a running wallpaper instance (scene, video) plays its sound: each plays it once,
    /// however many displays show it (`WallpaperAudioRouting`).
    var playsInstanceAudio: Bool { audioOutputEnabled }

    /// Whether the instance `key` plays its wallpaper's sound: a wallpaper plays once, so when its
    /// displays run it as several instances (different properties), only the instance on its
    /// audible display does (`WallpaperAudioRouting.audibleInstance`).
    func playsAudio(for key: WallpaperInstanceKey) -> Bool {
        guard audioOutputEnabled else { return false }
        guard persistsWallpapers else { return true }
        let audible = WallpaperAudioRouting.audibleInstance(
            of: key.wallpaper, instanceKeys: instanceKeys, enabledScreens: audibleCandidates(of: key),
            mainScreen: NSScreen.main.map(Self.screenId(for:)))
        return audible.map { $0 == key } ?? true
    }
}
