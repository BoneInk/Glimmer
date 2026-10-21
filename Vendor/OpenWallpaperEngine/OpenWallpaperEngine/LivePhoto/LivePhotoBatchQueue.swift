import Foundation

/// One wallpaper of the iPhone & iPad Export mode's "Export More with These Settings…": the
/// edited wallpaper with its own settings and values, or another one exported as authored with
/// the mode's device, quality and clip (`LivePhotoBatchTemplate`).
struct LivePhotoBatchItem: Identifiable, Equatable {
    var wallpaper: WEWallpaper
    /// The edited wallpaper's own settings (its crop, clip and parallax position); nil derives
    /// them from `template` for this wallpaper's size.
    var settings: LivePhotoExportSettings?
    var template: LivePhotoBatchTemplate
    /// The values the render uses: the mode's isolated store for the edited wallpaper, none (the
    /// wallpaper as authored) for the others.
    var properties: [String: String] = [:]

    var id: String { wallpaper.identityPath }
    /// A scene renders on the GPU; a video's frames are read from its file.
    var usesGPU: Bool { LivePhotoExportModel.isEligible(wallpaper) }

    static func == (lhs: LivePhotoBatchItem, rhs: LivePhotoBatchItem) -> Bool {
        lhs.id == rhs.id && lhs.settings == rhs.settings && lhs.template == rhs.template && lhs.properties == rhs.properties
    }
}

/// What the mode's settings give the other wallpapers of a batch: the device's crop centred at
/// zoom 1, the quality, the clip's length, and its start (the window with the most motion of each
/// wallpaper when the mode's clip is the automatic one).
struct LivePhotoBatchTemplate: Equatable {
    var device: DeviceModel
    var quality: LivePhotoQuality
    var clipLength: Double
    var clipStart: Double
    var findsMotion: Bool

    func settings(sceneSize: SIMD2<Double>) -> LivePhotoExportSettings {
        LivePhotoExportSettings(device: device, crop: LivePhotoCrop(sceneSize: sceneSize, outputPixels: device.pixelSize),
                                clip: LivePhotoClip(start: clipStart, length: clipLength), quality: quality)
    }
}

/// Makes one Live Photo of a batch: a protocol so the queue's tests use a fake.
@MainActor
protocol LivePhotoBatchWorking: AnyObject {
    /// Renders `item` into files named `name`, reporting 0…1; throws `CancellationError` when cancelled.
    func export(_ item: LivePhotoBatchItem, name: String, progress: @escaping @MainActor (Double) -> Void) async throws -> LivePhotoHelper.Files
}

/// Runs a Live Photo batch as the Android export runs its packages (`ExportLanes`): scenes render
/// one at a time (each holds the GPU), videos are read beside them. Each item's state and
/// progress, and the whole batch's, are published; `cancel()` stops what runs and leaves what
/// hasn't started. The files stay in the export cache, paired, for AirDrop until `removeFiles()`.
@MainActor
final class LivePhotoBatchQueue: ObservableObject {
    static let fileConcurrency = 2

    struct Entry: Identifiable, Equatable {
        var item: LivePhotoBatchItem
        /// Its files' name: the title, unique within the batch and the folder it is saved to.
        var name: String
        var status = ExportItemStatus.waiting
        var progress = 0.0
        var files: LivePhotoHelper.Files?

        var id: String { item.id }
    }

    struct Skipped: Equatable {
        var title: String
        var reason: String
    }

    @Published private(set) var entries: [Entry]
    let skipped: [Skipped]
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelled = false
    private let worker: LivePhotoBatchWorking
    private var task: Task<Void, Never>?

    /// `taken`: names already used where the batch is saved (the folder's).
    init(items: [LivePhotoBatchItem], skipped: [Skipped] = [], taken: Set<String> = [], worker: LivePhotoBatchWorking) {
        let names = Self.uniqueNames(items.map(\.wallpaper.project.displayTitle), taken: taken)
        entries = zip(items, names).map { Entry(item: $0, name: $1) }
        self.skipped = skipped
        self.worker = worker
    }

