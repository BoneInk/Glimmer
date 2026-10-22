import AppKit
import AVFoundation
import Darwin
import Foundation

struct ExperimentalLockScreenAsset: Codable, Identifiable, Sendable {
    let id: UUID
    let itemID: UUID
    let title: String
    let videoURL: URL
    let posterURL: URL
    let durationSeconds: Double
    let codec: String
    var liveRecipe: LiveWallpaperRecipe? = nil
}

struct ExperimentalLockScreenEnvironment: Sendable {
    let storeDirectory: URL
    let sharedDirectory: URL
    let legacySharedDirectory: URL?
    let extensionURL: URL?
    let isReview: Bool
    var reviewReloadFailureMessage: String? = nil

    static var production: Self {
        Self(storeDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store"),
             sharedDirectory: URL(fileURLWithPath: "/Users/Shared/\(GlimmerIdentity.lockScreenSharedFolderName)", isDirectory: true)
                .appendingPathComponent(String(getuid()), isDirectory: true),
             legacySharedDirectory: URL(fileURLWithPath: "/Users/Shared/\(GlimmerIdentity.legacyLockScreenSharedFolderName)", isDirectory: true)
                .appendingPathComponent(String(getuid()), isDirectory: true),
             extensionURL: Bundle.main.builtInPlugInsURL?.appendingPathComponent("GlimmerWallpaperExtension.appex"),
             isReview: false)
    }

    static func review(storage: AppStorage) -> Self {
        Self(storeDirectory: storage.root.resolvingSymlinksInPath().appendingPathComponent("LockScreenReview/Store"),
             sharedDirectory: storage.root.resolvingSymlinksInPath().appendingPathComponent("LockScreenReview/Shared"),
             legacySharedDirectory: nil,
             extensionURL: nil, isReview: true)
    }
}

