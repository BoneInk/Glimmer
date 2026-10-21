import AVFoundation
import Foundation
import Darwin

/// 工坊作品本地校验：安全定位 project.json 中的视频文件（F16 的下载侧一半）。
///
/// 安全规则：
/// - `project.json` 必须位于下载目录（管理根目录）之内；
/// - `file` 字段必须是**相对路径**，拒绝绝对路径与任何穿越（`..`、`~`）；
/// - 解析后必须仍位于下载目录之内（含符号链接解析）；
/// - 使用 AVFoundation 真实验证视频可播放（不是只检查扩展名）；
/// - 接受真实 video / 本地 HTML Web 项目；Scene/Application 继续拒绝。

/// 可用的视频项目校验结果。
struct WorkshopVideoProject: Sendable, Equatable {
    /// 实际的视频文件 URL（位于管理目录内）。
    var videoURL: URL
    var videoRelativePath: String
    var projectJSONPath: String
    var projectRoot: URL
    var projectType: String
    var projectTitle: String?
    var projectPreviewFileName: String?
    var workshopID: String
    var declaredTags: [String]
    var videoByteSize: Int64
    var probe: VideoProbeResultSummary
    var diagnostics: [String]
}

/// AVFoundation 探测结果的精简快照（避免把 AVFoundation 类型带进跨模块边界）。
struct VideoProbeResultSummary: Sendable, Equatable {
    var isPlayable: Bool
    var durationSeconds: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var frameRate: Double?
    var videoCodec: String?
    var hasAudioTrack: Bool

    var resolutionText: String { "\(pixelWidth)×\(pixelHeight)" }
    var durationText: String { WallpaperItem.formatDuration(durationSeconds) }
}

