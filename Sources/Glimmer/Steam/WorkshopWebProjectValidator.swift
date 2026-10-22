import Foundation

/// Structural validation only. Does not execute HTML/JavaScript, fetch remote
/// dependencies, or claim that an author callback or media codec works.
enum WorkshopWebProjectValidator {
    static func validate(projectFile: URL, downloadRoot: URL, workshopID: String,
        declaredTags: [String], projectTitle: String? = nil, diagnostics: [String]) throws -> WorkshopWebProject {
        do {
            let descriptor = try WebWallpaperProjectDescriptor(projectURL: projectFile)
            guard WorkshopProjectResolver.isInside(descriptor.projectURL, root: downloadRoot) else { throw invalid("Web 项目配置超出下载目录") }
            let root = try WebProjectPaths.canonical(descriptor.root)
            let canonicalDownloadRoot = try WebProjectPaths.canonical(downloadRoot)
            let excluded = GlimmerIdentity.downloadManifestNames.map {
                canonicalDownloadRoot.appendingPathComponent($0)
            }
            let tree = try WorkshopProjectTreeValidator.validate(
                root: root, excluded: excluded, label: "Web", ordering: .string)
            var report = diagnostics + ["仅校验本地 Web 项目结构；网页脚本与作者回调尚未运行", "远程网络依赖受当前 Web 运行时策略限制"]
            let largeDocuments = tree.entries.filter { ["html", "htm"].contains(($0.path as NSString).pathExtension.lowercased()) && $0.bytes > 32 * 1024 * 1024 }.count
            if largeDocuments > 0 {
                report.append("\(largeDocuments) 个 HTML 文档超过当前 Web 文档 32 MiB 限制，相关页面可能无法加载")
            }
            let current = try WebWallpaperProjectDescriptor(projectURL: descriptor.projectURL)
            guard current.entryURL == descriptor.entryURL else { throw invalid("Web 入口在校验期间发生变化") }
            return WorkshopWebProject(downloadRoot: try WebProjectPaths.canonical(downloadRoot),
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