    /// The whole batch's progress, 0…1: each item counts the same.
    var progress: Double {
        guard !entries.isEmpty else { return 1 }
        return entries.map { $0.status == .waiting ? 0 : ($0.status == .running ? $0.progress : 1) }.reduce(0, +) / Double(entries.count)
    }

    func run() async {
        if let task { return await task.value }
        isRunning = true
        let task = Task {
            let gpu = entries.indices.filter { entries[$0].item.usesGPU }
            let files = entries.indices.filter { !entries[$0].item.usesGPU }
            await ExportLanes.run(gpu: gpu, files: files, fileConcurrency: Self.fileConcurrency) { await self.runEntry($0) }
        }
        self.task = task
        await task.value
        isRunning = false
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }

    private func runEntry(_ index: Int) async {
        guard !isCancelled, !Task.isCancelled else {
            entries[index].status = .cancelled
            return
        }
        entries[index].status = .running
        let entry = entries[index]
        do {
            let files = try await worker.export(entry.item, name: entry.name) { [weak self] value in
                guard let self, self.entries[index].status == .running else { return }
                self.entries[index].progress = min(max(value, 0), 1)
            }
            entries[index].files = files
            try Task.checkCancellation()
            entries[index].progress = 1
            entries[index].status = .done
        } catch is CancellationError {
            entries[index].status = .cancelled
        } catch {
            OWELog.error(.app, "Live Photo batch: \(entry.item.wallpaper.wallpaperDirectory.lastPathComponent) failed: \(error)")
            entries[index].status = isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    /// The finished Live Photos, in the batch's order.
    var exported: [LivePhotoHelper.Files] {
        entries.compactMap { $0.status == .done ? $0.files : nil }
    }

    /// What "AirDrop All" shares: every finished Live Photo as one Live Photo bundle
    /// (`LivePhotoBundle`), in the batch's order, which Photos on the receiving device imports as
    /// Live Photos.
    var airDropItems: [URL] {
        exported.flatMap(Self.airDropItems)
    }

    /// One Live Photo's AirDrop items: its bundle (else its photo, then its movie).
    static func airDropItems(_ files: LivePhotoHelper.Files) -> [URL] {
        LivePhotoBundle.airDropItems(files)
    }

    /// Removes the batch's files from the export cache (the sheet closed).
    func removeFiles() {
        for index in entries.indices {
            if let files = entries[index].files { LivePhotoHelper.remove(files) }
            entries[index].files = nil
        }
    }

    /// The names for `titles`: each a file name (`LivePhotoRenderer.fileName`), none in `taken`
    /// or used twice (compared ignoring case, as APFS does): `<title> 2`, `<title> 3`…
    static func uniqueNames(_ titles: [String], taken: Set<String>) -> [String] {
        var used = Set(taken.map { $0.lowercased() })
        return titles.map { title in
            let base = LivePhotoRenderer.fileName(title)
            var name = base
            var number = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(number)"
                number += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    /// The names a folder's Live Photo files already use (their names without the extension).
    static func takenNames(in folder: URL) -> Set<String> {
        do {
            return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                .map { ($0 as NSString).deletingPathExtension })
        } catch {
            OWELog.error(.app, "Live Photo batch: can't list \(folder.path(percentEncoded: false)): \(error)")
            return []
        }
    }

    /// Why `wallpaper` can't be made into a Live Photo; nil when it can.
    static func skipReason(_ wallpaper: WEWallpaper) -> String? {
        if LivePhotoExportModel.isEligible(wallpaper) || ScreenSaverVideoSource.isEligible(wallpaper) { return nil }
        return String(localized: "Live Photos can be made only from scenes and from MP4, M4V or MOV video files in your library.")
    }
}

extension LivePhotoHelper.Files: Equatable {
    static func == (lhs: LivePhotoHelper.Files, rhs: LivePhotoHelper.Files) -> Bool {
        lhs.directory == rhs.directory && lhs.still == rhs.still && lhs.movie == rhs.movie && lhs.identifier == rhs.identifier
    }
}
