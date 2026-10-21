import Foundation
import Observation
import Darwin

/// 素材库运行时状态 + 持久化（F04）。
///
/// - 启动时从 `library.json` 恢复素材与收藏；文件缺失不删除记录，只标记为「待处理」。
/// - 任何变更都会触发一次防抖写入，保证重启后状态一致。
/// - `remove(item:)` 只移除记录，绝不删除用户原始文件或管理目录中的媒体（删除媒体由 F18 明确确认）。
@MainActor
@Observable
final class VideoLibraryStore {
    private(set) var items: [WallpaperItem] = []
    /// 需要用户处理的素材 ID（文件丢失/被移动）。
    private(set) var missingItemIDs: Set<UUID> = []
    /// 显示器标识 → 素材 ID
    private(set) var assignments: [String: UUID] = [:]
    /// 显示器标识 → 播放设置
    private(set) var displaySettings: [String: DisplayPlaybackSettings] = [:]
    private(set) var appSettings: AppSettings = .default
    private(set) var lastError: String?
    private(set) var lastCorruptedBackupPath: String?
    /// 上次成功写入配置的时间，用于设置页显示。
    private(set) var lastSavedAt: Date?

    let storage: AppStorage

    private var saveTask: Task<Void, Never>?
    private let saveDebounce: Duration = .milliseconds(400)

    init(storage: AppStorage = AppStorage()) {
        self.storage = storage
        load()
    }

    // MARK: - 载入

    private func load() {
        do {
            try storage.prepareDirectories()
        } catch {
            lastError = error.localizedDescription
            // A migration failure must not look like a legitimate empty library.
            // Keep every in-memory collection empty and wait for the next launch
            // after the user resolves the reported storage problem.
            items = []
            assignments = [:]
            displaySettings = [:]
            appSettings = .default
            return
        }
        do {
            let document = try LibraryPersistence.load(from: storage.libraryFile)
            var migratedItems = document.items
            var didMigrateProjectKind = false
            for index in migratedItems.indices where migratedItems[index].contentKind == nil {
                if let kind = LegacyManagedProjectKind.detect(item: migratedItems[index], storage: storage) {
                    migratedItems[index].contentKind = kind
                    didMigrateProjectKind = true
                }
            }
            items = migratedItems
            assignments = document.assignments
            displaySettings = document.displaySettings
            appSettings = document.appSettings
            if didMigrateProjectKind {
                var migratedDocument = document
                migratedDocument.items = migratedItems
                do {
                    _ = try LibraryPersistence.save(migratedDocument, to: storage.libraryFile)
                    lastSavedAt = Date()
                } catch {
                    // Keep the safe in-memory repair so the project opens in the
                    // right runtime; a later ordinary store mutation retries persistence.
                    lastError = error.localizedDescription
                }
            }
        } catch {
            lastError = error.localizedDescription
            if let backup = LibraryPersistence.quarantineCorruptedFile(at: storage.libraryFile) {
                lastCorruptedBackupPath = backup.path
            }
            items = []
            assignments = [:]
            displaySettings = [:]
            appSettings = .default
        }
        refreshMissingState()
    }

    /// 重新检查所有素材的文件是否存在（不修改记录内容）。
    func refreshMissingState() {
        var missing: Set<UUID> = []
        for item in items where !item.fileExists {
            missing.insert(item.id)
        }
        missingItemIDs = missing
    }

    /// Mutation paths only need to reconsider the record they changed. A full
    /// scan remains reserved for launch, activation and the explicit refresh
    /// command so unrelated externally restored files are still discovered.
    private func refreshMissingState(for item: WallpaperItem) {
        if item.fileExists {
            missingItemIDs.remove(item.id)
        } else {
            missingItemIDs.insert(item.id)
        }
    }

    var missingItems: [WallpaperItem] { items.filter { missingItemIDs.contains($0.id) } }
    var favoriteItems: [WallpaperItem] { items.filter(\.isFavorite) }

    func item(withID id: UUID) -> WallpaperItem? {
        items.first { $0.id == id }
    }

    // MARK: - 查询（导入去重用）

    func item(matchingFingerprint fingerprint: String, size: Int64, standardPath: String) -> WallpaperItem? {
        // 已取得内容指纹时只按内容去重。同一原始路径可以被用户替换为另一段视频，
        // 路径相同不能覆盖指纹不一致的结果。无指纹的保守回退由导入服务单独处理。
        items.first { $0.contentFingerprint == fingerprint && $0.fileSizeBytes == size }
    }

