import QuartzCore

/// Which display renders a shared scene's frames (docs/architecture.md "Wallpaper instances").
///
/// The display with the highest frame rate drives the instance: each of its draws renders a frame
/// (one script frame, one simulation step, one scene pass) and presents it; the other displays
/// present the latest frame at their own rate. Equal rates: the display that joined first drives.
/// A driver that stops drawing (its window occluded, its display asleep) hands over: once the
/// latest frame is two of its intervals old, whichever display draws next renders.
struct SceneFrameSchedule {
    private struct Presenter {
        let id: ObjectIdentifier
        var frameRate: Int
    }

    private var presenters: [Presenter] = []
    private(set) var lastRender: CFTimeInterval?

    var count: Int { presenters.count }

    /// The display that drives the frames.
    var driver: ObjectIdentifier? {
        var best: Presenter?
        for presenter in presenters where presenter.frameRate > (best?.frameRate ?? .min) { best = presenter }
        return best?.id
    }

    private var driverFrameRate: Int { presenters.map(\.frameRate).max() ?? 60 }

    mutating func add(_ id: ObjectIdentifier, frameRate: Int) {
        guard !presenters.contains(where: { $0.id == id }) else { return setFrameRate(frameRate, of: id) }
        presenters.append(Presenter(id: id, frameRate: frameRate))
    }

    mutating func remove(_ id: ObjectIdentifier) {
        presenters.removeAll { $0.id == id }
    }

    mutating func setFrameRate(_ frameRate: Int, of id: ObjectIdentifier) {
        guard let index = presenters.firstIndex(where: { $0.id == id }) else { return }
        presenters[index].frameRate = frameRate
    }

    /// Whether `id`'s draw at `now` renders a new frame before presenting.
    func shouldRender(_ id: ObjectIdentifier, at now: CFTimeInterval) -> Bool {
        guard let lastRender, id != driver else { return true }
        return now - lastRender > 2 / Double(max(driverFrameRate, 1))
    }

    mutating func rendered(at now: CFTimeInterval) {
        lastRender = now
    }
}
