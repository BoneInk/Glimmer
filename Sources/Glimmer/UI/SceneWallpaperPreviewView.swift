import AppKit
import Observation
import SwiftUI

/// Independent real Scene host. Preview changes never alter desktop assignments.
struct SceneWallpaperPreviewView: View {
    let item: WallpaperItem
    let isPaused: Bool
    let storage: AppStorage
    var wallpaperFPS = 30
    /// The preview's scene-music intent; default muted so opening a preview never makes sound.
    var soundEnabled = false
    var soundVolume = 1.0
    /// Borrowed from the active detail route so the already-running Scene
    /// session is handed to this view instead of being initialized again.
    var previewModel: SceneWallpaperPreviewModel? = nil
    var onControlsStateChange: ((UUID, ScenePreviewControlsState) -> Void)? = nil
    var onReady: (() -> Void)? = nil
    var onFailure: ((String) -> Void)? = nil
    @GlassState private var ownedModel = SceneWallpaperPreviewModel()
    private var model: SceneWallpaperPreviewModel { previewModel ?? ownedModel }
    private var revision: Int { AuthorPropertyServices.shared.revisions[item.id, default: 0] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let runtime = model.runtime {
                SceneWallpaperPreviewHost(runtime: runtime).id(ObjectIdentifier(runtime))
            } else if model.error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let runtime = model.runtime, runtime.state == .loading || runtime.state == .idle {
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error ?? model.runtime?.lastError {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label("Scene 预览已停止", systemImage: "exclamationmark.triangle")
                                .font(.callout.weight(.semibold))
                            Spacer(minLength: 8)
                            Button("重试") {
                                Task { await model.retry(item: item, paused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS) }
                            }.buttonStyle(.glass).controlSize(.small)
                                .accessibilityIdentifier("scene-preview-retry")
                        }
                        Text(SceneWallpaperPresentation.errorSummary(error))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.9))
                .accessibilityIdentifier("scene-preview-error")
            }
        }
        .task(id: "\(item.id):\(revision)") {
            guard !Task.isCancelled else { return }
            if previewModel == nil { ownedModel.activate() }
            await model.update(item: item, paused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS,
                               soundEnabled: soundEnabled, soundVolume: soundVolume)
        }
        .onChange(of: isPaused) { _, value in model.setPaused(value) }
        .onChange(of: wallpaperFPS) { _, value in model.setWallpaperFPS(value) }
        .onChange(of: soundEnabled) { _, _ in model.setSceneSound(enabled: soundEnabled, volume: soundVolume) }
        .onChange(of: soundVolume) { _, _ in model.setSceneSound(enabled: soundEnabled, volume: soundVolume) }
        .onChange(of: model.controlsState, initial: true) { _, state in
            onControlsStateChange?(item.id, state)
            if !state.hasError, state.phase == .ready || state.phase == .paused { onReady?() }
            else if state.hasError || state.phase == .failed {
                onFailure?(model.error ?? model.runtime?.lastError ?? "Scene 预览无法加载")
            }
        }
        .onDisappear {
            // A route-owned model outlives this borrowed view. Only a
            // standalone preview tears down its own engine here.
            if previewModel == nil { ownedModel.dispose() }
        }
        .accessibilityIdentifier("scene-wallpaper-preview")
    }
}

private struct SceneWallpaperPreviewHost: NSViewRepresentable {
    let runtime: SceneWallpaperRuntime
    func makeNSView(context: Context) -> NSView { runtime.hostView }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor @Observable
final class SceneWallpaperPreviewModel {
    private(set) var runtime: SceneWallpaperRuntime?
    private(set) var error: String?
    @ObservationIgnored private(set) var loadTimingMilliseconds: [String: Double] = [:]
    @ObservationIgnored private var itemID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var desiredPaused = false
    @ObservationIgnored private var desiredWallpaperFPS = 30
    @ObservationIgnored private var desiredSoundEnabled = false
    @ObservationIgnored private var desiredSoundVolume = 1.0
    @ObservationIgnored private var sentSound: (enabled: Bool, volume: Double)?
    @ObservationIgnored private var hostToken: UUID?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadItemID: UUID?
    @ObservationIgnored private var loadedRevision: Int?
    @ObservationIgnored private var requestedRevision = 0
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var applyTicket: UUID?
    @ObservationIgnored private var preferredScreenResolution: SceneVector2?

    var controlsState: ScenePreviewControlsState {
        .init(phase: runtime.flatMap { ScenePreviewControlsState.Phase(rawValue: $0.state.rawValue) } ?? .unavailable,
              hasError: error != nil || runtime?.lastError != nil)
    }

