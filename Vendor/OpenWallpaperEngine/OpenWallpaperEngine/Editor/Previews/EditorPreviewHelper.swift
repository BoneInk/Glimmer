import Foundation
import OWEEditor
import OWESceneEditing

/// The app's side of the editor's previews: the cache for the WE assets in use, and the renderer
/// the browsers' provider calls. While the app's background pre-warm runs (`EditorPreviewPrewarm`,
/// holding `EditorPreviewPrewarmLock`), the renderer hands its previews to it (`delegate`), so a
/// browser's tiles jump its queue; otherwise, and for whatever the pre-warm leaves, it runs this
/// app's executable with `--render-editor-previews` in this process's isolated state
/// (`EditorPreviewRenderer` renders there), reports each preview as the helper finishes it, and
/// terminates it when the task is cancelled. The helper exits with the app
/// (`HelperRunCommand.exitWithParent`).
enum EditorPreviewHelper {
    /// The folder holding every build's previews' folder (`EditorPreviewCache.root`'s parent).
    static var cachesDirectory: URL {
        AppStorageLocation.current.cachesDirectory.appending(path: "Open Wallpaper Engine", directoryHint: .isDirectory)
    }

    /// The previews' cache for the WE assets in use; nil without them. Other builds' previews are
    /// carried over and removed by the pre-warm (`EditorPreviewPrewarm`).
    static func cache() -> EditorPreviewCache? {
        guard let assets = WallpaperEngineAssets.directory else { return nil }
        return EditorPreviewCache(cachesDirectory: cachesDirectory, build: EditorPreviewCache.assetsBuild(of: assets))
    }

    /// The provider of the editor window's previews; nil without WE's assets. Each browser's open
    /// time is logged (`Editor previews: Add Effect opened in …`).
    @MainActor
    static func provider() -> EditorPreviewProvider? {
        cache().map { cache in
            EditorPreviewProvider(cache: cache,
                                  renderer: { items, finished in await render(items, cache: cache, finished: finished) },
                                  log: { OWELog.info(.ui, "Editor previews: \($0)") })
        }
    }

    /// Renders `items`, reporting each as it is done: through the pre-warm while one runs, then
    /// what is left in one helper run.
    static func render(_ items: [EditorPreviewRenderItem], cache: EditorPreviewCache,
                       finished: @escaping @Sendable (EditorPreviewSubject) -> Void) async {
        var items = items
        if !items.isEmpty, EditorPreviewPrewarmLock.isHeld(for: cache) {
            items = await delegate(items, cache: cache, finished: finished)
        }
        guard !Task.isCancelled else { return }
        await render(items, finished: finished)
    }

    /// Hands `items` to the running pre-warm (`EditorPreviewWants`) and reports each as its file
    /// appears or the pre-warm records its failure; returns the ones still missing when the
    /// pre-warm stops (finished or paused) first.
    static func delegate(_ items: [EditorPreviewRenderItem], cache: EditorPreviewCache,
                         finished: @escaping @Sendable (EditorPreviewSubject) -> Void,
                         poll: Duration = .milliseconds(200)) async -> [EditorPreviewRenderItem] {
        // Records keep whole seconds.
        let posted = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        do {
            try EditorPreviewWants(cache: cache).post(items.map(\.subject))
        } catch {
            OWELog.error(.ui, "Editor previews: can't hand \(items.count) previews to the pre-warm: \(error)")
            return items
        }
        OWELog.info(.ui, "Editor previews: \(items.count) handed to the background pre-warm")
        var waiting = items
        while !waiting.isEmpty, !Task.isCancelled {
            let records = cache.inputs()
            waiting.removeAll { item in
                let failed = records[item.subject.cacheName]?.failedAt.map { $0 >= posted } ?? false
                guard failed || cache.cachedPreview(for: item.subject) != nil else { return false }
                finished(item.subject)
                return true
            }
            guard !waiting.isEmpty, EditorPreviewPrewarmLock.isHeld(for: cache) else { break }
            try? await Task.sleep(for: poll) // Optional: cancellation ends the wait.
        }
        return waiting
    }

    /// Renders `items` in one helper run, reporting each as it is done.
    static func render(_ items: [EditorPreviewRenderItem], finished: @escaping @Sendable (EditorPreviewSubject) -> Void) async {
        guard !items.isEmpty else { return }
        let jobFile = FileManager.default.temporaryDirectory.appending(path: "owe-editor-previews-\(UUID().uuidString).json")
        // The user is looking at the browser, but the editor stays responsive.
        guard let process = HelperProcess.make([HelperRunCommand.editorPreviewArgument, jobFile.path(percentEncoded: false)],
                                               qos: .utility) else { return }
        let job = EditorPreviewJob(items: items.map {
            EditorPreviewJob.Item(subject: $0.subject, outputBase: $0.outputBase.path(percentEncoded: false))
        })
        do {
            try JSONEncoder().encode(job).write(to: jobFile)
        } catch {
            OWELog.error(.ui, "Editor previews: can't write the job file \(jobFile.path): \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: jobFile) } // Optional: the job is read at start.

        let pipe = Pipe()
        process.standardOutput = pipe
        let lines = EditorPreviewDoneLines { index in
            guard items.indices.contains(index) else { return }
            finished(items[index].subject)
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData) }
        let status: Int32?
        do {
            status = try await HelperProcess.run(process) { pipe.fileHandleForReading.readabilityHandler = nil }
        } catch {
            OWELog.error(.ui, "Editor previews: can't start the render helper: \(error)")
            status = nil
        }
        if let status, status != 0 {
            OWELog.error(.ui, "Editor previews: the render helper finished with status \(status) for \(items.count) previews")
        }
    }
}

/// Splits a helper's output into lines and reports each `done` line. Reading thread only.
final class EditorPreviewDoneLines: @unchecked Sendable {
    private var buffer = Data()
    private let report: (Int) -> Void

    init(_ report: @escaping (Int) -> Void) { self.report = report }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let index = EditorPreviewJob.doneIndex(fromLine: Substring(line)) { report(index) }
        }
    }
}
