import Foundation
import IOSurface

/// Shared wire contract, compiled independently into the native app and GPL helper framework.
/// No upstream internal types cross this boundary; this original contract retains MIT notices.
public struct SceneBackendRoots: Codable, Sendable {
    public let projectRoot: URL
    public let assetsRoot: URL
    public let cacheRoot: URL
    public let projectDigest: String
    public let assetsManifestDigest: String
    public init(projectRoot: URL, assetsRoot: URL, cacheRoot: URL, projectDigest: String, assetsManifestDigest: String) {
        self.projectRoot = projectRoot
        self.assetsRoot = assetsRoot
        self.cacheRoot = cacheRoot
        self.projectDigest = projectDigest
        self.assetsManifestDigest = assetsManifestDigest
    }
}

public struct SceneBackendConfiguration: Codable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let generation: UInt64
    public let roots: SceneBackendRoots
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let properties: [String: String]
    public init(protocolVersion: Int, sessionID: UUID, generation: UInt64, roots: SceneBackendRoots, width: Int, height: Int, framesPerSecond: Int, properties: [String: String]) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.generation = generation
        self.roots = roots
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.properties = properties
    }
}

public struct SceneFrameInput: Codable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public let sequence: UInt64
    public let elapsedSeconds: Double
    /// Coordinates in output pixels, origin bottom-left; both nil while outside the scene.
    public let cursorX: Float?
    public let cursorY: Float?
    public let leftMouseDown: Bool
    public init(sessionID: UUID, generation: UInt64, sequence: UInt64, elapsedSeconds: Double, cursorX: Float?, cursorY: Float?, leftMouseDown: Bool) {
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
        self.elapsedSeconds = elapsedSeconds
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.leftMouseDown = leftMouseDown
    }
}

public struct SceneFrameToken: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public let sequence: UInt64
    public let slotID: UUID
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: String
    public init(sessionID: UUID, generation: UInt64, sequence: UInt64, slotID: UUID, width: Int, height: Int, bytesPerRow: Int, pixelFormat: String) {
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
        self.slotID = slotID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
    }
}

public struct SceneBackendDiagnostic: Codable, Sendable {
    public let code: String
    public let resource: String?
    public let message: String
    public init(code: String, resource: String?, message: String) {
        self.code = code
        self.resource = resource
        self.message = message
    }
}

/// Structured failure detail that crosses the XPC boundary without leaking engine internals into
/// user-facing text: a stable code/category, a concise Chinese message and a bounded technical
/// detail for local reports. A missing resource is never turned into a blind re-download.
public struct SceneBackendFailureDetail: Codable, Sendable, Equatable {
    public static let userInfoKey = "GWSceneBackendFailureDetail"
    public static let categoryMissingResources = "missingResources"
    public static let categoryUnsupportedCapability = "unsupportedCapability"
    public static let categoryShaderFailure = "shaderFailure"
    public static let categoryScriptFailure = "scriptFailure"
    public static let categoryInvalidConfiguration = "invalidConfiguration"
    public static let categoryRuntimeFailure = "runtimeFailure"

    public let code: String
    public let category: String
    public let userMessage: String
    public let technicalDetail: String?
    public let missingResources: [String]

    public init(code: String, category: String, userMessage: String,
                technicalDetail: String? = nil, missingResources: [String] = []) {
        self.code = code
        self.category = category
        self.userMessage = userMessage
        self.technicalDetail = technicalDetail
        self.missingResources = missingResources
    }

    /// The concise Chinese message for a category; the UI shows this, never a raw engine string.
    public static func message(for category: String) -> String {
        switch category {
        case SceneBackendFailureDetail.categoryMissingResources:
            return "Scene 缺少必需资源，已保留具体文件列表，未自动重复下载。"
        case SceneBackendFailureDetail.categoryUnsupportedCapability:
            return "此 Scene 使用了当前尚未接入的能力，未以降级画面冒充成功。"
        case SceneBackendFailureDetail.categoryShaderFailure:
            return "Scene 着色器编译失败，无法按原作渲染。"
        case SceneBackendFailureDetail.categoryScriptFailure:
            return "Scene 脚本运行失败。"
        case SceneBackendFailureDetail.categoryInvalidConfiguration:
            return "Scene 配置或参数无效。"
        default:
            return "Scene 渲染准备失败。"
        }
    }
}