    func item(matchingStandardPath path: String) -> WallpaperItem? {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return items.first { item in
            let mediaPath = URL(fileURLWithPath: item.filePath).resolvingSymlinksInPath().standardizedFileURL.path
            if mediaPath == normalized { return true }
            guard let original = item.originalPath else { return false }
            return URL(fileURLWithPath: original).resolvingSymlinksInPath().standardizedFileURL.path == normalized
        }
    }

    // MARK: - 变更

    func add(_ item: WallpaperItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        refreshMissingState(for: item)
        scheduleSave()
    }

    /// Commit a prepared multi-file project before exposing its record to views.
    func addPersistedItem(_ item: WallpaperItem) throws {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        let document = LibraryDocument(schemaVersion: AppConstants.librarySchemaVersion,
            appVersion: AppConstants.version, items: items + [item], assignments: assignments,
            displaySettings: displaySettings, appSettings: appSettings)
        _ = try LibraryPersistence.save(document, to: storage.libraryFile)
        saveTask?.cancel()
        saveTask = nil
        items.append(item)
        refreshMissingState(for: item)
        lastSavedAt = Date()
    }

    /// Save the replacement document before publishing any changed record.
    func replacePersistedItem(_ item: WallpaperItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw AppFileError.storageUnavailable("要更新的素材记录已不存在")
        }
        var replacement = items
        replacement[index] = item
        let document = LibraryDocument(schemaVersion: AppConstants.librarySchemaVersion,
            appVersion: AppConstants.version, items: replacement, assignments: assignments,
            displaySettings: displaySettings, appSettings: appSettings)
        _ = try LibraryPersistence.save(document, to: storage.libraryFile)
        saveTask?.cancel()
        saveTask = nil
        items = replacement
        refreshMissingState(for: item)
        lastSavedAt = Date()
        lastError = nil
    }

    func update(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        refreshMissingState(for: item)
        scheduleSave()
    }

    func mutate(id: UUID, _ body: (inout WallpaperItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var copy = items[index]
        body(&copy)
        items[index] = copy
        scheduleSave()
    }

    func toggleFavorite(id: UUID) {
        mutate(id: id) { $0.isFavorite.toggle() }
    }

    func markPlayed(id: UUID, at date: Date = Date()) {
        mutate(id: id) { $0.lastPlayedAt = date }
    }

    func rename(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id: id) { $0.title = trimmed }
    }

    /// 移除记录（不删除任何文件）。
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        missingItemIDs.remove(id)
        scheduleSave()
    }

    /// Delete records only after the replacement document has been atomically saved.
    /// A failed write leaves every in-memory record and assignment unchanged.
    func removePersistedItems(ids: Set<UUID>) throws {
        let remainingItems = items.filter { !ids.contains($0.id) }
        let remainingAssignments = assignments.filter { !ids.contains($0.value) }
        let document = LibraryDocument(schemaVersion: AppConstants.librarySchemaVersion,
            appVersion: AppConstants.version, items: remainingItems, assignments: remainingAssignments,
            displaySettings: displaySettings, appSettings: appSettings)
        _ = try LibraryPersistence.save(document, to: storage.libraryFile)
        saveTask?.cancel()
        saveTask = nil
        items = remainingItems
        assignments = remainingAssignments
        missingItemIDs.subtract(ids)
        lastSavedAt = Date()
        lastError = nil
    }

    /// 用户重新指定文件位置后更新记录（保持原记录身份与收藏状态）。
    func relink(id: UUID, to newURL: URL, probe: VideoProbeResult?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items[index]
        var updated = previous
        updated.filePath = newURL.path
        if let probe {
            updated.durationSeconds = probe.durationSeconds
            updated.pixelWidth = probe.pixelWidth
            updated.pixelHeight = probe.pixelHeight
            updated.frameRate = probe.frameRate
            updated.videoCodec = probe.videoCodec
            updated.audioCodec = probe.audioCodec
            updated.hasAudioTrack = probe.hasAudioTrack
        }
        if newURL.path != previous.filePath, previous.fileExists {
            // 旧文件仍在：不删除，记录下来作为备注，便于用户找回。
            updated.notes = "原文件位置已改为 \(PathRedaction.short(newURL))"
        }
        items[index] = updated
        refreshMissingState(for: updated)
        scheduleSave()
        Task { await ThumbnailCache.shared.invalidate(id: id) }
    }

    // MARK: - 显示器分配与设置

    func assignedItemID(for displayID: String) -> UUID? {
        assignments[displayID]
    }

    func assign(itemID: UUID?, to displayID: String) {
        if let itemID {
            assignments[displayID] = itemID
        } else {
            assignments.removeValue(forKey: displayID)
        }
        scheduleSave()
    }

    func assignAll(itemID: UUID, displayIDs: [String]) {
        for displayID in displayIDs {
            assignments[displayID] = itemID
        }
        scheduleSave()
    }

    func settings(for displayID: String) -> DisplayPlaybackSettings {
        displaySettings[displayID] ?? .default
    }

    func videoPlaybackPreferences(for itemID: UUID) -> VideoPlaybackPreferences? {
        item(withID: itemID)?.videoPlaybackPreferences
    }

    func effectiveSettings(for itemID: UUID, displayID: String) -> DisplayPlaybackSettings {
        let defaults = settings(for: displayID)
        return videoPlaybackPreferences(for: itemID)?.applying(to: defaults) ?? defaults
    }

    func updateVideoPlaybackPreferences(_ preferences: VideoPlaybackPreferences?, itemID: UUID) {
        mutate(id: itemID) { $0.videoPlaybackPreferences = preferences?.normalized }
    }

    func updateSettings(for displayID: String, _ body: (inout DisplayPlaybackSettings) -> Void) {
        var settings = displaySettings[displayID] ?? .default
        body(&settings)
        displaySettings[displayID] = settings
        scheduleSave()
    }

    func resetSettings(for displayID: String) {
        displaySettings.removeValue(forKey: displayID)
        scheduleSave()
    }

    func updateAppSettings(_ body: (inout AppSettings) -> Void) {
        var copy = appSettings
        body(&copy)
        appSettings = copy
        scheduleSave()
    }

    // MARK: - 持久化

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    @discardableResult
    func saveNow() -> Int? {
        let document = LibraryDocument(
            schemaVersion: AppConstants.librarySchemaVersion,
            appVersion: AppConstants.version,
            items: items,
            assignments: assignments,
            displaySettings: displaySettings,
            appSettings: appSettings
        )
        do {
            let bytes = try LibraryPersistence.save(document, to: storage.libraryFile)
            lastSavedAt = Date()
            lastError = nil
            return bytes
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 等待防抖写入完成（退出应用前调用，保证最后一秒的变更落盘）。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    // MARK: - 统计

    var totalSizeBytes: Int64 {
        items.reduce(into: Int64(0)) { $0 += $1.fileSizeBytes }
    }

    var libraryFileSizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: storage.libraryFile.path)[.size] as? NSNumber)??.int64Value ?? 0
    }
}

