import Foundation
import Observation

/// The Installed tab's folders (`InstalledFolderTree`), saved in `UserDefaults.app` as JSON
/// after every change. The Installed list owns the app's one store (`InstalledLibraryModel.folders`);
/// tests pass a defaults suite of their own.
@MainActor @Observable
final class InstalledFolderStore {
    static let storageKey = "InstalledFolders"

    private(set) var tree: InstalledFolderTree
    /// Called after every change (the Installed list drops its sorted copy).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        tree = Self.load(from: defaults)
    }

    /// The stored folders; none when nothing is stored, or when what is stored can't be read
    /// (logged; the next change replaces it).
    nonisolated static func load(from defaults: UserDefaults) -> InstalledFolderTree {
        guard let data = defaults.data(forKey: storageKey) else { return InstalledFolderTree() }
        do {
            return try JSONDecoder().decode(InstalledFolderTree.self, from: data)
        } catch {
            OWELog.error(.library, "The Installed folders can't be read: \(error)")
            return InstalledFolderTree()
        }
    }

    /// Applies `change` and saves the result when it differs.
    @discardableResult
    func update<Result>(_ change: (inout InstalledFolderTree) -> Result) -> Result {
        var copy = tree
        let result = change(&copy)
        guard copy != tree else { return result }
        tree = copy
        save()
        onChange?()
        return result
    }

    /// Merges `incoming` (WE's folders, or a settings file's): see `InstalledFolderTree.merge`.
    @discardableResult
    func merge(_ incoming: [InstalledFolder]) -> InstalledFolderTree.MergeSummary {
        update { $0.merge(incoming) }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(tree), forKey: Self.storageKey)
        } catch {
            OWELog.error(.library, "The Installed folders can't be saved: \(error)")
        }
    }
}
