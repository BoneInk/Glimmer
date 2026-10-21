import Foundation

/// Web-specific material resolution over the shared rendered-video cache.
/// Existing cache directories, keys, manifests and leases remain compatible.
@MainActor
final class WebWallpaperLockScreenVideoCache {
    typealias ExportOperation = @MainActor @Sendable (
        _ item: WallpaperItem, _ payload: Data, _ directory: URL,
        _ progress: @escaping @Sendable (String) async -> Void
    ) async throws -> URL

    private let root: URL
    private let settings: WebWallpaperLockScreenExporter.Settings
    private let exportOperation: ExportOperation?
    private let beforeWaitOperation: @MainActor @Sendable () async -> Void

    init(root: URL, settings: WebWallpaperLockScreenExporter.Settings = .init(),
         exportOperation: ExportOperation? = nil,
         beforeWaitOperation: @escaping @MainActor @Sendable () async -> Void = {}) {
        self.root = root
        self.settings = settings
        self.beforeWaitOperation = beforeWaitOperation
        self.exportOperation = exportOperation ?? { item, payload, directory, progress in
            try await WebWallpaperLockScreenExporter(settings: settings)
                .export(item: item, authorPayload: payload, directory: directory, progress: progress)
        }
    }

    func video(item: WallpaperItem, storage: AppStorage,
               progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try await cache(item: item, storage: storage).video(progress: progress)
    }

    func withVideo<Result>(item: WallpaperItem, storage: AppStorage,
                           progress: @escaping @Sendable (String) async -> Void = { _ in },
                           operation: (URL) async throws -> Result) async throws -> Result {
        try await cache(item: item, storage: storage).withVideo(progress: progress, operation: operation)
    }

    func discardOtherEntries(keeping video: URL) {
        RenderedLockScreenVideoCache.discardOtherEntries(in: root, keeping: video)
    }

    /// One material provider per call keeps the item/storage capture explicit;
    /// flights and leases are static in the shared core, so separate facade
    /// instances still coalesce on the same directory.
    private func cache(item: WallpaperItem, storage: AppStorage) -> RenderedLockScreenVideoCache {
        let coreSettings = RenderedLockScreenVideoCache.Settings(
            signature: "web-h264-v2", duration: settings.duration,
            framesPerSecond: settings.framesPerSecond,
            width: settings.width, height: settings.height)
        let exportSettings = settings
        let exportOperation = self.exportOperation
        return RenderedLockScreenVideoCache(root: root, settings: coreSettings,
            materialProvider: {
                let payload = try await WebWallpaperLockScreenConfiguration.payload(item: item, storage: storage)
                let project = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
                let projectHash = try await RenderedLockScreenVideoCache.projectHash(root: project.root)
                try Task.checkCancellation()
                return .init(identityHash: projectHash,
                             payloadHash: RenderedLockScreenVideoCache.contentHash(payload),
                             payload: payload)
            },
            exportOperation: { payload, directory, progress in
                if let exportOperation {
                    return try await exportOperation(item, payload, directory, progress)
                }
                return try await WebWallpaperLockScreenExporter(settings: exportSettings)
                    .export(item: item, authorPayload: payload, directory: directory, progress: progress)
            },
            beforeWaitOperation: beforeWaitOperation)
    }
}
