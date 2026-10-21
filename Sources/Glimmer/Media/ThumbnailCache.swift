import AppKit
import Darwin
import Foundation
import ImageIO

/// 缩略图缓存。
///
/// - 键为素材 ID；磁盘缓存位于指定的 `AppStorage.thumbnailsDirectory`
///   （应用运行时为 Application Support，自检时为临时目录，避免污染用户数据）。
/// - 同一素材的生成工作合并为一个任务；单个视图取消只移除自己的等待，
///   最后一个等待者取消时才取消生成工作。
/// - 内存缓存只保留最近使用的小尺寸位图，超出上限按 LRU 淘汰。
actor ThumbnailCache {
    typealias GenerationOperation = @Sendable (WallpaperItem, CGSize) async -> NSImage?

    /// 应用运行时使用的共享缓存。
    static let shared = ThumbnailCache(storage: AppStorage())

    private struct InFlightGeneration {
        let generation: UInt64
        let task: Task<NSImage?, Never>
        let publication: ThumbnailGenerationPublication
        var waiters: [UUID: ThumbnailWaiter]
    }

    private var memory: [UUID: NSImage] = [:]
    private var order: [UUID] = []
    private var inFlight: [UUID: InFlightGeneration] = [:]
    private var nextGeneration: UInt64 = 0
    private let memoryLimit = 160

    private let storage: AppStorage
    private let generationOperation: GenerationOperation
    private var cancelWaiterHookForTesting: (@Sendable () async -> Void)?

    init(storage: AppStorage,
         generationOperation: GenerationOperation? = nil) {
        self.storage = storage
        self.generationOperation = generationOperation ?? { item, targetSize in
            await ThumbnailCache.generateThumbnail(for: item, targetSize: targetSize)
        }
    }

    /// 轻量缓存探测：只读内存/磁盘，不启动解码工作。卡片先用它决定是否显示加载指示。
    func cachedThumbnail(for item: WallpaperItem) -> NSImage? {
        if let cached = memory[item.id] {
            touch(item.id)
            return cached
        }
        let fileURL = storage.thumbnailURL(for: item.id)
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        store(image, for: item.id)
        return image
    }

    /// 读取缩略图：内存 → 磁盘 → 共享生成任务。
    func thumbnail(
        for item: WallpaperItem,
        targetSize: CGSize = CGSize(width: 560, height: 560)
    ) async -> NSImage? {
        if let cached = cachedThumbnail(for: item) { return cached }
        guard item.fileExists else { return nil }

        let waiterID = UUID()
        let generation: UInt64
        let waiter: ThumbnailWaiter
        if var running = inFlight[item.id] {
            waiter = ThumbnailWaiter(publication: running.publication)
            running.waiters[waiterID] = waiter
            inFlight[item.id] = running
            generation = running.generation
        } else {
            nextGeneration &+= 1
            if nextGeneration == 0 { nextGeneration = 1 }
            generation = nextGeneration
            let publication = ThumbnailGenerationPublication()
            waiter = ThumbnailWaiter(publication: publication)
            let operation = generationOperation
            let task = Task.detached(priority: .utility) {
                await operation(item, targetSize)
            }
            inFlight[item.id] = InFlightGeneration(
                generation: generation, task: task, publication: publication,
                waiters: [waiterID: waiter])
            Task { [weak self] in
                let image = await task.value
                await self?.finishGeneration(
                    itemID: item.id, generation: generation, image: image,
                    persistToDisk: !item.isWebWallpaper)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
            }
        } onCancel: {
            waiter.cancel()
            Task { [weak self] in
                await self?.cancelWaiter(itemID: item.id, generation: generation, waiterID: waiterID)
            }
        }
    }

    private func finishGeneration(itemID: UUID, generation: UInt64, image: NSImage?,
                                  persistToDisk: Bool) {
        guard let running = inFlight[itemID], running.generation == generation else {
            // An invalidate/clear or a newer generation owns this key now. The
            // discarded worker must never publish its stale result.
            return
        }
        inFlight[itemID] = nil

        // Cancellation marks its waiter synchronously, before the asynchronous
        // actor cleanup runs. Claiming publication through the same gate makes
        // those paths linearizable: if every waiter has already cancelled, this
        // completion cannot write disk/memory even when it reaches the actor
        // before cancelWaiter.
        guard running.publication.claimPublication() else {
            running.waiters.values.forEach { $0.complete(nil) }
            return
        }

        if let image {
            if persistToDisk, let jpeg = image.jpegData(quality: 0.82) {
                do {
                    try FileManager.default.createDirectory(
                        at: storage.thumbnailsDirectory, withIntermediateDirectories: true)
                    try jpeg.write(to: storage.thumbnailURL(for: itemID), options: [.atomic])
                } catch {
                    // A cache write failure must not hide a successfully decoded image.
                }
            }
            store(image, for: itemID)
        }

        let result = image
        for waiter in running.waiters.values {
            waiter.complete(result)
        }
    }

    private func cancelWaiter(itemID: UUID, generation: UInt64, waiterID: UUID) async {
        if let cancelWaiterHookForTesting {
            await cancelWaiterHookForTesting()
        }
        guard var running = inFlight[itemID], running.generation == generation else { return }
        running.waiters.removeValue(forKey: waiterID)
        if running.waiters.isEmpty {
            inFlight[itemID] = nil
            running.task.cancel()
        } else {
            inFlight[itemID] = running
        }
    }

    /// Default generation path. Web posters are kept in memory only, matching the
    /// previous cache behavior. Scene posters remain preferred over the legacy renderer.
    private static func generateThumbnail(for item: WallpaperItem,
                                          targetSize: CGSize) async -> NSImage? {
        do {
            let image: NSImage?
            if item.isWebWallpaper {
                if let poster = try? WebWallpaperProjectDescriptor(projectURL: item.fileURL).posterURL {
                    image = NSImage(contentsOf: poster)
                } else {
                    image = nil
                }
            } else {
                let cgImage: CGImage
                if item.isSceneWallpaper {
                    cgImage = try await sceneThumbnail(
                        projectURL: item.fileURL, targetSize: targetSize)
                } else {
                    cgImage = try await VideoProbe.stillImage(
                        url: item.fileURL,
                        at: min(1.0, max(0.0, (item.durationSeconds ?? 2.0) * 0.15)),
                        maximumSize: targetSize
                    )
                }
                image = NSImage(cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            guard !Task.isCancelled, item.fileExists else { return nil }
            return image
        } catch {
            return nil
        }
    }

    /// Prefer the author-supplied poster even when the project uses Scene features
    /// outside the finite legacy inspector/renderer subset. The poster read and
    /// decode run off the actor, while the old renderer remains the fallback.
    private static func sceneThumbnail(projectURL: URL, targetSize: CGSize) async throws -> CGImage {
        let renderWidth = boundedDimension(targetSize.width)
        let renderHeight = boundedDimension(targetSize.height)
        let posterLimit = max(renderWidth, renderHeight)

        let posterWork = Task.detached(priority: .utility) {
            try ProjectPosterLoader.firstFrame(
                projectURL: projectURL,
                maximumPixelSize: max(1, Int(posterLimit.rounded(.up)))
            )
        }
        do {
            let image = try await withTaskCancellationHandler {
                try await posterWork.value
            } onCancel: {
                posterWork.cancel()
            }
            try Task.checkCancellation()
            return image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        let renderWork = Task.detached(priority: .utility) {
            let inspection = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: projectURL)
            return try SceneWallpaperRenderer.render(
                inspection: inspection,
                pixelSize: CGSize(width: renderWidth, height: renderHeight)
            )
        }
        return try await withTaskCancellationHandler {
            try await renderWork.value
        } onCancel: {
            renderWork.cancel()
        }
    }

    private static func boundedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(960, max(1, value))
    }

    func invalidate(id: UUID) {
        if let running = inFlight.removeValue(forKey: id) {
            running.task.cancel()
            running.waiters.values.forEach { $0.complete(nil) }
        }
        memory[id] = nil
        order.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: storage.thumbnailURL(for: id))
    }

    func clearDiskCache() {
        for running in inFlight.values {
            running.task.cancel()
            running.waiters.values.forEach { $0.complete(nil) }
        }
        inFlight.removeAll()
        memory.removeAll()
        order.removeAll()
        try? FileManager.default.removeItem(at: storage.thumbnailsDirectory)
        try? FileManager.default.createDirectory(at: storage.thumbnailsDirectory, withIntermediateDirectories: true)
    }

    func inFlightWaiterCountForTesting(id: UUID) -> Int {
        inFlight[id]?.waiters.count ?? 0
    }

    func inFlightGenerationIsCancelledForTesting(id: UUID) -> Bool? {
        inFlight[id]?.task.isCancelled
    }

    func setCancelWaiterHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        cancelWaiterHookForTesting = hook
    }

    // MARK: - 内存 LRU

    private func store(_ image: NSImage, for id: UUID) {
        memory[id] = image
        touch(id)
        while order.count > memoryLimit {
            let evicted = order.removeFirst()
            memory[evicted] = nil
        }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// Linearizes synchronous waiter cancellation with result publication. The
/// generation can claim publication only while at least one waiter is still
/// active. A waiter that has already completed does not count, even if its
/// asynchronous actor cleanup has not run yet.
private final class ThumbnailGenerationPublication: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWaiters = 0
    private var claimed = false

    func addWaiter() {
        lock.lock()
        activeWaiters += 1
        lock.unlock()
    }

    func removeWaiter() {
        lock.lock()
        if activeWaiters > 0 { activeWaiters -= 1 }
        lock.unlock()
    }

    func claimPublication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed, activeWaiters > 0 else { return false }
        claimed = true
        return true
    }
}

