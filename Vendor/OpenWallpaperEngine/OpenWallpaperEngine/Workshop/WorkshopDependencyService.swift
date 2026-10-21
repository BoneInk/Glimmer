//
//  WorkshopDependencyService.swift
//  Open Wallpaper Engine
//
//  Downloads the Workshop items a wallpaper borrows assets from. When a wallpaper is shown (or a
//  Workshop item finishes downloading) its references are scanned off the main thread; every
//  missing id is checked on Steam first (GetPublishedFileDetails) and the ones that still exist
//  are fetched through steamcmd; each download is scanned in turn, so dependencies of dependencies
//  arrive too. Each id is requested once per session. Items that were removed, made private,
//  banned or belong to another app are remembered (`UnavailableWorkshopItemStore`) and skipped;
//  the wallpaper plays without them, as their assets resolve as missing. When a wallpaper's last
//  pending dependency is settled and one of them was installed, `.workshopDependenciesDidInstall`
//  asks its scene to reload.
//

import Combine
import Foundation

extension Notification.Name {
    /// Posted on the main queue; `userInfo["wallpaperDirectory"]` is the wallpaper to reload.
    static let workshopDependenciesDidInstall = Notification.Name("WorkshopDependenciesDidInstall")
}

@MainActor
final class WorkshopDependencyService: ObservableObject {
    enum State: Equatable {
        case downloading
        case installed
        case failed
        /// steamcmd isn't set up or logged in, so the item can't be fetched automatically.
        case unavailable
        /// Nobody can download the item: removed, private, banned or from another app.
        case itemUnavailable(WorkshopItemAvailability.Reason)
    }

    /// Asks Steam whether items still exist; throws when Steam can't be reached.
    typealias AvailabilityCheck = ([String]) async throws -> [String: WorkshopItemAvailability]

    /// Per dependency id, for the UI.
    @Published private(set) var states: [String: State] = [:]
    /// Wallpaper folder → the dependency ids it still waits for.
    @Published private(set) var pending: [URL: Set<String>] = [:]

    private let steamCmd: SteamCmdService
    private let makeResolver: () -> WorkshopAssetResolver
    private let store: UnavailableWorkshopItemStore
    private let checkAvailability: AvailabilityCheck
    private var requested = Set<String>()
    private var scanned = Set<URL>()
    /// Wallpapers one of whose pending dependencies was installed, to reload once none is pending.
    private var reloadDue = Set<URL>()
    private var cancellables = Set<AnyCancellable>()

