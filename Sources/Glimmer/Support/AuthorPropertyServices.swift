import Foundation
import Observation

@MainActor
@Observable
final class AuthorPropertyServices {
    static let shared = AuthorPropertyServices()
    private var stores: [String: AuthorPropertyOverrideStore] = [:]
    private(set) var revisions: [UUID: Int] = [:]
    private var hosts: [UUID: [UUID: WeakWebWallpaperHost]] = [:]
    private var sceneHosts: [UUID: [UUID: WeakSceneWallpaperHost]] = [:]
    private var assetStores: [String: AuthorPropertyAssetStore] = [:]
    private var lockedItems: Set<UUID> = []
    private var removingItems: Set<UUID> = []
    private var removedItems: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var contexts: [UUID: (AuthorPropertyProject, AppStorage)] = [:]
    private var monitors: [UUID: AuthorPropertySourceMonitor] = [:]
    private var monitorGenerations: [UUID: UUID] = [:]
    private var monitorPaths: [UUID: [String]] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTaskGenerations: [UUID: UUID] = [:]
    private var refreshPending: Set<UUID> = []
    private(set) var resourceErrors: [UUID: String] = [:]


    func register(_ runtime: WebWallpaperRuntime, itemID: UUID, onConfigurationChange: (@MainActor () -> Void)? = nil) -> UUID {
        let token = UUID()
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else { runtime.dispose(); return token }
        hosts[itemID, default: [:]][token] = WeakWebWallpaperHost(runtime, onChange: onConfigurationChange)
        Task { try? await self.updateMonitor(itemID: itemID) }
        return token
    }

    func unregister(itemID: UUID, token: UUID) {
        hosts[itemID]?[token] = nil
        if hosts[itemID]?.isEmpty == true {
            hosts[itemID] = nil
            monitors.removeValue(forKey: itemID)?.dispose()
            monitorGenerations[itemID] = UUID()
            monitorPaths[itemID] = nil
            refreshPending.remove(itemID)
            refreshTasks[itemID]?.cancel()
        }
    }

    func registerScene(_ runtime: SceneWallpaperRuntime, itemID: UUID, onConfigurationChange: (@MainActor () -> Void)? = nil) -> UUID {
        let token = UUID()
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else { runtime.dispose(); return token }
        sceneHosts[itemID, default: [:]][token] = WeakSceneWallpaperHost(runtime, onChange: onConfigurationChange)
        return token
    }

    func unregisterScene(itemID: UUID, token: UUID) {
        sceneHosts[itemID]?[token] = nil
        if sceneHosts[itemID]?.isEmpty == true { sceneHosts[itemID] = nil }
    }

    func readySceneHosts(itemID: UUID) -> [SceneWallpaperRuntime] {
        (sceneHosts[itemID]?.values.compactMap(\.runtime) ?? []).filter { $0.state == .ready || $0.state == .paused }
    }

    private func controllableSceneHosts(itemID: UUID) -> [SceneWallpaperRuntime] {
        (sceneHosts[itemID]?.values.compactMap(\.runtime) ?? []).filter { $0.state == .ready || $0.state == .paused || $0.state == .failed }
    }

    func readyHosts(itemID: UUID) -> [WebWallpaperRuntime] {
        (hosts[itemID]?.values.compactMap(\.runtime) ?? [])
            .filter { $0.state == .ready || $0.state == .paused }
    }

    /// Failed authored callbacks remain editable when their actual capability was observed.
    /// A new payload can repair a bad saved value without a reload loop.
    private func controllableHosts(itemID: UUID) -> [WebWallpaperRuntime] {
        (hosts[itemID]?.values.compactMap(\.runtime) ?? [])
            .filter { $0.state == .ready || $0.state == .paused || $0.state == .failed }
    }