/// 定位并解析下载目录内的 project.json。
enum WorkshopProjectResolver {
    /// 本模块自带的候选视频扩展名（自我验证用；真正的可播放性一律由 AVFoundation 判定）。
    static let candidateVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "mpg", "mpeg", "m2v",
        "wmv", "flv", "ts", "m2ts", "mts", "3gp", "3g2", "ogv", "vob", "asf", "divx"
    ]

    /// 扩展名候选筛选（不等于可播放，仅用于定位文件）。
    static func isCandidateVideo(url: URL) -> Bool {
        candidateVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 候选项：一个下载目录里可能有多个 project.json（例如包含多个子分辨率），
    /// 这里优先根目录，再按需回退到子目录。
    static func resolve(
        workshopID: String,
        directory: URL,
        declaredTags: [String] = []
    ) async throws -> WorkshopResolvedProject {
        let manager = FileManager.default
        let root = canonicalURL(directory)

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkshopDownloadError.validationFailed(reason: "下载目录不存在：\(PathRedaction.short(root))")
        }

        let projectFiles = findProjectJSONFiles(in: root, manager: manager)
        guard !projectFiles.isEmpty else {
            throw WorkshopDownloadError.validationFailed(reason: "下载内容中没有找到 project.json（可能不是 Wallpaper Engine 作品）")
        }

        var diagnostics: [String] = []
        var lastError: WorkshopDownloadError?

        for projectFile in projectFiles {
            try Task.checkCancellation()
            do {
                let project = try await resolveProject(
                    workshopID: workshopID,
                    projectFile: projectFile,
                    root: root,
                    declaredTags: declaredTags,
                    diagnostics: &diagnostics
                )
                return project
            } catch let error as WorkshopDownloadError {
                lastError = error
                diagnostics.append("跳过 \(projectFile.lastPathComponent)：\(error.errorDescription ?? "未知错误")")
            }
        }
        throw lastError ?? .validationFailed(reason: "没有可解析的 project.json")
    }

    // MARK: - 具体解析

    private static func resolveProject(
        workshopID: String,
        projectFile: URL,
        root: URL,
        declaredTags: [String],
        diagnostics: inout [String]
    ) async throws -> WorkshopResolvedProject {
        let metadata = try projectFile.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, metadata.isRegularFile == true,
              isInside(projectFile, root: root), (metadata.fileSize ?? Int.max) <= 2_097_152 else {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 必须是下载目录内不超过 2 MB 的常规文件")
        }
        let descriptor = open(projectFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkshopDownloadError.validationFailed(reason: "project.json 不可访问或在校验期间被替换") }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_size <= 2_097_152 else {
            close(descriptor)
            throw WorkshopDownloadError.validationFailed(reason: "project.json 不是常规文件或超过 2 MB")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data: Data
        do { data = try handle.read(upToCount: 2_097_153) ?? Data(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard data.count <= 2_097_152 else { throw WorkshopDownloadError.validationFailed(reason: "project.json 超过 2 MB") }
        let text = try decodeJSONText(data)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.allowFragments]) as? [String: Any] else {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 不是有效的 JSON 对象")
        }

        let typeString = (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let kind = WorkshopItemKind.fromProjectType(typeString)
        diagnostics.append("project.json type=\(typeString.isEmpty ? "(缺失)" : typeString)")

        if kind == .web {
            return .web(try WorkshopWebProjectValidator.validate(projectFile: projectFile, downloadRoot: root,
                workshopID: workshopID, declaredTags: declaredTags,
                projectTitle: (object["title"] as? String).map(SteamHTML.collapseWhitespace).flatMap { $0.isEmpty ? nil : $0 },
                diagnostics: diagnostics))
        }

        if kind == .scene {
            return .scene(try WorkshopSceneProjectValidator.validate(projectFile: projectFile, downloadRoot: root,
                workshopID: workshopID, declaredTags: declaredTags,
                projectTitle: (object["title"] as? String).map(SteamHTML.collapseWhitespace).flatMap { $0.isEmpty ? nil : $0 },
                diagnostics: diagnostics))
        }

        guard kind == .video else {
            throw WorkshopDownloadError.validationFailed(
                reason: kind.unsupportedReason ?? "项目类型 \(typeString.isEmpty ? "(缺失)" : typeString) 不是当前支持的视频、Web 或 Scene 子集项目"
            )
        }

        guard let rawFile = object["file"] as? String, !rawFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkshopDownloadError.validationFailed(reason: "视频项目缺少 file 字段")
        }

        // 收集可能的视频候选（file 可能是单个路径，也可能是列表/通配）。
        let fileBase = projectFile.deletingLastPathComponent()
        let candidates = try videoCandidates(from: rawFile, projectDirectory: fileBase, root: root)

        guard let videoURL = candidates.first else {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 指定的视频文件未找到（file=\(SteamHTML.collapseWhitespace(rawFile))）")
        }

        // AVFoundation 真实验证。
        let probeResult: VideoProbeResult
        do {
            probeResult = try await VideoProbe.probe(url: videoURL)
        } catch {
            throw WorkshopDownloadError.validationFailed(
                reason: "视频无法被 AVFoundation 播放：\(PathRedaction.short(videoURL))（\(error.localizedDescription)）"
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let relative = relativePath(of: videoURL, from: root)
        let projectRelative = relativePath(of: projectFile, from: root)

        return .video(WorkshopVideoProject(
            videoURL: videoURL,
            videoRelativePath: relative,
            projectJSONPath: projectRelative,
            projectRoot: root,
            projectType: typeString,
            projectTitle: (object["title"] as? String).map { SteamHTML.collapseWhitespace($0) },
            projectPreviewFileName: (object["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            workshopID: workshopID,
            declaredTags: declaredTags,
            videoByteSize: byteSize,
            probe: VideoProbeResultSummary(
                isPlayable: probeResult.isPlayable,
                durationSeconds: probeResult.durationSeconds,
                pixelWidth: probeResult.pixelWidth,
                pixelHeight: probeResult.pixelHeight,
                frameRate: probeResult.frameRate,
                videoCodec: probeResult.videoCodec,
                hasAudioTrack: probeResult.hasAudioTrack
            ),
            diagnostics: diagnostics + probeResult.diagnostics
        ))
    }

    /// 从 `file` 字段生成安全的候选视频路径列表。
    private static func videoCandidates(from rawFile: String, projectDirectory: URL, root: URL) throws -> [URL] {
        let manager = FileManager.default
        let trimmed = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)

        // 规范：不允许绝对路径、盘符、或目录穿越。
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains(":") && trimmed.count > 2 {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 的 file 字段是绝对路径或含非法字符，已拒绝")
        }
        if trimmed.contains("..") {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 的 file 字段包含目录穿越（..），已拒绝")
        }

        var resolved = projectDirectory.appendingPathComponent(trimmed, isDirectory: false)
        resolved = resolved.standardizedFileURL

        guard isInside(resolved, root: root) else {
            throw WorkshopDownloadError.validationFailed(reason: "视频路径解析后越出了下载目录，已拒绝")
        }
        if manager.fileExists(atPath: resolved.path) {
            // 符号链接必须解析后仍在下载目录内（防止用链接指向 /etc/passwd 等外部文件）。
            let real = resolved.resolvingSymlinksInPath()
            guard isInside(real, root: root) else {
                throw WorkshopDownloadError.validationFailed(reason: "视频文件是越出下载目录的符号链接，已拒绝")
            }
            return [real.standardizedFileURL]
        }

        // 兜底：同目录下大小写不同的同名文件（Steam 下载很少出现，但代价很低）。
        if let contents = try? manager.contentsOfDirectory(atPath: projectDirectory.path) {
            let wanted = trimmed.lowercased()
            if let match = contents.first(where: {
                $0.lowercased() == wanted && isCandidateVideo(url: URL(fileURLWithPath: $0))
            }) {
                let candidate = projectDirectory.appendingPathComponent(match)
                if isInside(candidate.standardizedFileURL, root: root) {
                    return [candidate.standardizedFileURL]
                }
            }
        }
        return []
    }

    static func findProjectJSONFiles(in directory: URL, manager: FileManager = .default) -> [URL] {
        var results: [URL] = []
        var seen: Set<String> = []
        func append(_ url: URL) {
            let key = canonicalPath(url)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            results.append(url)
        }
        if manager.fileExists(atPath: directory.appendingPathComponent("project.json").path) {
            append(directory.appendingPathComponent("project.json"))
        }
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return results }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 12_000 { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true || values?.isSymbolicLink == true {
                if values?.isSymbolicLink == true { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent.lowercased() == "project.json" {
                append(url)
                if results.count >= 8 { break }
            }
        }
        return results
    }

    /// 路径是否位于 root 内（两侧都用 realpath 规范化，避免 /var 与 /private/var 混用误判）。
    static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = canonicalPathComponents(candidate)
        let rootComponents = canonicalPathComponents(root)
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// 规范化后的路径分量（realpath：解析符号链接与 /private 前缀）。
    static func canonicalPathComponents(_ url: URL) -> [String] {
        canonicalPath(url).split(separator: "/").map(String.init)
    }

    /// 规范化 URL。
    static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: canonicalPath(url))
    }

    /// 系统级真实路径（`realpath(3)`）。
    ///
    /// 注意：`URL.resolvingSymlinksInPath()` 不会把 `/var` 归一化为 `/private/var`，
    /// 而目录枚举返回的 URL 往往是 `/private/var/...`，两者混用会被误判为「越界」。
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return path
    }

    static func relativePath(of url: URL, from root: URL) -> String {
        let candidate = canonicalPathComponents(url)
        let rootComponents = canonicalPathComponents(root)
        guard candidate.count > rootComponents.count, Array(candidate.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return candidate.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// 去掉 UTF-8 BOM；Wallpaper Engine 的 project.json 可能带 BOM 或注释。
    static func decodeJSONText(_ data: Data) throws -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw WorkshopDownloadError.validationFailed(reason: "project.json 不是 UTF-8 文本")
        }
        return stripJSONComments(text)
    }

    /// 去除 `//` 与 `/* */` 注释（Wallpaper Engine 允许，但 JSONSerialization 不允许）。
    static func stripJSONComments(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "/" {
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if next < text.endIndex, text[next] == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let current = text[index]
                        let following = text.index(after: index)
                        if current == "*", following < text.endIndex, text[following] == "/" {
                            index = text.index(after: following)
                            break
                        }
                        index = following
                    }
                    continue
                }
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }
}
