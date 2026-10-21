import Foundation
import Combine

/// Imports the Workshop items of an existing Steam install: finds CrossOver bottles' libraries or
/// takes the folder the user chooses, lists its items, and copies the checked ones into the
/// Wallpaper Storage folder (`SteamLibraryImport`).
@MainActor
final class SteamLibraryImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case copying
        case failed(String)
    }

    @Published private(set) var detectedLibraries: [URL] = []
    @Published private(set) var library: URL?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: SteamLibraryImport.CopyResult?
    let checklist: ImportChecklist

    private var items: [String: SteamLibraryImport.Item] = [:]
    private let storageDirectory: () throws -> URL
    private let onImported: ([URL]) -> Void
    private var checklistChange: AnyCancellable?

    /// `onImported` gets the new wallpaper folders, on the main thread.
    init(ratings: Set<String>,
         storageDirectory: @escaping () throws -> URL = { try WallpaperStorage.availableDirectory() },
         onImported: @escaping ([URL]) -> Void = { _ in }) {
        self.storageDirectory = storageDirectory
        self.onImported = onImported
        checklist = ImportChecklist(ratings: ratings)
        checklistChange = checklist.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Looks for CrossOver bottles' Steam libraries, and opens the first one found.
    func detect() {
        Task.detached(priority: .userInitiated) {
            let found = SteamLibraryImport.crossOverLibraries()
            await MainActor.run {
                self.detectedLibraries = found
                if self.library == nil, let first = found.first { self.open(first) }
            }
        }
    }

    /// Opens what the user chose: a Steam folder, its `steamapps`, or a folder inside it.
    func choose(_ folder: URL) {
        guard let steamapps = SteamLibraryImport.steamapps(from: folder) else {
            phase = .failed(SteamLibraryImport.Failure.notASteamLibrary(folder).errorDescription ?? "")
            return
        }
        open(steamapps)
    }

    func open(_ steamapps: URL) {
        library = steamapps
        result = nil
        phase = .loading
        let storage: URL?
        do {
            storage = try storageDirectory()
        } catch {
            storage = nil
            OWELog.error(.importer, "Steam library import: \(error.localizedDescription)")
        }
        Task.detached(priority: .userInitiated) {
            do {
                let found = try SteamLibraryImport.items(in: steamapps)
                await MainActor.run { self.show(found, storage: storage) }
            } catch {
                OWELog.error(.importer, "Can't list the Workshop items in \(steamapps.path): \(error)")
                let message = error.localizedDescription
                await MainActor.run { self.phase = .failed(message) }
            }
        }
    }

    func show(_ found: [SteamLibraryImport.Item], storage: URL?) {
        items = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        checklist.show(found.map { item in
            WorkshopImportCandidate(item: item, isInLibrary: storage.map {
                FileManager.default.fileExists(atPath: $0.appending(path: item.id).path)
            } ?? false)
        })
        phase = .loaded
    }

    /// Copies the checked items; the originals stay where they are.
    func copySelected() {
        let selection = checklist.selection.compactMap { items[$0.id] }
        guard !selection.isEmpty else { return }
        let storage: URL
        do {
            storage = try storageDirectory()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .copying
        Task.detached(priority: .userInitiated) {
            let copied = SteamLibraryImport.copy(selection, into: storage)
            OWELog.info(.importer, "Steam library import: \(copied.copied.count) copied, \(copied.existing.count) already there, \(copied.unsupported.count) applications skipped, \(copied.failed.count) failed")
            await MainActor.run { self.finish(copied, storage: storage) }
        }
    }

    private func finish(_ copied: SteamLibraryImport.CopyResult, storage: URL) {
        result = copied
        let folders = copied.copied.map { storage.appending(path: $0, directoryHint: .isDirectory) }
        let list = checklist.candidates.map { candidate in
            var updated = candidate
            if copied.copied.contains(candidate.id) { updated.isInLibrary = true }
            return updated
        }
        checklist.show(list)
        phase = .loaded
        onImported(folders)
    }
}
