import Foundation

/// Keeps the stored Steam tags (`InstalledWorkshopTags` in `DownloadedWallpaperIndex`) of the
/// installed Workshop wallpapers whose project.json has at most one tag.
///
/// - An item is read once. It is read again only when a Steam response seen since (Workshop
///   browsing, the Details panel) reports a later `time_updated`, and then that response's tags
///   are taken without another request.
/// - Unread items are asked for with GetPublishedFileDetails, `batchSize` ids per request, one
///   request at a time with `throttle` between them, in the background; results are stored as
///   they arrive and the Installed tab redraws from the store. Offline, the stored tags are used.
/// - Nothing is requested without a Steam Web API key. A failed request is retried after
///   `retryDelay`, not on every redraw.
///
/// Main-thread only (it belongs to the Installed tab's view model).
final class InstalledWorkshopTagSync {
    typealias Fetch = ([String]) async throws -> [WorkshopItem]

    /// Ids per GetPublishedFileDetails request.
    static let batchSize = 50

    enum Plan: Equatable {
        case upToDate
        /// Take these tags from a Steam response already at hand.
        case adopt(InstalledWorkshopTags)
        case fetch
    }

    private let index: DownloadedWallpaperIndex
    private let apiKey: () -> String?
    private let knownItem: (String) -> WorkshopItem?
    private let fetch: Fetch
    private let throttle: Duration
    private let retryDelay: TimeInterval
    /// How long a missing key is believed before the keychain is read again.
    private let keyRecheckDelay: TimeInterval

    private var queued: [String] = []
    private var inFlight = Set<String>()
    private var failedAt: [String: Date] = [:]
    private var keyCheck: (date: Date, hasKey: Bool)?
    private var worker: Task<Void, Never>?
    private var pendingWallpapers: [WEWallpaper]?

    init(index: DownloadedWallpaperIndex = .shared,
         apiKey: @escaping () -> String? = { SteamCredentials.webAPIKey().load() },
         knownItem: @escaping (String) -> WorkshopItem? = { WorkshopMetadataStore.shared.item(for: $0) },
         fetch: @escaping Fetch = { try await WorkshopAPIService().getItemDetails(workshopIds: $0) },
         throttle: Duration = .seconds(1),
         retryDelay: TimeInterval = 600,
         keyRecheckDelay: TimeInterval = 30) {
        self.index = index
        self.apiKey = apiKey
        self.knownItem = knownItem
        self.fetch = fetch
        self.throttle = throttle
        self.retryDelay = retryDelay
        self.keyRecheckDelay = keyRecheckDelay
    }

    /// What to do for an item with `stored` tags, given the newest Steam response at hand.
    static func plan(stored: InstalledWorkshopTags?, known: WorkshopItem?) -> Plan {
        let knownTime = known?.timeUpdated
        if let stored, stored.revision == InstalledWorkshopTags.currentRevision {
            guard let known, let knownTime, knownTime > (stored.timeUpdated ?? 0) else { return .upToDate }
            return .adopt(InstalledWorkshopTags(tags: known.tags, timeUpdated: knownTime))
        }
        if let known, let knownTime {
            return .adopt(InstalledWorkshopTags(tags: known.tags, timeUpdated: knownTime))
        }
        return .fetch
    }

    /// Runs `update(for:)` on the next main-queue turn, once however often it is called before: the
    /// library is listed while views update, which mustn't publish changes.
    func schedule(_ wallpapers: [WEWallpaper]) {
        let isScheduled = pendingWallpapers != nil
        pendingWallpapers = wallpapers
        guard !isScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let wallpapers = self.pendingWallpapers else { return }
            self.pendingWallpapers = nil
            self.update(for: wallpapers)
        }
    }

    /// Stores what Steam responses at hand say and queues the rest for fetching.
    func update(for wallpapers: [WEWallpaper], now: Date = Date()) {
        var adopted: [String: InstalledWorkshopTags] = [:]
        var toFetch: [String] = []
        var seen = Set<String>()
        for wallpaper in wallpapers where InstalledWorkshopTags.projectNeedsWorkshopTags(wallpaper.project) {
            guard let id = InstalledWorkshopTags.workshopId(of: wallpaper), seen.insert(id).inserted else { continue }
            switch Self.plan(stored: index.workshopTags(for: id), known: knownItem(id)) {
            case .upToDate:
                continue
            case .adopt(let entry):
                adopted[id] = entry
            case .fetch:
                guard !inFlight.contains(id) else { continue }
                if let failed = failedAt[id], now.timeIntervalSince(failed) < retryDelay { continue }
                toFetch.append(id)
            }
        }
        if !adopted.isEmpty {
            index.setWorkshopTags(adopted)
        }
        guard !toFetch.isEmpty, hasKey(now: now) else { return }
        inFlight.formUnion(toFetch)
        queued += toFetch
        startWorker()
    }

    /// Returns once every queued request finished (for tests).
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func hasKey(now: Date) -> Bool {
        if let keyCheck, now.timeIntervalSince(keyCheck.date) < keyRecheckDelay {
            return keyCheck.hasKey
        }
        let hasKey = apiKey() != nil
        keyCheck = (now, hasKey)
        return hasKey
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            var isFirst = true
            while true {
                guard let self, !self.queued.isEmpty else { break }
                if !isFirst {
                    do {
                        try await Task.sleep(for: self.throttle)
                    } catch {
                        break
                    }
                }
                isFirst = false
                let batch = Array(self.queued.prefix(Self.batchSize))
                self.queued.removeFirst(batch.count)
                do {
                    let items = try await self.fetch(batch)
                    self.store(items, requested: batch)
                } catch {
                    OWELog.error(.workshop, "Can't read the Workshop tags of \(batch.count) installed wallpapers: \(error)")
                    self.inFlight.subtract(batch)
                    let now = Date()
                    for id in batch { self.failedAt[id] = now }
                }
            }
            self?.worker = nil
        }
    }

    private func store(_ items: [WorkshopItem], requested batch: [String]) {
        var entries: [String: InstalledWorkshopTags] = [:]
        for item in items where batch.contains(item.id) {
            entries[item.id] = InstalledWorkshopTags(tags: item.tags, timeUpdated: item.timeUpdated)
        }
        // Steam didn't return these (removed or private items): stored empty, not asked for again.
        for id in batch where entries[id] == nil {
            entries[id] = InstalledWorkshopTags(tags: [], timeUpdated: nil)
        }
        index.setWorkshopTags(entries)
        inFlight.subtract(batch)
        for id in batch { failedAt.removeValue(forKey: id) }
    }
}