    func editableKeys(project: AuthorPropertyProject, itemID: UUID) -> Set<String> {
        let targets = controllableHosts(itemID: itemID)
        let scenes = controllableSceneHosts(itemID: itemID)
        if !scenes.isEmpty {
            var keys = Set(project.properties.map(\.key))
            for scene in scenes { keys.formIntersection(scene.editablePropertyKeys) }
            // An item must never expose capabilities belonging to another renderer.
            guard targets.isEmpty, project.projectType.lowercased() == "scene" else { return [] }
            return keys
        }
        guard !targets.isEmpty, project.projectType.lowercased() != "scene" else { return [] }
        return Set(project.properties.filter { definition in
            switch definition.kind {
            case .bool, .color, .slider, .combo, .textinput, .file:
                return targets.allSatisfy(\.canApplyUserProperties)
            case .directory:
                if definition.raw["mode"]?.stringValue == "fetchall" { return targets.allSatisfy(\.canApplyDirectoryProperties) }
                return targets.allSatisfy(\.canApplyUserProperties)
            default: return false
            }
        }.map(\.key))
    }

    func applyAndWait(_ payload: Data, itemID: UUID) async throws {
        try requireAvailable(itemID)
        let scenes = controllableSceneHosts(itemID: itemID)
        if !scenes.isEmpty {
            try await applyScenePayload(payload, itemID: itemID)
            return
        }
        let targets = readyHosts(itemID: itemID)
        guard !targets.isEmpty else { throw WebProjectError.invalid("网页预览尚未就绪或已经关闭；设置已保存，可在重新加载后重试。") }
        for host in targets { try await host.applyPropertiesAndWait(payload) }
    }

