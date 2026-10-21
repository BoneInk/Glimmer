import Foundation
import OWESceneEditing

/// One preview to render: what it shows, and where its file goes (without its extension, which
/// the renderer picks: `.heic` for a still, `.mov` for a loop).
public struct EditorPreviewRenderItem: Hashable, Sendable {
    public let subject: EditorPreviewSubject
    public let outputBase: URL

    public init(subject: EditorPreviewSubject, outputBase: URL) {
        self.subject = subject
        self.outputBase = outputBase
    }
}

/// The previews of the effect and particle browsers: each one is read from the cache
/// (`EditorPreviewCache`), else rendered the first time a tile asks for it, off the main thread
/// (the app renders them in its helper process, one batch at a time), then cached for the
/// assets' build. A tile shows a spinner meanwhile.
///
/// Each browser's open is measured (`beginOpen`, `endOpen`): from the browser appearing until
/// every tile it showed meanwhile has its preview (or its symbol), logged once through `log` with
/// how many were cached, rendered or failed, so a cold open can be compared across builds.
@MainActor
public final class EditorPreviewProvider: ObservableObject {
    /// The browsers whose opens are measured; the raw value names them in the log.
    public enum Browser: String, Sendable {
        case effects = "Add Effect"
        case particleSystems = "Add Particle System"
    }

    public enum State: Equatable, Sendable {
        case generating
        case ready(URL)
        /// It couldn't be rendered; the tile shows its symbol. Tried again in the next window.
        case failed
    }

    /// Renders `items` in order, calling `finished` for each one as its file is written or it
    /// failed; returns when all are done (or the task is cancelled).
    public typealias Renderer = @Sendable (_ items: [EditorPreviewRenderItem],
                                           _ finished: @escaping @Sendable (EditorPreviewSubject) -> Void) async -> Void

    @Published public private(set) var states: [EditorPreviewSubject: State] = [:]
    public let cache: EditorPreviewCache
    private let renderer: Renderer
    /// Asked for and not yet in a batch, in the order they were asked for.
    private var queue: [EditorPreviewSubject] = []
    private var worker: Task<Void, Never>?
    private let log: @MainActor (String) -> Void
    private let now: @MainActor () -> Date
    /// The browser open being measured, until its tiles are all shown.
    private var opening: Opening?

    /// One browser open: when it started and its tiles, by how each was shown.
    private struct Opening {
        let browser: Browser
        let started: Date
        var waiting: Set<EditorPreviewSubject> = []
        var shown: Set<EditorPreviewSubject> = []
        var cached = 0
        var rendered = 0
        var failed = 0
    }

    public init(cache: EditorPreviewCache, renderer: @escaping Renderer,
                log: @escaping @MainActor (String) -> Void = { _ in }, now: @escaping @MainActor () -> Date = { Date() }) {
        self.cache = cache
        self.renderer = renderer
        self.log = log
        self.now = now
    }

    public func state(of subject: EditorPreviewSubject) -> State? {
        states[subject]
    }

    /// Shows the subject's preview: at once when it is cached, else once it is rendered.
    public func request(_ subject: EditorPreviewSubject) {
        noteAsked(subject)
        guard states[subject] == nil else { return }
        states[subject] = .generating
        let cache = cache
        Task {
            let cached = await Task.detached(priority: .userInitiated) { cache.cachedPreview(for: subject) }.value
            if let cached {
                states[subject] = .ready(cached)
                noteShown(subject, cached: true)
            } else {
                queue.append(subject)
                startWorker()
            }
        }
    }

    // MARK: Measuring a browser's open

    /// A browser appeared: its open is measured until the tiles it shows have their previews.
    public func beginOpen(_ browser: Browser) {
        endOpen()
        opening = Opening(browser: browser, started: now())
    }

    /// The browser closed: an open whose tiles weren't all shown yet is logged as such.
    public func endOpen() {
        guard let open = opening else { return }
        opening = nil
        guard !open.waiting.isEmpty else { return }
        log("\(open.browser.rawValue) closed after " + Self.seconds(now().timeIntervalSince(open.started))
            + " with \(open.waiting.count) of \(open.waiting.count + open.shown.count) tiles still rendering")
    }

    private func noteAsked(_ subject: EditorPreviewSubject) {
        guard var open = opening, !open.waiting.contains(subject), !open.shown.contains(subject) else { return }
        switch states[subject] {
        case .ready?, .failed?:
            // Shown earlier in this window: as good as cached.
            open.shown.insert(subject)
            open.cached += 1
            opening = open
            // Checked once the other tiles laid out with this one have asked too.
            Task { self.finishOpenIfShown() }
        case .generating?, nil:
            open.waiting.insert(subject)
            opening = open
        }
    }

    private func noteShown(_ subject: EditorPreviewSubject, cached: Bool) {
        guard var open = opening, open.waiting.remove(subject) != nil else { return }
        open.shown.insert(subject)
        if cached {
            open.cached += 1
        } else if states[subject] == .failed {
            open.failed += 1
        } else {
            open.rendered += 1
        }
        opening = open
        finishOpenIfShown()
    }

    private func finishOpenIfShown() {
        guard let open = opening, open.waiting.isEmpty, !open.shown.isEmpty else { return }
        opening = nil
        log("\(open.browser.rawValue) opened in " + Self.seconds(now().timeIntervalSince(open.started))
            + ": \(open.shown.count) tiles shown, \(open.cached) cached, \(open.rendered) rendered, \(open.failed) failed")
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                let batch = self.takeQueue()
                guard !batch.isEmpty else { break }
                await self.render(batch)
            }
            self?.worker = nil
        }
    }

    private func takeQueue() -> [EditorPreviewSubject] {
        defer { queue.removeAll() }
        return queue
    }

    private func render(_ batch: [EditorPreviewSubject]) async {
        let cache = cache
        let items = batch.map { EditorPreviewRenderItem(subject: $0, outputBase: cache.outputBase(for: $0)) }
        await renderer(items) { [weak self] subject in
            Task { @MainActor in self?.resolve(subject) }
        }
        // Whatever the renderer didn't report (it stopped early) is resolved from the disk too.
        for subject in batch where states[subject] == .generating { resolve(subject) }
    }

    private func resolve(_ subject: EditorPreviewSubject) {
        let cache = cache
        Task {
            let cached = await Task.detached(priority: .userInitiated) { cache.cachedPreview(for: subject) }.value
            states[subject] = cached.map(State.ready) ?? .failed
            noteShown(subject, cached: false)
        }
    }
}
