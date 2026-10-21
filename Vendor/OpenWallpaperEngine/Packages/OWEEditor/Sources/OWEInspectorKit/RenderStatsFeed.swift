import Combine
import Foundation

/// A renderer's stats for the views that show them. The renderer counts only while some view
/// watches (`watch()` from its `onAppear`, `unwatch()` from its `onDisappear`): the first viewer
/// starts the counting (`start`), the last one gone stops it (`stop`), so a preview nobody looks
/// at the numbers of pays nothing for them.
@MainActor
public final class RenderStatsFeed: ObservableObject {
    /// The latest frame's numbers; nil while nothing is counted.
    @Published public private(set) var stats: RenderStats?
    private var viewers = 0
    /// Where the views keep their choices about the numbers (the editor's Show Stats mode).
    public let defaults: UserDefaults
    private let start: (RenderStatsFeed) -> Void
    private let stop: () -> Void

    public init(defaults: UserDefaults = .standard, start: @escaping (RenderStatsFeed) -> Void, stop: @escaping () -> Void) {
        self.defaults = defaults
        self.start = start
        self.stop = stop
    }

    public var isCounting: Bool { viewers > 0 }

    public func watch() {
        viewers += 1
        if viewers == 1 { start(self) }
    }

    public func unwatch() {
        guard viewers > 0 else { return }
        viewers -= 1
        if viewers == 0 {
            stop()
            stats = nil
        }
    }

    /// The counter's latest numbers (the app samples its renderer a few times a second).
    public func publish(_ stats: RenderStats?) {
        guard isCounting, self.stats != stats else { return }
        self.stats = stats
    }
}
