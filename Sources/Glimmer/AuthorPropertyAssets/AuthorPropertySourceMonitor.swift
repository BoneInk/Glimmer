import Foundation
import CoreServices
import Darwin

/// Selected directories use one recursive FSEvents stream. Selected files use
/// O_EVTONLY on the file itself: a file grant never opens its parent directory.
@MainActor
final class AuthorPropertySourceMonitor {
    private var stream: FSEventStreamRef?
    private var box: SourceEventBox?
    private var scopedURLs: [URL] = []
    private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    private var directoryRootSources: [String: any DispatchSourceFileSystemObject] = [:]
    private var directoryCount = 0
    private var fileURLs: [String: URL] = [:]
    private var rearmTasks: [String: Task<Void, Never>] = [:]
    var isActive: Bool {
        // A root vnode source only detects root replacement, not recursive edits.
        // Never report it as a substitute for a successfully started stream.
        (directoryCount == 0 || (stream != nil && directoryRootSources.count == directoryCount))
            && (stream != nil || !fileSources.isEmpty)
    }

    init(urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) {
        var watched: Set<String> = []
        var files: [String: URL] = [:]
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            let path = SourceEventBox.canonicalPath(url.path)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { watched.insert(path) }
            else if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { files[path] = url }
        }
        let box = SourceEventBox(paths: watched.sorted(), onChange: onChange)
        self.box = box
        fileURLs = files
        for (path, url) in files { _ = installFileSource(url: url, path: path) }
        directoryCount = watched.count
        for path in watched {
            if let source = Self.createDirectoryRootSource(path: path, box: box) {
                directoryRootSources[path] = source
                source.resume()
            }
        }
        guard !watched.isEmpty else { return }
        guard let stream = Self.createStream(box: box, paths: watched.sorted()) else {
            if fileSources.isEmpty { box.stop() }; return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
        }
    }

    private func installFileSource(url: URL, path: String) -> Bool {
        guard let box else { return false }
        guard let source = Self.createFileSource(url: url, box: box, onInvalidation: { [weak self] in
            self?.rearmFile(path: path)
        }) else { return false }
        fileSources[path] = source
        source.resume()
        return true
    }

    private func rearmFile(path: String) {
        fileSources.removeValue(forKey: path)?.cancel()
        guard rearmTasks[path] == nil, let url = fileURLs[path] else { return }
        // Atomic-save replacement can invalidate the inode while keeping the
        // selected pathname. Retry only that file, never watch its parent.
        rearmTasks[path] = Task { [weak self] in
            defer { self?.rearmTasks[path] = nil }
            for attempt in 0..<3 {
                guard !Task.isCancelled, let self, self.box != nil else { return }
                if self.installFileSource(url: url, path: path) { return }
                if attempt < 2 { do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
            }
        }
    }

    private nonisolated static func createFileSource(url: URL, box: SourceEventBox,
        onInvalidation: @escaping @MainActor @Sendable () -> Void) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { close(descriptor); return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak source, weak box] in
            guard let source else { return }
            box?.notify()
            if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                Task { @MainActor in onInvalidation() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        return source
    }

    /// WatchRoot asks FSEvents to open every ancestor, beyond a selected
    /// directory grant. Observe only the selected root vnode for these events;
    /// the FSEvents stream remains responsible for recursive subtree changes.
    private nonisolated static func createDirectoryRootSource(path: String, box: SourceEventBox)
        -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            close(descriptor); return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.rename, .delete, .revoke], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak box] in box?.notify() }
        source.setCancelHandler { close(descriptor) }
        return source
    }

    // C callbacks execute on the stream queue. Defining them inside the
    // MainActor initializer inherits its isolation and traps at first event.
    private nonisolated static func createStream(box: SourceEventBox, paths: [String]) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { raw in guard let raw else { return nil }; _ = Unmanaged<SourceEventBox>.fromOpaque(raw).retain(); return UnsafeRawPointer(raw) },
            release: { raw in if let raw { Unmanaged<SourceEventBox>.fromOpaque(raw).release() } }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        return FSEventStreamCreate(nil, { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<SourceEventBox>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var relevant = false
            for index in 0..<count {
                let mustScan = eventFlags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                if mustScan || ((paths[index] as? String).map { box.matches($0) } == true) { relevant = true; break }
            }
            if relevant { box.notify() }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags)
    }

    func dispose() {
        box?.stop()
        rearmTasks.values.forEach { $0.cancel() }; rearmTasks.removeAll()
        fileSources.values.forEach { $0.cancel() }; fileSources.removeAll(); fileURLs.removeAll()
        directoryRootSources.values.forEach { $0.cancel() }; directoryRootSources.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil; box = nil
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    isolated deinit {
        box?.stop()
        rearmTasks.values.forEach { $0.cancel() }
        fileSources.values.forEach { $0.cancel() }
        directoryRootSources.values.forEach { $0.cancel() }
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}

private final class SourceEventBox: @unchecked Sendable {
    let paths: [String]
    private let callback: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    init(paths: [String], onChange: @escaping @MainActor @Sendable () -> Void) { self.paths = paths; callback = onChange }
    func matches(_ path: String) -> Bool {
        let path = Self.canonicalPath(path)
        return paths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }
    /// Removed/renamed paths may no longer resolve; canonicalize their nearest
    /// existing ancestor so /tmp and /var aliases still match deletion events.
    static func canonicalPath(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while true {
            if let pointer = realpath(ancestor.path, nil) {
                let resolved = String(cString: pointer); free(pointer)
                return suffix.reversed().reduce(URL(fileURLWithPath: resolved)) { $0.appendingPathComponent($1) }.path
            }
            guard ancestor.path != "/" else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            suffix.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func notify() {
        guard !isStopped else { return }
        Task { @MainActor [weak self] in guard let self, !self.isStopped else { return }; self.callback() }
    }
}
