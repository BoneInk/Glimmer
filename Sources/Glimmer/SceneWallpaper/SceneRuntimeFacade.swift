#if GW_UNIVERSAL_SCENE_BACKEND
import AppKit
import CoreVideo
import Foundation
import Observation

/// One application-facing Scene API. Packaged builds use the shared community
/// renderer for every Scene; the finite native renderer remains a rollback and
/// isolated-test implementation, never a per-wallpaper compatibility exception.
@MainActor @Observable
final class SceneWallpaperRuntime {
    typealias State = LegacySceneWallpaperRuntime.State
    let projectURL: URL
    private let universal: UniversalSceneBackendRuntime?
    private let legacy: LegacySceneWallpaperRuntime?

    var hostView: NSView { universal?.hostView ?? legacy!.hostView }
    var state: State { universal.flatMap { State(rawValue: $0.state.rawValue) } ?? legacy?.state ?? .disposed }
    var lastError: String? { universal?.lastError ?? legacy?.lastError }
    var lastFailureDetail: SceneBackendFailureDetail? { universal?.lastFailureDetail }
    var readiness: SceneBackendReadiness? { universal?.readiness }
    var posterImage: CGImage? { universal?.posterImage ?? legacy?.posterImage }
    var inspection: SceneWallpaperInspection? { legacy?.inspection }
    var editablePropertyKeys: Set<String> { universal?.editablePropertyKeys ?? legacy?.editablePropertyKeys ?? [] }
    var isAnimated: Bool { universal != nil ? state == .ready || state == .paused : legacy?.isAnimated ?? false }
    var frameCount: Int { universal?.frameCount ?? legacy?.frameCount ?? 0 }
    var activeRuntime: Double { universal?.activeRuntime ?? legacy?.activeRuntime ?? 0 }
    var frameRateLimit: Int { universal?.frameRateLimit ?? legacy?.frameRateLimit ?? 30 }
    var screenResolution: SceneVector2? { universal?.screenResolution ?? legacy?.screenResolution }
    var lastFrameInput: SceneScriptInputSnapshot { legacy?.lastFrameInput ?? .init() }
    var usesUniversalBackend: Bool { universal != nil }
    var supportsManualFrameExport: Bool { universal != nil }
    var backendProcessStatus: SceneBackendProcessStatus? { universal?.processStatus }
    var sceneLoadTimingMilliseconds: [String: Double] { universal?.sceneLoadTimingMilliseconds ?? [:] }
    var shaderCacheRestoredFiles: Int { universal?.shaderCacheRestoredFiles ?? 0 }

    init(projectURL: URL, inspectionBarrier: (@Sendable () async throws -> Void)? = nil,
         workerExecutableURL: URL? = nil, screenResolution: SceneVector2? = nil,
         followsHostScreen: Bool = false, engineAssets: SceneEngineAssetBundle? = nil,
         manualFrameExport: Bool = false) throws {
        self.projectURL = projectURL
        if SceneBackendAvailability.isInstalled, inspectionBarrier == nil,
           workerExecutableURL == nil, engineAssets == nil {
            universal = try UniversalSceneBackendRuntime(projectURL: projectURL,
                screenResolution: screenResolution, followsHostScreen: followsHostScreen,
                manualFrameExport: manualFrameExport)
            legacy = nil
        } else {
            universal = nil
            legacy = try LegacySceneWallpaperRuntime(projectURL: projectURL,
                inspectionBarrier: inspectionBarrier, workerExecutableURL: workerExecutableURL,
                screenResolution: screenResolution, followsHostScreen: followsHostScreen, engineAssets: engineAssets)
        }
    }

    func load(propertiesJSON: Data) async throws {
        if let universal { try await universal.load(propertiesJSON: propertiesJSON) }
        else { try await legacy!.load(propertiesJSON: propertiesJSON) }
    }
    func applyPropertiesAndWait(_ payload: Data) async throws {
        if let universal { try await universal.applyPropertiesAndWait(payload) }
        else { try await legacy!.applyPropertiesAndWait(payload) }
    }
    func updateScreenResolutionAndWait(_ size: SceneVector2) async throws {
        if let universal { try await universal.updateScreenResolutionAndWait(size) }
        else { try await legacy!.updateScreenResolutionAndWait(size) }
    }
    func setAspectFill(_ value: Bool) { universal?.setAspectFill(value); legacy?.setAspectFill(value) }
    /// Scene sound is a universal-backend capability; the legacy fallback has no audio player and
    /// never pretends it applied the intent.
    func setSceneSound(enabled: Bool, volume: Double) { universal?.setSceneSound(enabled: enabled, volume: volume) }
    func setFrameRateLimit(_ value: Int) throws {
        if let universal { try universal.setFrameRateLimit(value) }
        else { try legacy!.setFrameRateLimit(value) }
    }
    func setPaused(_ value: Bool) { universal?.setPaused(value); legacy?.setPaused(value) }
    func renderManualFrame(elapsed: Double, into pixelBuffer: CVPixelBuffer) async throws {
        guard let universal else { throw SceneManualFrameError.notInManualMode }
        try await universal.renderManualFrame(elapsed: elapsed, into: pixelBuffer)
    }
    func currentHelperSceneSeconds() async throws -> Double? {
        guard let universal else { throw SceneManualFrameError.notInManualMode }
        return try await universal.currentHelperSceneSeconds()
    }
    func dispose() { universal?.dispose(); legacy?.dispose() }
    static func physicalScreenResolution(displayID: UInt32) -> SceneVector2? {
        LegacySceneWallpaperRuntime.physicalScreenResolution(displayID: displayID)
    }
}

enum SceneBackendAvailability {
    static var isInstalled: Bool {
        let services = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        return SceneBackendServiceCatalog.bundleNames.allSatisfy {
            FileManager.default.fileExists(atPath: services.appendingPathComponent($0).path)
        }
    }
}
#endif
