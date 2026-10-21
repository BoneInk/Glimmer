import Foundation

/// A Web result has no invented video probe, duration, or video URL.
struct WorkshopWebProject: Sendable, Equatable {
    var downloadRoot: URL
    var projectDirectory: URL
    var projectJSONURL: URL
    var entryURL: URL
    var projectJSONRelativePath: String
    /// Relative to projectDirectory, preserving the author's resource layout.
    var entryRelativePath: String
    var projectTitle: String?
    var projectPreviewFileName: String?
    var workshopID: String
    var declaredTags: [String]
    var totalByteSize: Int64
    var resourceCount: Int
    var contentFingerprint: String
    var diagnostics: [String]
}

/// A fully inspected renderable Scene subset; never a fabricated video probe.
struct WorkshopSceneProject: Sendable, Equatable {
    var downloadRoot: URL
    var projectDirectory: URL
    var projectJSONURL: URL
    var entryURL: URL
    var projectJSONRelativePath: String
    /// Relative to projectDirectory, preserving the author's resource layout.
    var entryRelativePath: String
    var projectTitle: String?
    var projectPreviewFileName: String?
    var workshopID: String
    var declaredTags: [String]
    var totalByteSize: Int64
    var resourceCount: Int
    var contentFingerprint: String
    var diagnostics: [String]
}

enum WorkshopResolvedProject: Sendable, Equatable {
    case video(WorkshopVideoProject)
    case web(WorkshopWebProject)
    case scene(WorkshopSceneProject)

    var videoProject: WorkshopVideoProject? { if case .video(let value) = self { return value }; return nil }
    var webProject: WorkshopWebProject? { if case .web(let value) = self { return value }; return nil }
    var sceneProject: WorkshopSceneProject? { if case .scene(let value) = self { return value }; return nil }
    var kind: WorkshopItemKind { switch self { case .video: .video; case .web: .web; case .scene: .scene } }
    var projectType: String { kind.rawValue }
    var projectRoot: URL { switch self { case .video(let v): v.projectRoot; case .web(let w): w.downloadRoot; case .scene(let w): w.downloadRoot } }
    var projectJSONURL: URL { switch self { case .video(let v): v.projectRoot.appendingPathComponent(v.projectJSONPath); case .web(let w): w.projectJSONURL; case .scene(let w): w.projectJSONURL } }
    var projectJSONPath: String { switch self { case .video(let v): v.projectJSONPath; case .web(let w): w.projectJSONRelativePath; case .scene(let w): w.projectJSONRelativePath } }
    var projectTitle: String? { switch self { case .video(let v): v.projectTitle; case .web(let w): w.projectTitle; case .scene(let w): w.projectTitle } }
    var projectPreviewFileName: String? { switch self { case .video(let v): v.projectPreviewFileName; case .web(let w): w.projectPreviewFileName; case .scene(let w): w.projectPreviewFileName } }
    var workshopID: String { switch self { case .video(let v): v.workshopID; case .web(let w): w.workshopID; case .scene(let w): w.workshopID } }
    var declaredTags: [String] { switch self { case .video(let v): v.declaredTags; case .web(let w): w.declaredTags; case .scene(let w): w.declaredTags } }
    var entryURL: URL { switch self { case .video(let v): v.videoURL; case .web(let w): w.entryURL; case .scene(let w): w.entryURL } }
    var totalByteSize: Int64 { switch self { case .video(let v): v.videoByteSize; case .web(let w): w.totalByteSize; case .scene(let w): w.totalByteSize } }
    var entryRelativePath: String? { webProject?.entryRelativePath ?? sceneProject?.entryRelativePath }
    var contentFingerprint: String? { webProject?.contentFingerprint ?? sceneProject?.contentFingerprint }
    var resourceCount: Int? { webProject?.resourceCount ?? sceneProject?.resourceCount }
}