enum LockScreenOwnedFiles {
    /// Reject symlink path components and foreign owners before placing private video assets.
    static func makePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            if manager.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                // Foundation canonicalises macOS temporary paths back through these
                // root-owned OS aliases; they are not user-controlled asset symlinks.
                let osAliasTarget = ["/var": "private/var", "/tmp": "private/tmp"][cursor.path]
                let destination = try? manager.destinationOfSymbolicLink(atPath: cursor.path)
                let owner = (try? manager.attributesOfItem(atPath: cursor.path)[.ownerAccountID] as? NSNumber)?.uint32Value
                let trustedOSAlias = osAliasTarget != nil && owner == 0
                    && (destination == osAliasTarget || destination == osAliasTarget.map { "/" + $0 })
                guard values.isSymbolicLink != true || trustedOSAlias else {
                    throw ExperimentalLockScreenFailure(message: "素材目录包含符号链接，已拒绝写入。")
                }
            }
            cursor.deleteLastPathComponent()
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw ExperimentalLockScreenFailure(message: "素材目录不属于当前用户，已拒绝写入。")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func privateWrite(_ data: Data, to url: URL) throws {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ExperimentalLockScreenFailure(message: "目标文件是符号链接，已拒绝写入。")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

actor ExperimentalLockScreenAssetPreparer {
    func stageVideo(_ asset: ExperimentalLockScreenAsset, directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent("\(asset.id.uuidString).mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard values.isSymbolicLink != true,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ExperimentalLockScreenFailure(message: "共享素材不属于当前用户或是符号链接，已拒绝使用。")
            }
        } else {
            try FileManager.default.copyItem(at: asset.videoURL, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func prepare(item: WallpaperItem, sourceURL: URL? = nil, root: URL,
                 configuration: LockScreenExportConfiguration? = nil,
                 progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ExperimentalLockScreenAsset {
        await progress("正在检查视频编码与时长")
        let source = sourceURL ?? item.fileURL
        let probe = try await VideoProbe.probe(url: source)
        guard probe.isPlayable, probe.durationSeconds.isFinite, probe.durationSeconds > 0,
              probe.pixelWidth > 0, probe.pixelHeight > 0 else {
            throw ExperimentalLockScreenFailure(message: "视频时长或编码不可用，无法准备动态锁屏。")
        }
        guard let sourceFPS = probe.frameRate, sourceFPS.isFinite, sourceFPS > 0 else {
            throw LockScreenExportConfigurationFailure(message: "无法读取视频原始帧率，已停止锁屏导出。")
        }
        let sourceSpecification = LockScreenExportSpecification(width: probe.pixelWidth,
            height: probe.pixelHeight, framesPerSecond: sourceFPS)
        let specification = try (configuration ?? .init(settings: .original)).resolve(source: sourceSpecification)
        try Task.checkCancellation()
        let id = UUID()
        let destination = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let directory = root.appendingPathComponent(".preparing-\(id.uuidString)", isDirectory: true)
        try LockScreenOwnedFiles.makePrivateDirectory(directory)
        do {
            let video = directory.appendingPathComponent("video.mp4")
            let originalCodec = (probe.videoCodec ?? "").lowercased()
            let directlyUsable = source.pathExtension.lowercased() == "mp4"
                && ["avc1", "avc3", "h264", "h.264", "hvc1", "hev1", "hevc"].contains(where: originalCodec.contains)
                && specification.width == probe.pixelWidth && specification.height == probe.pixelHeight
                && specification.framesPerSecond >= sourceFPS
            if directlyUsable {
                await progress("正在复制兼容的 MP4 视频")
                try FileManager.default.copyItem(at: source, to: video)
            } else {
                await progress("正在转码为兼容的 MP4 视频")
                try await LockScreenVideoTranscoder.export(source: source, to: video, specification: specification)
            }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: video.path)
            let preparedProbe = try await VideoProbe.probe(url: video)
            guard preparedProbe.isPlayable, preparedProbe.durationSeconds.isFinite, preparedProbe.durationSeconds > 0,
                  preparedProbe.pixelWidth == specification.width, preparedProbe.pixelHeight == specification.height,
                  let outputFPS = preparedProbe.frameRate, outputFPS > 0,
                  outputFPS <= specification.framesPerSecond + 0.002 else {
                throw ExperimentalLockScreenFailure(message: "准备后的视频未通过真实播放校验。")
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            await progress("正在生成静态预览")
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            let time = CMTime(seconds: min(1, preparedProbe.durationSeconds * 0.15), preferredTimescale: 600)
            let still = try await generator.image(at: time).image
            try Task.checkCancellation()
            guard let poster = NSBitmapImageRep(cgImage: still).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                throw ExperimentalLockScreenFailure(message: "无法准备锁屏静态预览图。")
            }
            let posterURL = directory.appendingPathComponent("poster.jpg")
            try LockScreenOwnedFiles.privateWrite(poster, to: posterURL)
            try Task.checkCancellation()
            // Publish both files together only after real probing and poster generation.
            // APFS exchanges directories atomically; the old version then lives at
            // the staging path and can be deleted without touching an applied copy.
            if FileManager.default.fileExists(atPath: destination.path) {
                try LockScreenOwnedFiles.makePrivateDirectory(destination)
                guard renameatx_np(AT_FDCWD, directory.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try? FileManager.default.removeItem(at: directory)
            } else {
                try FileManager.default.moveItem(at: directory, to: destination)
            }
            return ExperimentalLockScreenAsset(id: id, itemID: item.id, title: item.displayTitle,
                videoURL: destination.appendingPathComponent("video.mp4"),
                posterURL: destination.appendingPathComponent("poster.jpg"), durationSeconds: preparedProbe.durationSeconds,
                codec: preparedProbe.videoCodec ?? "unknown")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

actor ExperimentalLockScreenRegistrar {
    private struct Registration {
        let path: URL
        let eligible: Bool
    }

    /// `-v` prints one tab-separated record per physical extension. Match the
    /// provider and path on the same record; -A/-D inventory is not selection.
    private nonisolated static func registrations(_ output: String) -> [Registration] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            var identity = fields[0].trimmingCharacters(in: .whitespaces)
            let marker = identity.first
            if let marker, "+-=!?".contains(marker) {
                identity.removeFirst(); identity = identity.trimmingCharacters(in: .whitespaces)
            }
            guard identity.hasPrefix(LockScreenStorePatcher.provider + "("),
                  let path = fields.last, path.hasPrefix("/"), path.hasSuffix(".appex") else { return nil }
            return Registration(path: URL(fileURLWithPath: String(path)).standardizedFileURL,
                eligible: marker != "-" && marker != "=" && marker != "!" && marker != "?")
        }
    }

    nonisolated static func registeredExtensionURLs(output: String) -> [URL] {
        Array(Set(registrations(output).map(\.path))).sorted { $0.path < $1.path }
    }

    nonisolated static func registrationMatches(output: String, extensionURL: URL) -> Bool {
        let records = registrations(output).filter(\.eligible)
        return records.count == 1 && records[0].path == extensionURL.standardizedFileURL
    }

    func register(extensionURL: URL) async throws {
        let infoURL = extensionURL.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == LockScreenStorePatcher.provider else {
            throw ExperimentalLockScreenFailure(message: "应用内没有匹配的动态锁屏扩展，请使用完整安装包。")
        }
        let inventory = try await run(executable: "/usr/bin/pluginkit",
            arguments: ["-m", "-A", "-D", "-v", "-i", LockScreenStorePatcher.provider], capture: true)
        // Development builds and moved installs can leave the same provider in
        // several bundles. Retire only confirmed copies of our own extension;
        // no files or other providers are removed.
        for old in Self.registeredExtensionURLs(output: String(decoding: inventory.output, as: UTF8.self))
            where old != extensionURL.standardizedFileURL {
            let oldInfo = old.appendingPathComponent("Contents/Info.plist")
            guard let bytes = try? Data(contentsOf: oldInfo),
                  let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  value["CFBundleIdentifier"] as? String == LockScreenStorePatcher.provider else { continue }
            let removed = try await run(executable: "/usr/bin/pluginkit", arguments: ["-r", old.path])
            guard removed.status == 0 else {
                throw ExperimentalLockScreenFailure(message: "无法注销旧安装包的锁屏扩展；系统壁纸未修改。")
            }
        }
        let added = try await run(executable: "/usr/bin/pluginkit", arguments: ["-a", extensionURL.path])
        guard added.status == 0 else {
            throw ExperimentalLockScreenFailure(message: "系统未接受动态锁屏扩展注册（状态 \(added.status)）。")
        }
        let matched = try await run(executable: "/usr/bin/pluginkit",
            arguments: ["-m", "-v", "-i", LockScreenStorePatcher.provider], capture: true)
        guard matched.status == 0,
              Self.registrationMatches(output: String(decoding: matched.output, as: UTF8.self), extensionURL: extensionURL) else {
            throw ExperimentalLockScreenFailure(message: "注册后未能核对当前安装包的扩展标识与路径；系统壁纸未修改。")
        }
    }

    /// Production only: terminate this user's exact WallpaperAgent executable name.
    /// launchd owns restarting it. Never signal another user or a broader name pattern.
    func reloadCurrentUser() async throws {
        // A running old service can survive registration and be reused by the
        // agent. Retire this user's exact extension before requesting reacquire.
        let retired = try await run(executable: "/usr/bin/pkill",
            arguments: ["-TERM", "-u", String(getuid()), "-x", "GlimmerWallpaperExtension"])
        guard retired.status == 0 || retired.status == 1 else {
            throw ExperimentalLockScreenFailure(message: "无法停止旧锁屏扩展，请稍后重新应用锁屏。")
        }
        let result = try await run(executable: "/usr/bin/pkill",
            arguments: ["-TERM", "-u", String(getuid()), "-x", "WallpaperAgent"])
        guard result.status == 0 else {
            throw ExperimentalLockScreenFailure(message: "系统壁纸代理未接受重新加载请求（状态 \(result.status)）；配置已保存，可稍后在系统设置中重新选择。")
        }
    }

    private func run(executable: String, arguments: [String], capture: Bool = false) async throws -> (status: Int32, output: Data) {
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("gw-lock-screen-process-\(UUID().uuidString)")
        var handle: FileHandle?
        if capture {
            guard FileManager.default.createFile(atPath: captureURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ExperimentalLockScreenFailure(message: "无法创建扩展核验的临时输出。")
            }
            handle = try FileHandle(forWritingTo: captureURL)
        }
        defer {
            try? handle?.close()
            if capture { try? FileManager.default.removeItem(at: captureURL) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                throw ExperimentalLockScreenFailure(message: "系统扩展操作超时或被取消。")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try handle?.synchronize()
        let output = capture ? (try Data(contentsOf: captureURL)) : Data()
        return (process.terminationStatus, output)
    }
}