private enum LegacyManagedProjectKind {
    private static let maximumProjectBytes = 1024 * 1024

    static func detect(item: WallpaperItem, storage: AppStorage) -> WallpaperContentKind? {
        let media = storage.mediaDirectory
        let candidate = URL(fileURLWithPath: item.filePath)
        let root = media.path.hasSuffix("/") ? media.path : media.path + "/"
        guard candidate.path.hasPrefix(root) else { return nil }
        let relative = String(candidate.path.dropFirst(root.count))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == "project.json", UUID(uuidString: parts[1]) != nil else { return nil }
        let expected: WallpaperContentKind
        switch parts[0] {
        case "SceneProjects": expected = .scene
        case "WebProjects": expected = .web
        default: return nil
        }
        guard let data = readProject(mediaRoot: media, namespace: parts[0], identifier: parts[1]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              type.lowercased() == expected.rawValue else { return nil }
        return expected
    }

    private static func readProject(mediaRoot: URL, namespace: String, identifier: String) -> Data? {
        guard let media = openAbsoluteDirectory(mediaRoot) else { return nil }
        defer { close(media) }
        guard isOwnedNonWritableDirectory(media), let category = openDirectory(media, namespace) else { return nil }
        defer { close(category) }
        guard isOwnedNonWritableDirectory(category), let project = openDirectory(category, identifier) else { return nil }
        defer { close(project) }
        guard isOwnedNonWritableDirectory(project) else { return nil }
        let descriptor = openat(project, "project.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= maximumProjectBytes else { return nil }
        var data = Data(count: Int(before.st_size)), offset = 0
        let completed = data.withUnsafeMutableBytes { bytes -> Bool in
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        var extra: UInt8 = 0, after = stat()
        guard completed, Darwin.read(descriptor, &extra, 1) == 0,
              fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { return nil }
        return data
    }

    private static func openAbsoluteDirectory(_ url: URL) -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("//"),
              url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        for part in url.path.split(separator: "/") {
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    private static func openDirectory(_ parent: Int32, _ name: String) -> Int32? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func isOwnedNonWritableDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
            info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }
}
