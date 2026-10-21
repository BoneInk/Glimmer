import CryptoKit
import Foundation

/// 官方 SteamCMD 安装包下载 + 安全展开（F13）。
///
/// - 下载源固定为官方 HTTPS 地址（Steam CDN）。
/// - 展开使用 `/usr/bin/tar`，以参数数组方式启动（无 shell 拼接），并加上 `--no-same-owner`
///   等安全选项；只展开到应用管理目录，绝不写入全局 Steam 目录。
/// - 不自动安装任何系统组件（例如 Rosetta），只如实报告状态与引导。
actor SteamCMDInstaller {
    struct DownloadProgress: Sendable, Equatable {
        var receivedBytes: Int64
        var expectedBytes: Int64?
        var fraction: Double? {
            guard let expectedBytes, expectedBytes > 0 else { return nil }
            return min(1, Double(receivedBytes) / Double(expectedBytes))
        }
    }

    private let layout: SteamCMDLayout
    private let processRunner = WorkshopProcessRunner()

    init(layout: SteamCMDLayout = SteamCMDLayout()) {
        self.layout = layout
    }

    /// 下载官方安装包并展开到应用管理目录。
    ///
    /// - Returns: 下载到本地的压缩包 SHA-256（用于安装记录与校验）。
    @discardableResult
    func downloadAndInstall(
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> SteamCMDInstallRecord {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: layout.homeURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: layout.downloadsURL, withIntermediateDirectories: true)
        } catch {
            throw WorkshopDownloadError.storageUnavailable(error.localizedDescription)
        }

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("glimmer-steamcmd-\(UUID().uuidString).tar.gz")

        let (received, expected) = try await downloadArchive(to: archiveURL, progress: progress)
        let digest = try Self.sha256(of: archiveURL)

        // 安全展开：先解到临时目录，再把 steamcmd 相关文件移入管理目录。
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: layout.root,
            create: true
        ).appendingPathComponent("steamcmd-staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: archiveURL) }
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try await extractArchive(archiveURL, to: staging)
        } catch {
            throw WorkshopDownloadError.extractionFailed(detail: error.localizedDescription)
        }

        let stagedExecutable = staging.appendingPathComponent("steamcmd", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: stagedExecutable.path) else {
            throw WorkshopDownloadError.extractionFailed(detail: "压缩包内没有找到可执行的 steamcmd 二进制（Steam 官方包结构可能变化）")
        }

        // 校验：真实读取 Mach-O 架构后再落位。
        let architecture = SteamCMDCapabilityProbe.readArchitecture(at: stagedExecutable)

        // 清掉旧安装（只删除管理目录内的内容）。
        for name in ["steamcmd", "public", "linux32", "steamclient.so", "steamclient.dylib", "install-record.json"] {
            let target = layout.root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: target)
            }
        }

        // 移动 staging 内容
        let contents = (try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? []
        for name in contents {
            let source = staging.appendingPathComponent(name)
            let target = layout.root.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: source, to: target)
            } catch {
                throw WorkshopDownloadError.extractionFailed(detail: "移动 \(name) 失败：\(error.localizedDescription)")
            }
        }

        let executableURL = layout.executableURL
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw WorkshopDownloadError.extractionFailed(detail: "安装后未找到可执行的 steamcmd")
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let record = SteamCMDInstallRecord(
            layoutVersion: SteamCMDLayout.layoutVersion,
            installedAt: Date(),
            archiveURL: SteamCMDLayout.archiveURL.absoluteString,
            archiveByteSize: received > 0 ? received : (expected ?? 0),
            archiveSHA256: digest,
            executableRelativePath: "steamcmd",
            architecture: architecture.rawValue,
            smokeTestPassed: false,
            smokeTestOutputSummary: ""
        )
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: layout.installRecordURL, options: .atomic)
        }
        WorkshopLog.notice("SteamCMD 安装包已展开（架构 \(architecture.rawValue)，SHA-256 \(digest.prefix(12))…）")
        return record
    }

    /// 删除应用管理目录内的 SteamCMD（不动全局 Steam）。
    func uninstall() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: layout.root)
    }

    // MARK: - 下载

    private func downloadArchive(
        to destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> (Int64, Int64?) {
        var request = URLRequest(url: SteamCMDLayout.archiveURL)
        request.setValue(SteamHTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let delegate = ArchiveDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            return try await delegate.run(session: session, request: request)
        } catch let error as SteamHTTPError {
            throw error
        } catch let error as URLError {
            throw SteamHTTPError.network(SteamHTTPClient.describe(urlError: error))
        } catch let error as WorkshopDownloadError {
            throw error
        } catch {
            throw SteamHTTPError.network(error.localizedDescription)
        }
    }

    private func extractArchive(_ archive: URL, to destination: URL) async throws {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        guard FileManager.default.isExecutableFile(atPath: tar.path) else {
            throw WorkshopDownloadError.extractionFailed(detail: "系统缺少 /usr/bin/tar")
        }
        let arguments = [
            "-xzf", archive.path,
            "-C", destination.path,
            "--no-same-owner",
            "--no-same-permissions",
            "--no-xattrs",
            "--no-mac-metadata"
        ]
        do {
            _ = try await processRunner.run(
                executable: tar,
                arguments: arguments,
                environment: nil,
                currentDirectory: destination,
                timeout: 180
            )
        } catch let error as WorkshopProcessError {
            throw WorkshopDownloadError.extractionFailed(detail: error.errorDescription ?? "未知错误")
        }
    }

    /// 流式计算文件 SHA-256（CryptoKit）。
    static func sha256(of url: URL, chunkSize: Int = 4 * 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 下载代理：写入文件并汇报进度（带 500ms 节流）。
private final class ArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (@Sendable (SteamCMDInstaller.DownloadProgress) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Int64, Int64?), Error>?
    private var fileMoved = false
    private var lastProgressAt = Date.distantPast
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?

    init(destination: URL, progress: (@Sendable (SteamCMDInstaller.DownloadProgress) -> Void)?) {
        self.destination = destination
        self.progress = progress
    }

    func run(session: URLSession, request: URLRequest) async throws -> (Int64, Int64?) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        receivedBytes = totalBytesWritten
        expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastProgressAt) > 0.5
        if shouldReport { lastProgressAt = now }
        let expected = expectedBytes
        lock.unlock()
        if shouldReport {
            progress?(.init(receivedBytes: totalBytesWritten, expectedBytes: expected))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            fileMoved = true
            let received = receivedBytes
            let expected = expectedBytes
            lock.unlock()
            finish(.success((received, expected)))
        } catch {
            finish(.failure(SteamHTTPError.decoding("无法写入下载文件：\(error.localizedDescription)")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        // 没有 error 但也没有移动文件（例如 3xx 无内容）
        lock.lock()
        let moved = fileMoved
        lock.unlock()
        if !moved {
            finish(.failure(SteamHTTPError.structureChanged("下载未产生文件")))
        }
    }

    private func finish(_ result: Result<(Int64, Int64?), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
    }
}
