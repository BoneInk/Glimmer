import Foundation
import Darwin

/// Checks project structure and metadata. Packaged universal-backend builds
/// defer playback compatibility to the actual shader/script/GPU runtime.
struct SceneWallpaperProjectDescriptor: Sendable {
    let projectURL: URL
    let root: URL
    /// Actual loose entry or package containing the declared Scene entry.
    let entryURL: URL
    let declaredEntryPath: String
    let posterURL: URL?
    let title: String
    let inspection: SceneWallpaperInspection

    init(projectURL: URL) throws {
        let file = try WebProjectPaths.canonical(projectURL)
        guard file.lastPathComponent == "project.json" else { throw WebProjectError.invalid("请选择 Scene 项目的 project.json") }
        let root = file.deletingLastPathComponent()
        guard let json = try JSONSerialization.jsonObject(with: WebProjectPaths.readProject(file)) as? [String: Any],
              (json["type"] as? String)?.lowercased() == "scene", let entry = json["file"] as? String else {
            throw WebProjectError.invalid("该项目不是声明了入口的 Scene 壁纸")
        }
        _ = try ScenePackageArchive.normalizedPath(entry)
        func resource(_ relative: String) -> URL? {
            guard let normalized = try? ScenePackageArchive.normalizedPath(relative),
                  let result = try? WebProjectPaths.canonical(root.appendingPathComponent(normalized)),
                  result.path.hasPrefix(root.path + "/") else { return nil }
            var info = stat()
            guard lstat(root.appendingPathComponent(normalized).path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
            return result
        }
        guard let entryURL = resource(entry) ?? resource("scene.pkg") else {
            throw WebProjectError.invalid("Scene 本地入口或 scene.pkg 不存在")
        }
        let inspection: SceneWallpaperInspection
        #if GW_UNIVERSAL_SCENE_BACKEND
        if SceneBackendAvailability.isInstalled {
            inspection = try Self.structuralMetadata(projectURL: file, entry: entry)
        } else {
            inspection = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: file)
            guard inspection.isRenderableSubset else { throw WebProjectError.invalid(Self.unsupportedSummary(inspection.diagnostics)) }
        }
        #else
        inspection = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: file)
        guard inspection.isRenderableSubset else { throw WebProjectError.invalid(Self.unsupportedSummary(inspection.diagnostics)) }
        #endif
        self.projectURL = file; self.root = root; self.entryURL = entryURL; self.declaredEntryPath = entry
        self.posterURL = (json["preview"] as? String).flatMap(resource)
        self.title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? root.lastPathComponent
        self.inspection = inspection
    }

    #if GW_UNIVERSAL_SCENE_BACKEND
    /// Import checks a complete document, never claims successful GPU playback.
    /// Playback capability is checked by the generic backend, not by the old
    /// finite renderer or an identifier-specific download exception.
    private static func structuralMetadata(projectURL: URL, entry: String) throws -> SceneWallpaperInspection {
        let limits = SceneReadLimits()
        let source = try SceneAssetSource(rootURL: projectURL.deletingLastPathComponent(), limits: limits)
        let scenePath: String
        if entry.lowercased().hasSuffix(".pkg") { try source.useArchive(entry); scenePath = "scene.json" }
        else if source.containsLoose(entry) { scenePath = entry }
        else { try source.useArchive("scene.pkg"); scenePath = entry }
        guard let scene = try JSONSerialization.jsonObject(with: source.read(scenePath, maximumBytes: limits.maximumJSONBytes)) as? [String: Any],
              let objects = scene["objects"] as? [[String: Any]], !objects.isEmpty, objects.count <= 4096 else {
            throw WebProjectError.invalid("Scene 场景文件无效或超过图层数量限制")
        }
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any]
        func dimension(_ name: String) throws -> Double {
            guard let value = projection?[name] else { return 0 }
            let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? .nan
            guard number.isFinite, number > 0, number <= 16_384 else { throw WebProjectError.invalid("Scene 画布尺寸无效") }
            return number
        }
        // Metadata-only and deliberately not renderable by the legacy backend.
        return .init(canvasSize: .init(x: try dimension("width"), y: try dimension("height")),
            clearColor: .init(x: 0, y: 0, z: 0), layers: [], textures: [:],
            diagnostics: [.init(severity: .unsupported, path: "runtime", message: "Playback readiness is checked by the universal Scene backend.")])
    }
    #endif

    /// Keep technical paths in the inspection report; the download toast names
    /// the missing capabilities without dumping a multiline engine log.
    static func unsupportedSummary(_ diagnostics: [SceneDiagnostic]) -> String {
        var capabilities: [String] = []
        for diagnostic in diagnostics {
            let path = diagnostic.path.lowercased()
            let category: String
            if diagnostic.severity == .missing, SceneEngineAssetResolver.requiredResources.contains(diagnostic.path) { category = "内置纹理资源缺失" }
            else if path.contains("particle") { category = diagnostic.severity == .missing ? "粒子内置资源缺失" : "粒子与拖尾渲染" }
            else if path.contains("copybackground") { category = "背景采样" }
            else if path.contains("bloom") || path.contains("hdr") { category = "光照与泛光" }
            else if path.contains("parallax") { category = "相机视差" }
            else if path.contains("camera") || path.contains("nearz") || path.contains("farz") || path.contains("zoom") { category = "相机效果" }
            else if path.contains("effects") || path.contains("material") || diagnostic.message.lowercased().contains("shader") { category = "材质与图层特效" }
            else if path.contains("script") || diagnostic.message.lowercased().contains("script") { category = "场景脚本" }
            else { category = "其他场景功能" }
            if !capabilities.contains(category) { capabilities.append(category) }
        }
        guard !capabilities.isEmpty else { return "此 Scene 暂时无法播放。" }
        let priorities = ["内置纹理资源缺失", "粒子内置资源缺失", "粒子与拖尾渲染", "材质与图层特效", "光照与泛光"]
        capabilities.sort { (priorities.firstIndex(of:$0) ?? priorities.count) < (priorities.firstIndex(of:$1) ?? priorities.count) }
        return "此 Scene 仍需未支持的功能：" + capabilities.prefix(4).joined(separator: "、") + "。"
    }

}