    func store(storage: AppStorage) -> AuthorPropertyOverrideStore {
        let directory = storage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true)
        if let store = stores[directory.path] { return store }
        let store = AuthorPropertyOverrideStore(directory: directory)
        stores[directory.path] = store
        return store
    }

    func assets(storage: AppStorage) -> AuthorPropertyAssetStore {
        let directory = storage.root.appendingPathComponent("AuthorPropertyAssets", isDirectory: true)
        if let store = assetStores[directory.path] { return store }
        let store = AuthorPropertyAssetStore(directory: directory)
        assetStores[directory.path] = store
        return store
    }

    private func acquireItemLock(itemID: UUID) async {
        if lockedItems.contains(itemID) {
            await withCheckedContinuation { waiters[itemID, default: []].append($0) }
        } else { lockedItems.insert(itemID) }
    }

    private func releaseItemLock(itemID: UUID) {
        if var queued = waiters[itemID], !queued.isEmpty {
            let next = queued.removeFirst(); waiters[itemID] = queued; next.resume()
        } else { lockedItems.remove(itemID); waiters[itemID] = nil }
    }

    private func requireAvailable(_ itemID: UUID) throws {
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else {
            throw WebProjectError.invalid("此壁纸正在删除或已删除，未重新创建作者设置")
        }
    }

    private func withItemLock<T>(itemID: UUID, _ body: @MainActor () async throws -> T) async throws -> T {
        try requireAvailable(itemID)
        await acquireItemLock(itemID: itemID)
        defer { releaseItemLock(itemID: itemID) }
        try Task.checkCancellation()
        try requireAvailable(itemID)
        return try await body()
    }

    /// The synchronous file/library commit runs while all matching item locks
    /// and both actor barriers are held. No bookmark is resolved for deletion.
    func withItemRemoval<T>(itemIDs: Set<UUID>, storage: AppStorage,
                            _ commit: @MainActor () throws -> T) async throws -> T {
        let ids = itemIDs.sorted { $0.uuidString < $1.uuidString }
        for id in ids { try requireAvailable(id) }
        removingItems.formUnion(itemIDs)
        for id in ids {
            monitors.removeValue(forKey: id)?.dispose()
            monitorGenerations[id] = UUID(); monitorPaths[id] = nil
            refreshPending.remove(id); refreshTasks.removeValue(forKey: id)?.cancel()
        }
        for id in ids { await acquireItemLock(itemID: id) }
        defer { for id in ids.reversed() { releaseItemLock(itemID: id) } }
        let overrides = store(storage: storage), resources = assets(storage: storage), token = UUID()
        var overrideBarriers: [UUID] = [], resourceBarriers: [UUID] = []
        do {
            try Task.checkCancellation()
            for id in ids {
                try await overrides.beginItemRemoval(itemID: id, token: token); overrideBarriers.append(id)
                try await resources.beginItemRemoval(itemID: id, token: token); resourceBarriers.append(id)
            }
            try Task.checkCancellation()
            let result = try commit()
            // Publish the tombstone before yielding to actors, including before
            // a late runtime registration or queued item-lock waiter can resume.
            removedItems.formUnion(itemIDs)
            for id in ids {
                let runtimes = hosts.removeValue(forKey: id)?.values.compactMap(\.runtime) ?? []
                for runtime in runtimes { runtime.dispose() }
                let scenes = sceneHosts.removeValue(forKey: id)?.values.compactMap(\.runtime) ?? []
                for runtime in scenes { runtime.dispose() }
                contexts[id] = nil; resourceErrors[id] = nil; revisions[id] = nil
            }
            for id in resourceBarriers { await resources.finishItemRemoval(itemID: id, token: token, committed: true) }
            for id in overrideBarriers { await overrides.finishItemRemoval(itemID: id, token: token, committed: true) }
            removingItems.subtract(itemIDs)
            return result
        } catch {
            for id in resourceBarriers { await resources.finishItemRemoval(itemID: id, token: token, committed: false) }
            for id in overrideBarriers { await overrides.finishItemRemoval(itemID: id, token: token, committed: false) }
            removingItems.subtract(itemIDs)
            for id in ids {
                do { try await updateMonitor(itemID: id) }
                catch { resourceErrors[id] = "恢复资源监测失败：" + error.localizedDescription }
            }
            throw error
        }
    }

    static func configuration(item: WallpaperItem, storage: AppStorage) async throws -> (payload: Data, manifest: WebWallpaperResourceManifest) {
        guard let project = try project(for: item) else { throw WebProjectError.invalid("Web 项目配置不存在") }
        return try await shared.withItemLock(itemID: item.id) {
            shared.contexts[item.id] = (project, storage)
            let result = try await shared.configurationUnlocked(project: project, itemID: item.id, storage: storage)
            try await shared.updateMonitor(itemID: item.id)
            return result
        }
    }

    private func configurationUnlocked(project: AuthorPropertyProject, itemID: UUID, storage: AppStorage) async throws -> (payload: Data, manifest: WebWallpaperResourceManifest) {
        let resourceStore = assets(storage: storage)
        let grants = try await resourceStore.grants(itemID: itemID)
        let manifest = try await resourceStore.manifest(itemID: itemID)
        let persisted = try await store(storage: storage).load(itemID: itemID)
        var values = project.resolve(overrides: persisted).values
        // Only an explicit persisted override matching a native grant authorizes exposure.
        let active = grants.filter { grant in
            guard let definition = project.definition(for: grant.propertyKey), persisted[grant.propertyKey] == grant.value else { return false }
            if definition.kind == .file { return grant.kind == .file }
            guard definition.kind == .directory, grant.kind == .directory else { return false }
            return grant.directoryMode?.rawValue == (definition.raw["mode"]?.stringValue ?? "ondemand")
        }
        for definition in project.properties where definition.kind == .file || definition.kind == .directory {
            if !active.contains(where: { $0.propertyKey == definition.key }) { values[definition.key] = .string("") }
        }
        let tokens = Set(active.flatMap(\.assets).map(\.token))
        let directoryKeys = Set(active.filter { $0.kind == .directory }.map(\.propertyKey))
        let filtered = WebWallpaperResourceManifest(itemID: itemID, rootURL: manifest.rootURL,
            assets: manifest.assets.filter { tokens.contains($0.token) },
            directories: manifest.directories.filter { directoryKeys.contains($0.propertyKey) })
        return (try Self.payload(project: project, values: values), filtered)
    }

    func applySavedSettings(project: AuthorPropertyProject, itemID: UUID, storage: AppStorage) async throws {
        try await withItemLock(itemID: itemID) {
            if project.projectType.lowercased() == "scene" {
                let resolved = try await self.store(storage: storage).resolve(itemID: itemID, project: project)
                let payload = try Self.payload(project: project, values: resolved.values)
                try await self.applyScenePayload(payload, itemID: itemID)
            } else {
                let config = try await self.configurationUnlocked(project: project, itemID: itemID, storage: storage)
                _ = try await self.install(config, itemID: itemID, requiresDirectory: false)
            }
        }
    }

    private func applyScenePayload(_ payload: Data, itemID: UUID) async throws {
        try requireAvailable(itemID)
        let targets = controllableSceneHosts(itemID: itemID)
        guard !targets.isEmpty else { throw WebProjectError.invalid("Scene 预览尚未就绪或已经关闭；设置已保存，可重新加载后重试。") }
        for runtime in targets {
            try requireAvailable(itemID)
            let callbacks = sceneHosts[itemID]?.values.filter { $0.runtime === runtime }.compactMap(\.onChange) ?? []
            for callback in callbacks { callback() }
            try await runtime.applyPropertiesAndWait(payload)
            try requireAvailable(itemID)
        }
        // Loading/new hosts must not be silently counted as acknowledged.
        let live = sceneHosts[itemID]?.values.compactMap(\.runtime).filter { $0.state != .disposed } ?? []
        let acknowledged = Set(targets.map(ObjectIdentifier.init))
        guard live.allSatisfy({ acknowledged.contains(ObjectIdentifier($0)) }) else {
            throw WebProjectError.invalid("仍有 Scene 视图正在加载；设置已保存，可在加载后重试。")
        }
    }

    /// Returns true only when every still-live host has acknowledged the current resources.
    /// Loading hosts receive configuration too, but retain old resource versions until later ACK.
    private func install(_ configuration: (payload: Data, manifest: WebWallpaperResourceManifest), itemID: UUID,
                         requiresDirectory: Bool) async throws -> Bool {
        let targets = controllableHosts(itemID: itemID)
        guard !targets.isEmpty else { throw WebProjectError.invalid("网页已关闭或尚未就绪；设置已保存，可在重新加载后重试。") }
        guard targets.allSatisfy({ requiresDirectory ? $0.canApplyDirectoryProperties : $0.canApplyUserProperties }) else {
            throw WebProjectError.invalid("网页未提供对应的作者设置回调；设置已保存，但尚未应用。")
        }
        let all = hosts[itemID]?.values.filter { $0.runtime != nil && $0.runtime?.state != .disposed } ?? []
        for host in all {
            guard let runtime = host.runtime else { continue }
            host.onChange?()
            try runtime.configureResourceManifest(configuration.manifest)
            try runtime.applyPropertiesJSON(configuration.payload)
        }
        var acknowledged: Set<ObjectIdentifier> = []
        for runtime in targets {
            if runtime.canApplyDirectoryProperties {
                try await runtime.configureResourceManifestAndWait(configuration.manifest)
            }
            if runtime.canApplyUserProperties { try await runtime.applyPropertiesAndWait(configuration.payload) }
            acknowledged.insert(ObjectIdentifier(runtime))
        }
        resourceErrors[itemID] = nil
        let live = hosts[itemID]?.values.compactMap(\.runtime).filter { $0.state != .disposed } ?? []
        return live.allSatisfy { acknowledged.contains(ObjectIdentifier($0)) }
    }

    func performResource(_ request: AuthorPropertyResourceRequest, storage: AppStorage) async throws {
        try await withItemLock(itemID: request.itemID) {
            let itemID = request.itemID, definition = request.definition
            guard request.project.projectType.lowercased() != "scene" else {
                throw AuthorPropertyResourceFailure(persisted: false, message: "当前 Scene 渲染器尚未支持文件或目录作者属性，未保存资源授权。")
            }
            guard request.project.definition(for: definition.key) == definition,
                  definition.kind == .file || definition.kind == .directory else {
                throw AuthorPropertyResourceFailure(persisted: false, message: "资源属性与当前项目不匹配")
            }
            self.contexts[itemID] = (request.project, storage)
            let assets = self.assets(storage: storage), overrides = self.store(storage: storage)
            let checkpoint = try await assets.checkpoint(itemID: itemID, propertyKey: definition.key)
            var replacedRevision = checkpoint.record?.grant.revision
            var persisted = false
            do {
                switch request.operation {
                case .select(let url):
                    let grant = try await (definition.kind == .file
                        ? assets.selectFile(url, itemID: itemID, propertyKey: definition.key, project: request.project)
                        : assets.selectDirectory(url, itemID: itemID, propertyKey: definition.key, project: request.project))
                    replacedRevision = grant.revision
                    try Task.checkCancellation()
                    try await overrides.set(grant.value, for: definition.key, itemID: itemID, project: request.project)
                case .refresh:
                    let grant = try await assets.refresh(itemID: itemID, propertyKey: definition.key, project: request.project)
                    replacedRevision = grant.revision
                    try Task.checkCancellation()
                    try await overrides.set(grant.value, for: definition.key, itemID: itemID, project: request.project)
                case .clear, .reset:
                    try await assets.revoke(itemID: itemID, propertyKey: definition.key)
                    replacedRevision = nil
                    if case .reset = request.operation { try await overrides.set(nil, for: definition.key, itemID: itemID, project: request.project) }
                    else { try await overrides.set(.string(""), for: definition.key, itemID: itemID, project: request.project) }
                case .retry: break
                }
                persisted = true
                try await self.updateMonitor(itemID: itemID)
                let configuration = try await self.configurationUnlocked(project: request.project, itemID: itemID, storage: storage)
                let fullyConsumed = try await self.install(configuration, itemID: itemID,
                    requiresDirectory: definition.kind == .directory && definition.raw["mode"]?.stringValue == "fetchall")
                if fullyConsumed { try await assets.pruneUnreferencedAssets(itemID: itemID) }
            } catch {
                var message = error.localizedDescription
                if !persisted {
                    do { try await assets.restore(checkpoint, replacingRevision: replacedRevision) }
                    catch { message += "；资源授权回滚未完成：" + error.localizedDescription }
                }
                self.resourceErrors[itemID] = message
                throw AuthorPropertyResourceFailure(persisted: persisted, message: message)
            }
        }
    }

    private func updateMonitor(itemID: UUID) async throws {
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else { return }
        guard hosts[itemID]?.values.contains(where: { $0.runtime != nil && $0.runtime?.state != .disposed }) == true,
              let (_, storage) = contexts[itemID] else { return }
        let generation = UUID()
        monitorGenerations[itemID] = generation
        let urls = try await assets(storage: storage).sourceURLs(itemID: itemID)
        guard !removingItems.contains(itemID), !removedItems.contains(itemID),
              monitorGenerations[itemID] == generation,
              hosts[itemID]?.values.contains(where: { $0.runtime != nil && $0.runtime?.state != .disposed }) == true else { return }
        let paths = urls.map(\.path).sorted()
        guard paths != monitorPaths[itemID] else { return }
        monitors.removeValue(forKey: itemID)?.dispose()
        monitorPaths[itemID] = paths
        guard !urls.isEmpty else { return }
        let monitor = AuthorPropertySourceMonitor(urls: urls) { [weak self] in self?.scheduleRefresh(itemID: itemID) }
        guard monitor.isActive else { monitorPaths[itemID] = nil; throw WebProjectError.invalid("无法监测已选资源的变更，请重新选择资源后重试。") }
        monitors[itemID] = monitor
    }

    private func scheduleRefresh(itemID: UUID) {
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else { return }
        refreshPending.insert(itemID)
        guard refreshTasks[itemID] == nil else { return }
        let generation = UUID()
        refreshTaskGenerations[itemID] = generation
        refreshTasks[itemID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshTaskGenerations[itemID] == generation {
                    self.refreshTasks[itemID] = nil; self.refreshTaskGenerations[itemID] = nil
                }
            }
            while self.refreshPending.remove(itemID) != nil, !Task.isCancelled,
                  let (project, storage) = self.contexts[itemID] {
                do {
                    let grants = try await self.assets(storage: storage).grants(itemID: itemID)
                    let overrides = try await self.store(storage: storage).load(itemID: itemID)
                    for grant in grants {
                        guard overrides[grant.propertyKey] == grant.value,
                              let definition = project.definition(for: grant.propertyKey) else { continue }
                        try await self.performResource(.init(itemID: itemID, project: project, definition: definition, operation: .refresh), storage: storage)
                    }
                } catch {
                    if !self.removingItems.contains(itemID), !self.removedItems.contains(itemID) {
                        self.resourceErrors[itemID] = "资源自动更新失败：" + error.localizedDescription
                    }
                }
            }
        }
    }

    func didChange(itemID: UUID) {
        guard !removingItems.contains(itemID), !removedItems.contains(itemID) else { return }
        revisions[itemID, default: 0] += 1
    }

    static func project(for item: WallpaperItem) throws -> AuthorPropertyProject? {
        let url = item.isProjectWallpaper ? item.fileURL : item.fileURL.deletingLastPathComponent().appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let project = try AuthorPropertyProject.load(projectURL: url, allowedRoot: url.deletingLastPathComponent())
        if !item.isProjectWallpaper {
            guard let entry = project.rawJSON.objectValue?["file"]?.stringValue,
                  url.deletingLastPathComponent().appendingPathComponent(entry).standardizedFileURL.resolvingSymlinksInPath() == item.fileURL.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        }
        return project
    }

    static func payload(item: WallpaperItem, storage: AppStorage) async throws -> Data {
        if item.isWebWallpaper { return try await configuration(item: item, storage: storage).payload }
        if item.isSceneWallpaper {
            guard let project = try project(for: item), project.projectType.lowercased() == "scene" else { throw WebProjectError.invalid("Scene 项目配置不存在") }
            return try await shared.withItemLock(itemID: item.id) {
                let resolved = try await shared.store(storage: storage).resolve(itemID: item.id, project: project)
                return try payload(project: project, values: resolved.values)
            }
        }
        guard let project = try project(for: item) else { return Data("{}".utf8) }
        let resolution = try await shared.store(storage: storage).resolve(itemID: item.id, project: project)
        return try payload(project: project, values: resolution.values)
    }

    static func payload(project: AuthorPropertyProject, values: [String: GWJSONValue]) throws -> Data {
        let supported: Set<AuthorPropertyKind> = [.bool, .color, .slider, .combo, .textinput, .file, .directory]
        var result: [String: GWJSONValue] = [:]
        for definition in project.properties where supported.contains(definition.kind) {
            if definition.kind == .directory, definition.raw["mode"]?.stringValue == "fetchall" { continue }
            guard let value = values[definition.key] else { continue }
            try definition.validate(value)
            var raw = definition.raw
            raw["value"] = value
            result[definition.key] = .object(raw)
        }
        // Payload bytes are cache identity. Sort keys recursively so dictionary
        // insertion/dictionary iteration order cannot create duplicate hashes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(GWJSONValue.object(result))
    }
}

private final class WeakWebWallpaperHost {
    weak var runtime: WebWallpaperRuntime?
    let onChange: (@MainActor () -> Void)?
    init(_ runtime: WebWallpaperRuntime, onChange: (@MainActor () -> Void)?) { self.runtime = runtime; self.onChange = onChange }
}

private final class WeakSceneWallpaperHost {
    weak var runtime: SceneWallpaperRuntime?
    let onChange: (@MainActor () -> Void)?
    init(_ runtime: SceneWallpaperRuntime, onChange: (@MainActor () -> Void)?) { self.runtime = runtime; self.onChange = onChange }
}
