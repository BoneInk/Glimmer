import Foundation
import Combine

/// The items an import offers, which of them are checked, and the content-rating filter.
///
/// Only items the rating filter allows are listed (so no Mature or Questionable preview shows
/// unless the filter includes it), and only listed items are imported. Application items and
/// items already in the library are listed but can't be checked.
@MainActor
final class ImportChecklist: ObservableObject {
    @Published private(set) var candidates: [WorkshopImportCandidate] = []
    @Published var selected: Set<String> = []
    @Published var ratings: Set<String> {
        didSet { selected = selected.filter { id in visible.contains { $0.id == id } } }
    }

    /// `ratings`: the app's rating filter (the Workshop tab's, Everyone by default).
    init(ratings: Set<String>) {
        self.ratings = ratings.isEmpty ? Set(WorkshopTags.ratings) : ratings
    }

    /// Lists `candidates` with every importable one checked.
    func show(_ candidates: [WorkshopImportCandidate]) {
        self.candidates = candidates
        selectAll()
    }

    /// What the rating filter lets through, in order.
    var visible: [WorkshopImportCandidate] {
        candidates.filter { $0.isAllowed(byRatings: ratings) }
    }

    /// Items left out by the rating filter; counted, never shown.
    var hiddenCount: Int { candidates.count - visible.count }

    func isSelectable(_ candidate: WorkshopImportCandidate) -> Bool {
        !candidate.isApplication && !candidate.isInLibrary
    }

    func selectAll() {
        selected = Set(visible.filter(isSelectable).map(\.id))
    }

    func selectNone() {
        selected = []
    }

    func toggle(_ candidate: WorkshopImportCandidate) {
        guard isSelectable(candidate) else { return }
        if selected.contains(candidate.id) {
            selected.remove(candidate.id)
        } else {
            selected.insert(candidate.id)
        }
    }

    /// The checked items the filter shows, in list order.
    var selection: [WorkshopImportCandidate] {
        visible.filter { selected.contains($0.id) && isSelectable($0) }
    }

    /// Listed items already in the library (for "add to playlist").
    var inLibrary: [WorkshopImportCandidate] {
        visible.filter { $0.isInLibrary && !$0.isApplication }
    }
}
