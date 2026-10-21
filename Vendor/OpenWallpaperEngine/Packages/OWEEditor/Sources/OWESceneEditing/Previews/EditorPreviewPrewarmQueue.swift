import Foundation

/// The order the background pre-warm renders previews in: the catalog's (every effect, then the
/// particle systems), except that what a browser shows goes first (`prioritize`), the latest
/// browser's tiles ahead of earlier ones. `next` skips what no longer needs rendering (cached
/// meanwhile, by the browser or a lane).
public struct EditorPreviewPrewarmQueue: Sendable {
    private var urgent: [EditorPreviewSubject] = []
    private var pending: [EditorPreviewSubject]
    private var known: Set<EditorPreviewSubject>

    public init(_ order: [EditorPreviewSubject]) {
        var seen = Set<EditorPreviewSubject>()
        pending = order.filter { seen.insert($0).inserted }
        known = seen
    }

    /// Subjects not handed out yet.
    public var count: Int { urgent.count + pending.count }
    public var isEmpty: Bool { count == 0 }

    /// Moves `subjects` to the front, in their order, ahead of any earlier priorities. A subject
    /// the catalog doesn't list (a Workshop effect a browser shows) is added.
    public mutating func prioritize(_ subjects: [EditorPreviewSubject]) {
        guard !subjects.isEmpty else { return }
        var seen = Set<EditorPreviewSubject>()
        let front = subjects.filter { seen.insert($0).inserted }
        urgent.removeAll(where: seen.contains)
        pending.removeAll(where: seen.contains)
        urgent.insert(contentsOf: front, at: 0)
        known.formUnion(front)
    }

    /// Puts a subject handed out but not rendered (its lane paused) back at the front.
    public mutating func putBack(_ subject: EditorPreviewSubject) {
        urgent.removeAll { $0 == subject }
        pending.removeAll { $0 == subject }
        urgent.insert(subject, at: 0)
        known.insert(subject)
    }

    /// The next subject that `isNeeded`, dropping the ones before it that aren't. `isUrgent` is
    /// true for one a browser asked for.
    public mutating func next(where isNeeded: (EditorPreviewSubject, _ isUrgent: Bool) -> Bool)
        -> (subject: EditorPreviewSubject, isUrgent: Bool)? {
        while !urgent.isEmpty {
            let subject = urgent.removeFirst()
            if isNeeded(subject, true) { return (subject, true) }
        }
        while !pending.isEmpty {
            let subject = pending.removeFirst()
            if isNeeded(subject, false) { return (subject, false) }
        }
        return nil
    }
}
