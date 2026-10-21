import AppKit

/// "Export More with These Settings…": the mode's device, quality and clip applied to other
/// wallpapers picked from the library (`LivePhotoBatchQueue`). The edited wallpaper keeps its own
/// crop, clip, parallax position and isolated values; the others export as authored. The Live
/// Photos go to the chosen folder and/or the Photos album, and can all be sent with AirDrop.
extension LivePhotoExportModel {
    /// What the mode's settings give the other wallpapers.
    var batchTemplate: LivePhotoBatchTemplate {
        LivePhotoBatchTemplate(device: device, quality: quality, clipLength: clip.length, clipStart: clip.start,
                               findsMotion: motionWindowIsAutomatic)
    }

    /// The batch's items for `wallpapers` (in that order, once each) and the ones skipped, with why.
    func batchPlan(_ wallpapers: [WEWallpaper]) -> (items: [LivePhotoBatchItem], skipped: [LivePhotoBatchQueue.Skipped]) {
        var items: [LivePhotoBatchItem] = []
        var skipped: [LivePhotoBatchQueue.Skipped] = []
        var seen = Set<String>()
        let template = batchTemplate
        for other in wallpapers where seen.insert(other.identityPath).inserted {
            if let reason = LivePhotoBatchQueue.skipReason(other) {
                skipped.append(.init(title: other.project.displayTitle, reason: reason))
                continue
            }
            var item = LivePhotoBatchItem(wallpaper: other, template: template)
            if other.isSameWallpaper(as: wallpaper) {
                item.settings = settings
                item.properties = exportProperties
            }
            items.append(item)
        }
        return (items, skipped)
    }

    func showBatch() {
        guard !isRendering else { return }
        isBatchPresented = true
    }

    /// Export More from the Export Settings sheet: one sheet at a time, so the batch waits for it to close.
    func showBatchAfterSheet() {
        opensBatchWhenSheetCloses = true
        sheet = nil
    }

    /// The Export Settings sheet closed.
    func sheetDidClose() {
        guard opensBatchWhenSheetCloses else { return }
        opensBatchWhenSheetCloses = false
        showBatch()
    }

    /// Exports `wallpapers` into `folder` (when given) and the Photos album (when that is on).
    func exportMore(_ wallpapers: [WEWallpaper], folder: URL?, worker: LivePhotoBatchWorking? = nil) {
        guard batch?.isRunning != true else { return }
        let plan = batchPlan(wallpapers)
        guard !plan.items.isEmpty else { return }
        batch?.removeFiles()
        batchPhotosNotice = nil
        let exporter = LivePhotoBatchExporter(folder: folder, album: savesToPhotos ? photosAlbum : nil, photos: photos)
        exporter.onPhotos = { [weak self] notice in self?.batchPhotosNotice = notice }
        LivePhotoHelper.removeStaleExports()
        let queue = LivePhotoBatchQueue(items: plan.items, skipped: plan.skipped,
                                        taken: folder.map(LivePhotoBatchQueue.takenNames(in:)) ?? [],
                                        worker: worker ?? exporter)
        batch = queue
        Task { await queue.run() }
    }

    func cancelBatch() { batch?.cancel() }

    /// The sheet closed: a running batch stops and its files leave the cache.
    func closeBatch() {
        batch?.cancel()
        batch?.removeFiles()
        batch = nil
        isBatchPresented = false
    }

    /// Sends every finished Live Photo with one AirDrop share, each photo and movie paired.
    func airDropAll() {
        guard let batch else { return }
        share(batch.airDropItems)
    }

    /// Sends one finished Live Photo with AirDrop.
    func airDrop(_ files: LivePhotoHelper.Files) {
        share(LivePhotoBatchQueue.airDropItems(files))
    }

    private func share(_ items: [URL]) {
        guard !items.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            errorMessage = String(localized: "AirDrop isn't available on this Mac.")
            return
        }
        service.perform(withItems: items)
    }

    func showBatchInFinder(folder: URL) {
        NSWorkspace.shared.open(folder)
    }
}
