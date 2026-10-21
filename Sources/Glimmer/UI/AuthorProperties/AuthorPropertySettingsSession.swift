import Foundation
import Observation

/// 独立于播放器的编辑事务。只在用户修改后保存；读取/打开面板不调用运行时。
/// 连续修改按键合并、串行保存和提交；旧事务完成后继续提交最新值，不丢掉拖动结果。
@MainActor
@Observable
final class AuthorPropertySettingsSession {
    enum Mutation: Sendable {
        case set(GWJSONValue)
        case reset
    }

    let project: AuthorPropertyProject
    let itemID: UUID
    let capabilities: AuthorPropertyEditingCapabilities
    private let overrideStore: AuthorPropertyOverrideStore
    private let onValuesChanged: @MainActor ([String: GWJSONValue]) async throws -> Void
    let resourceActions: AuthorPropertyResourceActions?
    private let coalescingDelay: Duration

    private(set) var values: [String: GWJSONValue] = [:]
    private(set) var overrides: [String: GWJSONValue] = [:]
    private(set) var diagnostics: [AuthorPropertyDiagnostic] = []
    private(set) var unknownOverrides: [String: GWJSONValue] = [:]
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var isReady = false
    private(set) var isResourceBusy = false
    private var resourceRetry: AuthorPropertyResourceRequest?
    private(set) var statusText: String?
    private(set) var errorText: String?
    private(set) var savedButNotApplied = false
    private var pending: [String: Mutation] = [:]
    private var inFlight: [String: Mutation] = [:]
    private var failedMutations: [String: Mutation] = [:]
    private var reapplyRequested = false
    private var drainTask: Task<Void, Never>?

    init(project: AuthorPropertyProject, overrideStore: AuthorPropertyOverrideStore, itemID: UUID,
         capabilities: AuthorPropertyEditingCapabilities, resourceActions: AuthorPropertyResourceActions? = nil,
         coalescingDelay: Duration = .milliseconds(120),
         onValuesChanged: @escaping @MainActor ([String: GWJSONValue]) async throws -> Void) {
        self.project = project
        self.overrideStore = overrideStore
        self.itemID = itemID
        self.capabilities = capabilities
        self.resourceActions = resourceActions
        self.coalescingDelay = coalescingDelay
        self.onValuesChanged = onValuesChanged
    }

