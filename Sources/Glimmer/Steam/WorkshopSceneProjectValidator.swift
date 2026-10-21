import Foundation

/// Real Scene dependency/texture inspection plus bounded complete-tree hash.
/// No scripts, shaders, or arbitrary author code are executed.
enum WorkshopSceneProjectValidator {
    static func validate(projectFile: URL, downloadRoot: URL, workshopID: String,
        declaredTags: [String], projectTitle: String? = nil, diagnostics: [String]) throws -> WorkshopSceneProject {
        do {
            let descriptor = try SceneWallpaperProjectDescriptor(projectURL: projectFile)
            guard WorkshopProjectResolver.isInside(descriptor.projectURL, root: downloadRoot) else { throw invalid("Scene 项目配置超出下载目录") }
            let root = try WebProjectPaths.canonical(descriptor.root)
            let canonicalDownloadRoot = try WebProjectPaths.canonical(downloadRoot)
            let excluded = GlimmerIdentity.downloadManifestNames.map {
                canonicalDownloadRoot.appendingPathComponent($0)
            }
            let tree = try WorkshopProjectTreeValidator.validate(
                root: root, excluded: excluded, label: "Scene", ordering: .utf8)
            #if GW_UNIVERSAL_SCENE_BACKEND
            let report = diagnostics + ["Scene 项目结构、完整文件树和内容哈希已校验；播放时由通用渲染器检查着色器、脚本及 GPU 管线"]
            #else
            let report = diagnostics + ["已验证受支持的二维 Scene 图层与本地资源；内联脚本将在运行时进一步验证，自定义 shader 等功能尚未支持"]
            #endif
            let current = try SceneWallpaperProjectDescriptor(projectURL: descriptor.projectURL)
            guard current.entryURL == descriptor.entryURL else { throw invalid("Scene 入口在校验期间发生变化") }
            return WorkshopSceneProject(downloadRoot: try WebProjectPaths.canonical(downloadRoot),
                projectDirectory: root, projectJSONURL: descriptor.projectURL, entryURL: descriptor.entryURL,
                projectJSONRelativePath: WorkshopProjectResolver.relativePath(of: descriptor.projectURL, from: downloadRoot),
                entryRelativePath: WorkshopProjectResolver.relativePath(of: descriptor.entryURL, from: root),
                projectTitle: projectTitle,
                projectPreviewFileName: descriptor.posterURL.map { WorkshopProjectResolver.relativePath(of: $0, from: root) },
                workshopID: workshopID, declaredTags: declaredTags, totalByteSize: tree.totalByteSize,
                resourceCount: tree.entries.count,
                contentFingerprint: tree.contentFingerprint, diagnostics: report)
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorkshopDownloadError { throw error }
        catch { throw invalid(error.localizedDescription) }
    }

    private static func invalid(_ text: String) -> WorkshopDownloadError { .validationFailed(reason: text) }
}
