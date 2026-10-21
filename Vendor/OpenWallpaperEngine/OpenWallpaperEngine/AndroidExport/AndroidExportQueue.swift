import Foundation

/// Runs an Android export's items: pre-renders one at a time (each holds the GPU), while the
/// file-only work (videos, Dynamic scenes) runs beside them, `fileConcurrency` at once. Each
/// item's progress and state, and the whole batch's, are published; `cancel()` stops what runs
/// and leaves what hasn't started. The batch lists the packages in the selection's order,
/// whatever order they finish in. Its packages go into the Android exports list
/// (`AndroidExportOutbox`) when it finishes.
@MainActor
final class AndroidExportQueue: ObservableObject {
    static let fileConcurrency = 2

    typealias Status = ExportItemStatus

    struct Entry: Identifiable, Equatable {
        var item: AndroidExportItem
        /// Where its package goes.
        var url: URL
        var status = Status.waiting
        var progress = 0.0

        var id: String { item.id }
    }

    @Published private(set) var entries: [Entry]
    let skipped: [AndroidExportBatch.Skipped]
    let folder: URL
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelled = false
    /// The Android device the export is framed for, which the Android exports list shows.
    var device: String?
    /// Whether its packages go into the Android exports list.
    private let recordsExports: Bool
    private let worker: AndroidExportWorking
    private var task: Task<AndroidExportBatch, Never>?

    /// `items` go into `folder` under unique names (`AndroidExportNaming`), avoiding `taken`
    /// (the folder's files, by default), or under `names` (a save panel's choice).
    init(items: [AndroidExportItem], skipped: [AndroidExportBatch.Skipped] = [], folder: URL,
         taken: Set<String>? = nil, names chosen: [String]? = nil, worker: AndroidExportWorking,
         recordsExports: Bool = true) {
        let names = chosen.flatMap { $0.count == items.count ? $0 : nil }
            ?? AndroidExportNaming.uniqueNames(items.map(\.wallpaper.project.displayTitle),
                                               taken: taken ?? AndroidExportNaming.existingNames(in: folder))
        entries = zip(items, names).map { Entry(item: $0, url: folder.appending(path: $1, directoryHint: .notDirectory)) }
        self.skipped = skipped
        self.folder = folder
        self.worker = worker
        self.recordsExports = recordsExports
    }

    /// The whole batch's progress, 0…1: each item counts the same.
    var progress: Double {
        guard !entries.isEmpty else { return 1 }
        return entries.map { $0.status == .waiting ? 0 : ($0.status == .running ? $0.progress : 1) }.reduce(0, +) / Double(entries.count)
    }

    /// Runs every item and returns the batch; a second call waits for the first run.
    func run() async -> AndroidExportBatch {
        if let task { return await task.value }
        isRunning = true
        let task = Task { await self.runAll() }
        self.task = task
        let batch = await task.value
        isRunning = false
        if recordsExports { AndroidExportOutbox.shared.record(batch, device: device) }
        return batch
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }

    private func runAll() async -> AndroidExportBatch {
        let gpu = entries.indices.filter { entries[$0].item.usesGPU }
        let files = entries.indices.filter { !entries[$0].item.usesGPU }
        await ExportLanes.run(gpu: gpu, files: files, fileConcurrency: Self.fileConcurrency) { await self.runEntry($0) }
        return batch
    }

    private func runEntry(_ index: Int) async {
        guard !isCancelled, !Task.isCancelled else {
            entries[index].status = .cancelled
            return
        }
        entries[index].status = .running
        let entry = entries[index]
        do {
            try await worker.export(entry.item, to: entry.url) { [weak self] value in
                guard let self, self.entries[index].status == .running else { return }
                self.entries[index].progress = min(max(value, 0), 1)
            }
            try Task.checkCancellation()
            entries[index].progress = 1
            entries[index].status = .done
        } catch is CancellationError {
            // The writer moves a package into place only when it is complete.
            entries[index].status = .cancelled
        } catch {
            OWELog.error(.app, "Android export: \(entry.item.wallpaper.wallpaperDirectory.lastPathComponent) failed: \(error)")
            entries[index].status = isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    /// The batch as it stands.
    var batch: AndroidExportBatch {
        var batch = AndroidExportBatch(folder: folder, skipped: skipped, wasCancelled: isCancelled)
        for entry in entries {
            let wallpaper = entry.item.wallpaper
            switch entry.status {
            case .done:
                let size = (try? FileManager.default.attributesOfItem(atPath: entry.url.path(percentEncoded: false))[.size] as? NSNumber)?
                    .int64Value ?? 0 // Optional: the size is shown, not needed.
                batch.outputs.append(.init(wallpaperID: entry.id, title: wallpaper.project.displayTitle,
                                           type: entry.item.kind == .video ? "video" : "scene",
                                           mode: entry.item.kind == .scene ? entry.item.options.mode : nil,
                                           url: entry.url, size: size, previewURL: wallpaper.previewURL))
            case .failed(let reason):
                batch.failed.append(.init(wallpaperID: entry.id, title: wallpaper.project.displayTitle, reason: reason))
            case .waiting, .running, .cancelled:
                break
            }
        }
        return batch
    }
}