    func load() async {
        guard !isSaving else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await refresh()
            isReady = true
            errorText = nil
        } catch {
            values = project.resolve(overrides: [:]).values
            isReady = false
            errorText = "无法读取已保存的作者设置：\(error.localizedDescription)"
        }
    }

    func canEdit(_ definition: AuthorPropertyDefinition) -> Bool {
        isReady && !isResourceBusy && capabilities.allows(definition, project: project, values: values)
            && (!isResource(definition) || resourceActions != nil)
    }

    func isModified(_ key: String) -> Bool {
        switch pending[key] ?? inFlight[key] {
        case .set: return true
        case .reset: return false
        case nil: return overrides[key] != nil
        }
    }

    var editableModifiedKeys: [String] {
        project.properties.filter { canEdit($0) && isModified($0.key) }.map(\.key)
    }

    func set(_ value: GWJSONValue, for definition: AuthorPropertyDefinition) {
        guard !isResource(definition) else { rejectUnsupported(); return }
        guard canEdit(definition) else { rejectUnsupported(); return }
        do {
            try definition.validate(value)
            values[definition.key] = value
            pending[definition.key] = .set(value)
            failedMutations.removeValue(forKey: definition.key)
            schedule()
        } catch { errorText = error.localizedDescription }
    }

    func reset(_ definition: AuthorPropertyDefinition) {
        if isResource(definition) { performResource(.reset, for: definition); return }
        guard canEdit(definition) else { rejectUnsupported(); return }
        values[definition.key] = project.resolve(overrides: [:]).values[definition.key]
        pending[definition.key] = .reset
        failedMutations.removeValue(forKey: definition.key)
        schedule()
    }

    func resetEditable() {
        guard isReady, !isSaving else { return }
        let modified = project.properties.filter { canEdit($0) && isModified($0.key) }
        let resources = modified.filter { isResource($0) }
        if !resources.isEmpty {
            runResources(resources.map { request(.reset, for: $0) }, scalarResets: modified.filter { !isResource($0) })
            return
        }
        // Deliberately avoid store.reset(itemID:): unknown and unsupported values must survive.
        for definition in modified {
            values[definition.key] = project.resolve(overrides: [:]).values[definition.key]
            pending[definition.key] = .reset
            failedMutations.removeValue(forKey: definition.key)
        }
        if !pending.isEmpty { schedule() }
    }

    func performResource(_ operation: AuthorPropertyResourceOperation, for definition: AuthorPropertyDefinition) {
        guard canEdit(definition), isResource(definition), !isSaving else { rejectUnsupported(); return }
        runResources([request(operation, for: definition)])
    }

    private func isResource(_ definition: AuthorPropertyDefinition) -> Bool {
        definition.kind == .file || definition.kind == .directory
    }

    private func request(_ operation: AuthorPropertyResourceOperation,
                         for definition: AuthorPropertyDefinition) -> AuthorPropertyResourceRequest {
        .init(itemID: itemID, project: project, definition: definition, operation: operation)
    }

    private func runResources(_ requests: [AuthorPropertyResourceRequest], scalarResets: [AuthorPropertyDefinition] = []) {
        guard let resourceActions, !isSaving else { return }
        isSaving = true
        isResourceBusy = true
        errorText = nil
        statusText = "正在处理所选资源…"
        drainTask = Task { @MainActor in
            defer { self.isSaving = false; self.isResourceBusy = false; self.drainTask = nil }
            var activeRequest = requests.first
            do {
                for resourceRequest in requests {
                    activeRequest = resourceRequest
                    // The service owns grant + override + manifest + host acknowledgement.
                    // Never also call the scalar callback for this resource operation.
                    try await resourceActions.perform(resourceRequest)
                }
                activeRequest = nil
                for definition in scalarResets {
                    do { try await overrideStore.set(nil, for: definition.key, itemID: itemID, project: project) }
                    catch { failedMutations[definition.key] = .reset; throw error }
                }
                try await refresh()
                if !scalarResets.isEmpty {
                    let payload = project.resolve(overrides: overrides).values.filter { capabilities.editableKeys.contains($0.key) }
                    do { try await onValuesChanged(payload) }
                    catch { savedButNotApplied = true; throw error }
                }
                resourceRetry = nil
                savedButNotApplied = false
                errorText = nil
                statusText = "设置已提交至\(capabilities.runtimeLabel)"
            } catch {
                try? await refresh()
                if let resourceRequest = activeRequest {
                    let persisted = (error as? AuthorPropertyResourceFailure)?.persisted == true
                    resourceRetry = persisted ? request(.retry, for: resourceRequest.definition) : resourceRequest
                    savedButNotApplied = persisted
                    errorText = persisted ? "资源设置已保存，但尚未应用：\(error.localizedDescription)"
                        : "资源设置未保存：\(error.localizedDescription)"
                } else {
                    errorText = savedButNotApplied ? "值已保存，但尚未应用到播放器：\(error.localizedDescription)"
                        : "部分默认值尚未保存：\(error.localizedDescription)"
                }
                statusText = nil
            }
        }
    }

    var canRetry: Bool { resourceRetry != nil || savedButNotApplied || !failedMutations.isEmpty }

    func retry() {
        guard isReady, canRetry, !isSaving else { return }
        if let resourceRetry { runResources([resourceRetry]); return }
        for (key, mutation) in failedMutations where pending[key] == nil {
            pending[key] = mutation
            applyDraft(mutation, key: key)
        }
        failedMutations.removeAll()
        reapplyRequested = true
        schedule()
    }

    /// Fixture/host coordination can await completion without observing arbitrary sleeps.
    func waitUntilIdle() async { await drainTask?.value }

    private func rejectUnsupported() {
        errorText = capabilities.unsupportedReason.isEmpty ? "当前播放器尚不支持修改此作者选项。" : capabilities.unsupportedReason
    }

    private func schedule() {
        statusText = "正在提交更改…"
        guard drainTask == nil else { return }
        isSaving = true
        drainTask = Task { @MainActor in
            defer { self.isSaving = false; self.drainTask = nil }
            await self.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty || reapplyRequested {
            // This task intentionally finishes explicit user edits even if the panel closes.
            try? await Task.sleep(for: coalescingDelay)
            let batch = pending
            inFlight = batch
            pending.removeAll()
            reapplyRequested = false
            var persisted = false
            do {
                for key in batch.keys.sorted() {
                    guard let definition = project.definition(for: key),
                          capabilities.allows(definition, project: project, values: values) else {
                        throw AuthorPropertyError(message: "播放器尚不支持此选项：\(key)")
                    }
                    switch batch[key]! {
                    case .set(let value): try await overrideStore.set(value, for: key, itemID: itemID, project: project)
                    case .reset: try await overrideStore.set(nil, for: key, itemID: itemID, project: project)
                    }
                }
                let stored = try await overrideStore.load(itemID: itemID)
                let resolution = project.resolve(overrides: stored)
                adopt(stored, resolution: resolution)
                persisted = true
                // Never forward unsupported file/directory/unknown values to a scalar-only host.
                let payload = resolution.values.filter { capabilities.editableKeys.contains($0.key) }
                try await onValuesChanged(payload)
                savedButNotApplied = false
                for key in batch.keys { failedMutations.removeValue(forKey: key) }
                if failedMutations.isEmpty {
                    errorText = nil
                    statusText = "设置已提交至\(capabilities.runtimeLabel)"
                } else {
                    statusText = "部分设置尚未保存，请重试。"
                }
            } catch {
                if persisted {
                    savedButNotApplied = true
                    errorText = "值已保存，但尚未应用到播放器：\(error.localizedDescription)"
                } else {
                    for (key, mutation) in batch where pending[key] == nil { failedMutations[key] = mutation }
                    errorText = "保存未完成，播放器尚未更新：\(error.localizedDescription)"
                }
                statusText = nil
                try? await refresh()
            }
            inFlight.removeAll()
        }
    }

    private func refresh() async throws {
        let stored = try await overrideStore.load(itemID: itemID)
        adopt(stored, resolution: project.resolve(overrides: stored))
    }

    private func adopt(_ stored: [String: GWJSONValue], resolution: AuthorPropertyResolution) {
        overrides = stored
        values = resolution.values
        diagnostics = resolution.diagnostics
        unknownOverrides = resolution.unknownOverrides
        for (key, mutation) in pending { applyDraft(mutation, key: key) }
    }

    private func applyDraft(_ mutation: Mutation, key: String) {
        switch mutation {
        case .set(let value): values[key] = value
        case .reset: values[key] = project.resolve(overrides: [:]).values[key]
        }
    }
}
