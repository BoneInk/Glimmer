import CoreServices
import Foundation

/// Watches a folder's whole tree with FSEvents and reports its matching files after each change,
/// as WE's directory listener does with `FindFirstChangeNotificationW`. Listing runs on a
/// background queue; `onChange` gets the full listing on the main queue (first right after
/// `start`, then after every burst of changes).
final class WebDirectoryWatcher: @unchecked Sendable {
    let folder: URL
    let fileType: WebDirectoryProperty.FileType
    /// How long FSEvents gathers a burst of changes before reporting it.
    static let latency: CFTimeInterval = 0.3

    private let queue = DispatchQueue(label: "app.openwallpaperengine.web-directory", qos: .utility)
    private let onChange: @MainActor ([String: Date]) -> Void
    // Touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var stopped = false
    /// Main thread only: `stop` was called, so listings still on their way are dropped.
    private var reporting = true

    init(folder: URL, fileType: WebDirectoryProperty.FileType, onChange: @escaping @MainActor ([String: Date]) -> Void) {
        self.folder = folder
        self.fileType = fileType
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<WebDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().rescan()
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            if let stream = FSEventStreamCreate(nil, callback, &context, [folder.path(percentEncoded: false)] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) {
                FSEventStreamSetDispatchQueue(stream, queue)
                if FSEventStreamStart(stream) {
                    self.stream = stream
                } else {
                    OWELog.error(.web, "Failed creating directory listener for: \(folder.lastPathComponent)")
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                }
            } else {
                OWELog.error(.web, "Failed creating directory listener for: \(folder.lastPathComponent)")
            }
            rescan()
        }
    }

    /// Stops watching (main thread); nothing is reported afterwards. The stream is released on the
    /// queue, after any callback in flight.
    @MainActor
    func stop() {
        reporting = false
        queue.async { [self] in
            stopped = true
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// On `queue`.
    private func rescan() {
        guard !stopped else { return }
        let files = WebDirectoryProperty.files(in: folder, type: fileType)
        DispatchQueue.main.async { [weak self, onChange] in
            guard let self, self.reporting else { return }
            MainActor.assumeIsolated { onChange(files) }
        }
    }
}