    init(steamCmd: SteamCmdService,
         makeResolver: @escaping () -> WorkshopAssetResolver = { WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots()) },
         store: UnavailableWorkshopItemStore = UnavailableWorkshopItemStore(),
         checkAvailability: @escaping AvailabilityCheck = { try await WorkshopAPIService().availability(of: $0) }) {
        self.steamCmd = steamCmd
        self.makeResolver = makeResolver
        self.store = store
        self.checkAvailability = checkAvailability
        // Any item that reaches the storage folder (from the Workshop tab too) may itself need dependencies.
        steamCmd.itemInstalled.sink { [weak self] directory in
            Task { @MainActor [weak self] in self?.ensureDependencies(ofItemAt: directory) }
        }.store(in: &cancellables)
        // steamcmd's `File Not Found`, for downloads started here or from the dependency list.
        steamCmd.itemUnavailable.sink { [weak self] id in
            Task { @MainActor [weak self] in self?.markUnavailable(id, reason: .removedOrPrivate) }
        }.store(in: &cancellables)
        // Wallpapers that were waiting on a login get another try once there is one.
        steamCmd.$isLoggedIn.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.retryUnavailable() }
        }.store(in: &cancellables)
    }

    /// Why `id` can't be downloaded, when it is known to be unavailable.
    func unavailableReason(for id: String) -> WorkshopItemAvailability.Reason? {
        if case .itemUnavailable(let reason) = states[id] { return reason }
        return store.skipReason(for: id)
    }

    /// Forgets that `ids` were unavailable and scans the item in `directory` again, so they are
    /// checked on Steam and downloaded if they are back.
    func retry(_ ids: Set<String>, forItemAt directory: URL) {
        store.forget(ids)
        for id in ids {
            states[id] = nil
            requested.remove(id)
        }
        let directory = directory.standardizedFileURL
        scanned.remove(directory)
        ensureDependencies(ofItemAt: directory)
    }

    private func retryUnavailable() {
        let unavailable = Set(states.compactMap { $0.value == .unavailable ? $0.key : nil })
        for (wallpaper, ids) in pending where !ids.isDisjoint(with: unavailable) {
            scanned.remove(wallpaper)
            pending[wallpaper] = nil
            ensureDependencies(ofItemAt: wallpaper)
        }
    }

    func ensureDependencies(for wallpaper: WEWallpaper) {
        ensureDependencies(ofItemAt: wallpaper.wallpaperDirectory)
    }

    /// Scans the item once per session and fetches whatever it references that isn't installed.
    func ensureDependencies(ofItemAt directory: URL) {
        let directory = directory.standardizedFileURL
        guard scanned.insert(directory).inserted else { return }
        let makeResolver = makeResolver
        Task.detached(priority: .utility) {
            let resolver = makeResolver()
            let referenced = WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: directory)
            let missing = referenced.filter { !resolver.isInstalled($0) }
            // Installed dependencies can still have missing dependencies of their own.
            let installed = referenced.subtracting(missing).compactMap(resolver.itemDirectory(for:))
            await self.handleScan(of: directory, missing: missing, installedDependencies: installed)
        }
    }

    private func handleScan(of directory: URL, missing: Set<String>, installedDependencies: [URL]) {
        installedDependencies.forEach(ensureDependencies(ofItemAt:))
        var wanted = Set<String>()
        for id in missing {
            if let reason = store.skipReason(for: id) {
                states[id] = .itemUnavailable(reason)
            } else {
                wanted.insert(id)
            }
        }
        if wanted.count < missing.count {
            OWELog.info(.workshop, "\(directory.lastPathComponent) skips unavailable workshop items \(missing.subtracting(wanted).sorted())")
        }
        guard !wanted.isEmpty else { return }
        OWELog.info(.workshop, "\(directory.lastPathComponent) needs workshop items \(wanted.sorted())")
        pending[directory, default: []].formUnion(wanted)
        fetch(wanted)
    }

    /// Checks the ids not requested yet on Steam, then downloads the ones that still exist. When
    /// Steam can't be reached every id is downloaded, and steamcmd has the last word.
    private func fetch(_ ids: Set<String>) {
        let new = ids.filter { requested.insert($0).inserted }.sorted()
        guard !new.isEmpty else { return }
        let checkAvailability = checkAvailability
        Task { [weak self] in
            let answers: [String: WorkshopItemAvailability]
            do {
                answers = try await checkAvailability(new)
            } catch {
                OWELog.error(.workshop, "Can't check workshop items \(new) on Steam; downloading them unchecked: \(error)")
                answers = [:]
            }
            self?.finishCheck(of: new, answers: answers)
        }
    }

    private func finishCheck(of ids: [String], answers: [String: WorkshopItemAvailability]) {
        for id in ids {
            if case .unavailable(let reason) = answers[id] {
                markUnavailable(id, reason: reason)
            } else {
                download(id)
            }
        }
    }

    private func download(_ id: String) {
        guard steamCmd.isInstalled, steamCmd.isLoggedIn else {
            OWELog.error(.workshop, "Workshop dependency \(id) is missing; log in to steamcmd on the Workshop tab to download it")
            states[id] = .unavailable
            requested.remove(id)
            return
        }
        states[id] = .downloading
        steamCmd.downloadWorkshopItem(workshopId: id, asDependency: true) { [weak self] destination in
            Task { @MainActor [weak self] in
                self?.finishDownload(id, destination: destination)
            }
        }
    }

    /// Records `id` as unavailable and stops waiting for it; the wallpaper plays without it.
    private func markUnavailable(_ id: String, reason: WorkshopItemAvailability.Reason) {
        OWELog.info(.workshop, "Workshop dependency \(id) is unavailable (\(reason.rawValue)); not downloading it")
        store.record(id, reason: reason)
        states[id] = .itemUnavailable(reason)
        settle(id, installed: false)
    }

    private func finishDownload(_ id: String, destination: URL?) {
        guard let destination else {
            // steamcmd's `File Not Found` arrives through `itemUnavailable`.
            if case .itemUnavailable = states[id] { return }
            OWELog.error(.workshop, "Workshop dependency \(id) failed to download")
            states[id] = .failed
            return
        }
        states[id] = .installed
        // Installed now, so it isn't missing again unless it is removed as an unused dependency.
        requested.remove(id)
        ensureDependencies(ofItemAt: destination)
        settle(id, installed: true)
    }

    /// Stops waiting for `id`. A wallpaper with nothing left pending reloads when one of its
    /// dependencies was installed meanwhile.
    private func settle(_ id: String, installed: Bool) {
        for (wallpaper, ids) in pending where ids.contains(id) {
            if installed { reloadDue.insert(wallpaper) }
            let remaining = ids.subtracting([id])
            pending[wallpaper] = remaining.isEmpty ? nil : remaining
            guard remaining.isEmpty, reloadDue.remove(wallpaper) != nil else { continue }
            OWELog.info(.workshop, "Workshop dependencies of \(wallpaper.lastPathComponent) installed; reloading")
            NotificationCenter.default.post(name: .workshopDependenciesDidInstall, object: self,
                                            userInfo: ["wallpaperDirectory": wallpaper])
        }
    }
}