    func activate() { closed = false }
    func retry(item: WallpaperItem, paused: Bool, storage: AppStorage, wallpaperFPS: Int = 30,
               screenResolution: SceneVector2? = nil) async {
        guard !closed, !Task.isCancelled else { return }
        let resolution = screenResolution ?? preferredScreenResolution
        reset(clearPreferredScreen: false)
        preferredScreenResolution = resolution
        await update(item: item, paused: paused, storage: storage, wallpaperFPS: wallpaperFPS,
                     screenResolution: resolution)
    }

    /// Idempotent for the current item. Concurrent callers await the one
    /// existing load task; they never start a second runtime or load session.
    func update(item: WallpaperItem, paused: Bool, storage: AppStorage, wallpaperFPS: Int = 30,
                screenResolution: SceneVector2? = nil,
                soundEnabled: Bool = false, soundVolume: Double = 1) async {
        guard !closed, !Task.isCancelled else { return }
        if itemID != item.id {
            let resolution = screenResolution ?? preferredScreenResolution
            reset(clearPreferredScreen: false)
            preferredScreenResolution = resolution
            itemID = item.id
        } else if let screenResolution {
            preferredScreenResolution = screenResolution
        }
        desiredPaused = paused
        desiredWallpaperFPS = min(max(wallpaperFPS, 1), 240)
        desiredSoundEnabled = soundEnabled
        desiredSoundVolume = soundVolume.isFinite ? min(max(soundVolume, 0), 1) : 1

        requestedRevision = max(requestedRevision,
            AuthorPropertyServices.shared.revisions[item.id, default: 0])

        if let loadTask {
            if loadItemID == item.id {
                await loadTask.value
            } else {
                reset(clearPreferredScreen: false)
                itemID = item.id
                await beginInitialLoad(item: item, storage: storage)
            }
        } else if runtime == nil, error == nil {
            await beginInitialLoad(item: item, storage: storage)
        }

        guard !closed, !Task.isCancelled, let target = runtime else { return }
        try? target.setFrameRateLimit(desiredWallpaperFPS)
        target.setPaused(desiredPaused)
        applySound(to: target)
        guard target.state == .ready || target.state == .paused else { return }
        await applyPendingRevision(item: item, storage: storage)
    }

    private func beginInitialLoad(item: WallpaperItem, storage: AppStorage) async {
        generation += 1
        let ticket = generation
        let revision = AuthorPropertyServices.shared.revisions[item.id, default: 0]
        requestedRevision = max(requestedRevision, revision)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadInitially(item: item, storage: storage, ticket: ticket, revision: revision)
        }
        loadTask = task
        loadItemID = item.id
        await task.value
        if generation == ticket, loadItemID == item.id {
            loadTask = nil
            loadItemID = nil
        }
    }

    private func loadInitially(item: WallpaperItem, storage: AppStorage,
                               ticket: Int, revision: Int) async {
        var token: UUID?
        let started = ContinuousClock.now
        loadTimingMilliseconds = [:]
        func record(_ phase: String, since start: ContinuousClock.Instant) {
            guard generation == ticket, !closed else { return }
            let elapsed = start.duration(to: .now).components
            loadTimingMilliseconds[phase] = Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1e15
        }
        defer { record("total", since: started) }
        do {
            let payload = try await AuthorPropertyServices.payload(item: item, storage: storage)
            record("authorPayload", since: started)
            try Task.checkCancellation()
            guard !closed, generation == ticket else { return }
            let initialization = ContinuousClock.now
            let created = try SceneWallpaperRuntime(
                projectURL: item.fileURL, screenResolution: preferredScreenResolution,
                followsHostScreen: true)
            record("runtimeInitialization", since: initialization)
            try Task.checkCancellation()
            guard !closed, generation == ticket else {
                created.dispose()
                return
            }
            runtime = created
            try created.setFrameRateLimit(desiredWallpaperFPS)
            created.setPaused(desiredPaused)
            token = AuthorPropertyServices.shared.registerScene(created, itemID: item.id,
                onConfigurationChange: { [weak self] in
                    // The runtime reports any new rendering failure. An external
                    // author update must not invalidate the initial load ticket.
                    self?.error = nil
                })
            hostToken = token
            let loadStart = ContinuousClock.now
            try await created.load(propertiesJSON: payload)
            record("runtimeLoad", since: loadStart)
            try Task.checkCancellation()
            guard !closed, generation == ticket, runtime === created else {
                if let token, hostToken == token {
                    AuthorPropertyServices.shared.unregisterScene(itemID: item.id, token: token)
                    hostToken = nil
                }
                created.dispose()
                return
            }
            loadedRevision = revision
            requestedRevision = max(requestedRevision,
                AuthorPropertyServices.shared.revisions[item.id, default: 0])
            error = nil
            created.setPaused(desiredPaused)
            sentSound = nil
            applySound(to: created)
        } catch is CancellationError { }
        catch {
            guard !closed, generation == ticket else { return }
            self.error = error.localizedDescription
        }
    }