/// Thread-safe one-shot wake-up for a thumbnail waiter. Cancellation can race
/// with generation completion, so exactly one side is allowed to resume it.
private final class ThumbnailWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let publication: ThumbnailGenerationPublication
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var completedImage: NSImage?
    private var completed = false

    init(publication: ThumbnailGenerationPublication) {
        self.publication = publication
        publication.addWaiter()
    }

    func install(_ continuation: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        if completed {
            let image = completedImage
            lock.unlock()
            continuation.resume(returning: image)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(_ image: NSImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        completedImage = image
        let continuation = self.continuation
        self.continuation = nil
        publication.removeWaiter()
        lock.unlock()
        continuation?.resume(returning: image)
    }

    func cancel() {
        complete(nil)
    }
}

/// Reads only the author's `preview` from a bounded `project.json` and decodes its
/// first frame. This deliberately has no dependency on the Scene inspector: a
/// preview remains usable for projects the finite legacy renderer cannot support.
///
/// Paths are resolved beneath a canonical project root with `openat` plus
/// `O_NOFOLLOW` at every component. Absolute paths, traversal components and
/// symlinks are rejected before any image data is read.
enum ProjectPosterLoader {
    static let maximumProjectJSONBytes = 2_097_152
    static let maximumPreviewBytes = 33_554_432
    static let maximumSourceDimension = 16_384
    static let maximumSourcePixelCount = 67_108_864
    static let maximumOutputPixelSize = 960

    private static let readChunkBytes = 65_536
    private static let maximumRelativePathBytes = 4_096
    private static let maximumPathComponents = 32

    static func firstFrame(projectURL: URL, maximumPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard projectURL.isFileURL, projectURL.lastPathComponent == "project.json" else {
            throw ProjectPosterError.invalid("Scene poster requires a local project.json")
        }

        let rootURL = projectURL.deletingLastPathComponent()
        guard let canonicalBuffer = realpath(rootURL.path, nil) else {
            throw ProjectPosterError.invalid("Scene project root is unavailable")
        }
        defer { free(canonicalBuffer) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: canonicalBuffer), isDirectory: true)

        let rootFD = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw ProjectPosterError.invalid("Scene project root cannot be opened safely")
        }
        defer { close(rootFD) }

        let projectData = try readRegularFile(
            rootFD: rootFD,
            components: ["project.json"],
            maximumBytes: maximumProjectJSONBytes
        )
        guard let project = try JSONSerialization.jsonObject(with: projectData) as? [String: Any] else {
            throw ProjectPosterError.invalid("Scene project.json is not an object")
        }
        guard let preview = project["preview"] as? String, !preview.isEmpty else {
            throw ProjectPosterError.missingPreview
        }

        let components = try relativePathComponents(preview)
        let previewData = try readRegularFile(
            rootFD: rootFD,
            components: components,
            maximumBytes: maximumPreviewBytes
        )
        try Task.checkCancellation()
        return try decodeFirstFrame(previewData, maximumPixelSize: maximumPixelSize)
    }

    private static func relativePathComponents(_ relative: String) throws -> [String] {
        guard !relative.isEmpty,
              relative.utf8.count <= maximumRelativePathBytes,
              !relative.hasPrefix("/"),
              !relative.contains("\\"),
              !relative.contains(":"),
              !relative.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
        else {
            throw ProjectPosterError.invalid("Scene preview path must be relative and local")
        }

        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= maximumPathComponents,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ProjectPosterError.invalid("Scene preview path contains a traversal or empty component")
        }
        return parts.map(String.init)
    }

    private static func readRegularFile(rootFD: Int32, components: [String], maximumBytes: Int) throws -> Data {
        guard !components.isEmpty, maximumBytes >= 0 else {
            throw ProjectPosterError.invalid("Invalid Scene poster read request")
        }

        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else {
            throw ProjectPosterError.invalid("Scene project root cannot be duplicated")
        }
        defer { close(directoryFD) }

        for component in components.dropLast() {
            let nextFD = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(directoryFD)
            directoryFD = -1
            guard nextFD >= 0 else {
                throw ProjectPosterError.invalid("Scene preview contains unsupported path components")
            }
            directoryFD = nextFD
        }

        guard let leaf = components.last else {
            throw ProjectPosterError.invalid("Scene preview has no file name")
        }
        let fileFD = leaf.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fileFD >= 0 else {
            throw ProjectPosterError.invalid("Scene preview cannot be opened safely")
        }
        defer { close(fileFD) }

        var info = stat()
        guard fstat(fileFD, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes)
        else {
            throw ProjectPosterError.invalid("Scene poster is not a bounded regular file")
        }

        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: readChunkBytes)
        while true {
            try Task.checkCancellation()
            let remainingWithSentinel = maximumBytes - data.count + 1
            guard remainingWithSentinel > 0 else {
                throw ProjectPosterError.invalid("Scene poster exceeds its byte budget")
            }
            let requested = min(buffer.count, remainingWithSentinel)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileFD, $0.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProjectPosterError.invalid("Scene poster cannot be read")
            }
            guard data.count + count <= maximumBytes else {
                throw ProjectPosterError.invalid("Scene poster grew beyond its byte budget")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        try Task.checkCancellation()
        return data
    }

    private static func decodeFirstFrame(_ data: Data, maximumPixelSize: Int) throws -> CGImage {
        guard !data.isEmpty else {
            throw ProjectPosterError.invalid("Scene preview is empty")
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension,
              width <= maximumSourcePixelCount / height
        else {
            throw ProjectPosterError.invalid("Scene preview is invalid or exceeds the decode size limit")
        }

        let outputLimit = min(maximumOutputPixelSize, max(1, maximumPixelSize))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: outputLimit,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0,
              image.height > 0,
              max(image.width, image.height) <= outputLimit
        else {
            throw ProjectPosterError.invalid("Scene preview first frame could not be decoded within bounds")
        }
        try Task.checkCancellation()
        return image
    }
}

enum ProjectPosterError: LocalizedError, Sendable {
    case invalid(String)
    case missingPreview

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        case .missingPreview: return "Scene project.json has no preview"
        }
    }
}

private extension NSImage {
    func jpegData(quality: Double) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