/// A readiness claim needs positive structured evidence, not renderer.hasContent alone.
public struct SceneBackendReadiness: Codable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public let projectDigest: String
    public let assetsManifestDigest: String
    public let authoredDrawableIDs: [String]
    public let accountedDrawableIDs: [String]
    public let fallbackDrawableIDs: [String]
    public let unresolvedResources: [String]
    public let scriptErrors: [SceneBackendDiagnostic]
    public let pipelineFailureCount: Int
    public let exactFontsResolved: Bool
    public let requiredVideoStreamsReady: Bool
    /// Authored sound objects whose original files were decoded and whose playback layer is
    /// prepared: positive evidence, not a claim that sound is audible.
    public let auditedSoundObjectIDs: [String]
    public let gpuFrameCompleted: Bool
    public let capabilityAuditCompleted: Bool
    public let diagnostics: [SceneBackendDiagnostic]

    public var isStrictlyReady: Bool {
        capabilityAuditCompleted && gpuFrameCompleted && exactFontsResolved && requiredVideoStreamsReady
        && pipelineFailureCount == 0 && unresolvedResources.isEmpty && scriptErrors.isEmpty
        && fallbackDrawableIDs.isEmpty && diagnostics.isEmpty
        && !authoredDrawableIDs.isEmpty && !authoredDrawableIDs.contains("")
        && Set(authoredDrawableIDs).count == authoredDrawableIDs.count
        && Set(accountedDrawableIDs).count == accountedDrawableIDs.count
        && Set(authoredDrawableIDs) == Set(accountedDrawableIDs)
    }
    public init(sessionID: UUID, generation: UInt64, projectDigest: String, assetsManifestDigest: String, authoredDrawableIDs: [String], accountedDrawableIDs: [String], fallbackDrawableIDs: [String], unresolvedResources: [String], scriptErrors: [SceneBackendDiagnostic], pipelineFailureCount: Int, exactFontsResolved: Bool, requiredVideoStreamsReady: Bool, auditedSoundObjectIDs: [String], gpuFrameCompleted: Bool, capabilityAuditCompleted: Bool, diagnostics: [SceneBackendDiagnostic]) {
        self.sessionID = sessionID
        self.generation = generation
        self.projectDigest = projectDigest
        self.assetsManifestDigest = assetsManifestDigest
        self.authoredDrawableIDs = authoredDrawableIDs
        self.accountedDrawableIDs = accountedDrawableIDs
        self.fallbackDrawableIDs = fallbackDrawableIDs
        self.unresolvedResources = unresolvedResources
        self.scriptErrors = scriptErrors
        self.pipelineFailureCount = pipelineFailureCount
        self.exactFontsResolved = exactFontsResolved
        self.requiredVideoStreamsReady = requiredVideoStreamsReady
        self.auditedSoundObjectIDs = auditedSoundObjectIDs
        self.gpuFrameCompleted = gpuFrameCompleted
        self.capabilityAuditCompleted = capabilityAuditCompleted
        self.diagnostics = diagnostics
    }
}

/// Each active Scene owns one service process. Connections to the same identifier share a process.
public enum SceneBackendServiceCatalog {
    /// Kept in the independently compiled wire-contract target so the helper
    /// never depends on app-only source files.
    public static let servicePrefix = "com.boneink.Glimmer.SceneBackend"
    public static let identifiers: [String] = (0..<8).map {
        $0 == 0 ? servicePrefix : "\(servicePrefix).slot\($0)"
    }
    public static let bundleNames: [String] = (0..<8).map {
        $0 == 0 ? "SceneBackendHelper.xpc" : "SceneBackendHelperSlot\($0).xpc"
    }
}

public struct SceneBackendProcessStatus: Codable, Sendable {
    public let helperPID: Int32
    public let instanceID: UUID
    public let sessionID: UUID?
    public let generation: UInt64?
    public let ownsSession: Bool
    public let frameRateLimit: Int?
    public let aspectFill: Bool?
    public let sceneSeconds: Double?
    public let paused: Bool?
    /// Real helper-side sound state: default false until the app forwards the user's intent.
    public let soundEnabled: Bool?
    public let soundVolume: Double?
    /// Authored sound layers prepared in the renderer, and how many voices are actually playing.
    public let soundsPrepared: Int?
    public let soundPlaying: Int?
    /// The last property revision the helper accepted (proves updates were applied, not ACKed).
    public let propertyRevision: UInt64?
    public init(helperPID: Int32, instanceID: UUID, sessionID: UUID?, generation: UInt64?, ownsSession: Bool, frameRateLimit: Int? = nil, aspectFill: Bool? = nil, sceneSeconds: Double? = nil, paused: Bool? = nil, soundEnabled: Bool? = nil, soundVolume: Double? = nil, soundsPrepared: Int? = nil, soundPlaying: Int? = nil, propertyRevision: UInt64? = nil) {
        self.helperPID = helperPID; self.instanceID = instanceID
        self.sessionID = sessionID; self.generation = generation; self.ownsSession = ownsSession
        self.frameRateLimit = frameRateLimit; self.aspectFill = aspectFill; self.sceneSeconds = sceneSeconds; self.paused = paused
        self.soundEnabled = soundEnabled; self.soundVolume = soundVolume
        self.soundsPrepared = soundsPrepared; self.soundPlaying = soundPlaying
        self.propertyRevision = propertyRevision
    }
}

/// IOSurface already conforms to NSSecureCoding in the macOS SDK.
/// Use the object capability, not a globally discoverable numeric surface ID.
@objc(GWSceneBackendRemote) public protocol SceneBackendRemote {
    func status(reply: @escaping (Data) -> Void)
    func prepare(_ configuration: Data, reply: @escaping (Data?, NSError?) -> Void)
    func render(_ input: Data, reply: @escaping (Data?, IOSurface?, NSError?) -> Void)
    func acknowledge(_ frameToken: Data, reply: @escaping (NSError?) -> Void)
    func updateProperties(_ properties: Data, revision: UInt64, reply: @escaping (NSError?) -> Void)
    func setFrameRateLimit(_ fps: Int, reply: @escaping (NSError?) -> Void)
    func setAspectFill(_ fill: Bool, reply: @escaping (NSError?) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (NSError?) -> Void)
    func setSceneSound(_ enabled: Bool, volume: Double, reply: @escaping (NSError?) -> Void)
    func close(_ sessionID: UUID, generation: UInt64, reply: @escaping () -> Void)
}