    private func applyPendingRevision(item: WallpaperItem, storage: AppStorage) async {
        guard !closed, !Task.isCancelled, runtime != nil else { return }
        requestedRevision = max(requestedRevision,
            AuthorPropertyServices.shared.revisions[item.id, default: 0])
        if let applyTask, let applyTicket {
            await applyTask.value
            if self.applyTicket == applyTicket {
                self.applyTask = nil
                self.applyTicket = nil
            }
            guard !closed, !Task.isCancelled, error == nil,
                  loadedRevision != requestedRevision else { return }
            await applyPendingRevision(item: item, storage: storage)
            return
        }
        guard let target = runtime,
              target.state == .ready || target.state == .paused,
              loadedRevision != requestedRevision else { return }

        let ticket = generation
        let applyTicket = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRevisionUpdates(item: item, storage: storage, ticket: ticket)
        }
        applyTask = task
        self.applyTicket = applyTicket
        await task.value
        if self.applyTicket == applyTicket {
            applyTask = nil
            self.applyTicket = nil
        }
        guard !closed, !Task.isCancelled, error == nil,
              loadedRevision != requestedRevision else { return }
        await applyPendingRevision(item: item, storage: storage)
    }

    private func drainRevisionUpdates(item: WallpaperItem, storage: AppStorage,
                                      ticket: Int) async {
        while !closed, !Task.isCancelled, generation == ticket {
            requestedRevision = max(requestedRevision,
                AuthorPropertyServices.shared.revisions[item.id, default: 0])
            guard let target = runtime,
                  target.state == .ready || target.state == .paused,
                  loadedRevision != requestedRevision else { return }
            let revision = requestedRevision
            do {
                let payload = try await AuthorPropertyServices.payload(item: item, storage: storage)
                try Task.checkCancellation()
                guard !closed, generation == ticket, runtime === target,
                      requestedRevision >= revision else { return }
                try await target.applyPropertiesAndWait(payload)
                try Task.checkCancellation()
                guard !closed, generation == ticket, runtime === target else { return }
                loadedRevision = revision
                error = nil
                target.setPaused(desiredPaused)
                applySound(to: target)
            } catch is CancellationError {
                return
            } catch {
                guard !closed, generation == ticket, runtime === target else { return }
                self.error = error.localizedDescription
                return
            }
        }
    }

    func setPaused(_ value: Bool) { desiredPaused = value; runtime?.setPaused(value) }
    /// Sends the preview's sound intent only when it changed (or after a fresh load); the runtime
    /// reads the helper's real state back.
    private func applySound(to target: SceneWallpaperRuntime) {
        let desired = (enabled: desiredSoundEnabled, volume: desiredSoundVolume)
        guard sentSound == nil || sentSound! != desired else { return }
        sentSound = desired
        target.setSceneSound(enabled: desired.enabled, volume: desired.volume)
    }
    func setSceneSound(enabled: Bool, volume: Double) {
        desiredSoundEnabled = enabled
        desiredSoundVolume = volume.isFinite ? min(max(volume, 0), 1) : 1
        if let runtime { applySound(to: runtime) }
    }
    func setWallpaperFPS(_ value: Int) {
        desiredWallpaperFPS = min(max(value, 1), 240)
        try? runtime?.setFrameRateLimit(desiredWallpaperFPS)
    }
    func dispose() { closed = true; reset(clearPreferredScreen: true) }
    private func reset(clearPreferredScreen: Bool = true) {
        generation += 1
        loadTask?.cancel(); loadTask = nil; loadItemID = nil
        applyTask?.cancel(); applyTask = nil; applyTicket = nil
        if let itemID, let hostToken { AuthorPropertyServices.shared.unregisterScene(itemID: itemID, token: hostToken) }
        hostToken = nil
        runtime?.dispose()
        runtime = nil
        sentSound = nil
        itemID = nil
        loadedRevision = nil
        requestedRevision = 0
        error = nil
        if clearPreferredScreen { preferredScreenResolution = nil }
    }
}
