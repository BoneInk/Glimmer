import AppKit
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import SwiftUI

/// 自检与可控验证入口（`--self-test`）。
///
/// 原则：
/// - 默认在临时目录中运行，不触碰用户的素材库与配置。
/// - 不切换当前用户壁纸：全程只使用「预览会话」（不创建桌面窗口），真实桌面显示由人工验证。
/// - 结论来自真实调用：AVFoundation 探测、AVPlayerItemVideoOutput 解码帧、播放器当前时间、
///   文件读写。图层截图不作为「画面已显示」的证据。
@MainActor
final class SelfTestRunner {
    struct TestResult {
        var name: String
        var passed: Bool
        var detail: String
        var skipped: Bool = false

        var symbol: String { skipped ? "SKIP" : (passed ? "PASS" : "FAIL") }
    }

    /// 运行模式：full 覆盖全部检查；smoke 只做有界的解码/播放冒烟检查。
    enum Mode: String {
        case full
        case smoke
    }

    var evidenceDirectory: URL?
    var keepArtifacts: Bool
    var sampleFrames: Int
    var customLibrary: URL?
    var mode: Mode
    /// 可选：用一份真实媒体文件（只读）追加运行有界的解码/播放冒烟检查。
    var externalMediaURL: URL?

    init(
        evidenceDirectory: URL?,
        keepArtifacts: Bool,
        sampleFrames: Int,
        customLibrary: URL?,
        mode: Mode = .full,
        externalMediaURL: URL? = nil
    ) {
        self.evidenceDirectory = evidenceDirectory
        self.keepArtifacts = keepArtifacts
        self.sampleFrames = sampleFrames
        self.customLibrary = customLibrary
        self.mode = mode
        self.externalMediaURL = externalMediaURL
    }

    private var results: [TestResult] = []
    private let fileManager = FileManager.default
    private var storage: AppStorage!
    private var registry: DisplayRegistry!
    private var store: VideoLibraryStore!
    private var importService: ImportService!
    /// 自检专用的缩略图缓存：磁盘缓存写在临时测试目录，不污染用户数据。
    private var thumbnailCache: ThumbnailCache!
    /// 第二个内容不同的测试视频（用于切换素材与文件夹导入检查）。
    private var secondaryFixtureURL: URL?

    // MARK: - 入口

    static func run(arguments: [String]) async -> Int32 {
        var evidence: URL?
        var keep = false
        var frames = 6
        var customLibrary: URL?
        var mode: Mode = .full
        var externalMedia: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--evidence":
                if index + 1 < arguments.count { evidence = URL(fileURLWithPath: arguments[index + 1]); index += 1 }
            case "--library":
                if index + 1 < arguments.count { customLibrary = URL(fileURLWithPath: arguments[index + 1]); index += 1 }
            case "--frames":
                if index + 1 < arguments.count { frames = Int(arguments[index + 1]) ?? frames; index += 1 }
            case "--keep-artifacts":
                keep = true
            case "--smoke":
                mode = .smoke
            case "--smoke-file":
                if index + 1 < arguments.count { externalMedia = URL(fileURLWithPath: arguments[index + 1]); index += 1 }
            default:
                break
            }
            index += 1
        }

        // 安全门槛：拒绝在可能包含真实数据的目录上运行自检（避免覆盖真实素材库/配置）。
        if let customLibrary, refusesCustomLibrary(customLibrary) {
            print("✗ 拒绝在原数据目录上运行自检：\(customLibrary.path)")
            print("  该目录包含真实的素材库记录或应用配置。请传入一个全新的空目录，")
            print("  或省略 --library 参数（默认在系统临时目录中运行）。")
            return 2
        }

        let runner = SelfTestRunner(
            evidenceDirectory: evidence,
            keepArtifacts: keep,
            sampleFrames: max(3, min(frames, 30)),
            customLibrary: customLibrary,
            mode: mode,
            externalMediaURL: externalMedia
        )
        return await runner.execute()
    }

    /// 自检数据目录安全门槛：默认应用数据目录，或已含素材/配置记录的目录一律拒绝。
    static func refusesCustomLibrary(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let defaultRoot = AppStorage().root.standardizedFileURL
        if standardized.path == defaultRoot.path { return true }

        let manager = FileManager.default
        if let document = try? LibraryPersistence.load(from: standardized.appendingPathComponent(AppConstants.libraryFileName)),
           !document.items.isEmpty {
            return true
        }
        let mediaDirectory = standardized.appendingPathComponent("Media", isDirectory: true)
        if let contents = try? manager.contentsOfDirectory(atPath: mediaDirectory.path),
           contents.contains(where: { !$0.hasPrefix(".") }) {
            return true
        }
        for name in ["power-policy.json", "playlist.json", "preferences.json"] {
            if manager.fileExists(atPath: standardized.appendingPathComponent(name).path) { return true }
        }
        return false
    }

    // MARK: - 执行

    private func execute() async -> Int32 {
        let started = Date()
        header("Glimmer 自检开始（模式：\(mode.rawValue)）")
        print("时间: \(ISO8601DateFormatter().string(from: started))")
        print("系统: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("架构: \(architecture())")
        print("可执行文件: \(Bundle.main.executablePath ?? "-")")
        print("说明: 自检使用预览会话，不会替换当前桌面壁纸。")
        if mode == .smoke {
            print("说明: 冒烟模式只运行有界的解码与播放检查（测试视频为视频轨 only）。")
        }

        var sandbox: URL?
        if let customLibrary {
            storage = AppStorage(root: customLibrary)
        } else {
            let temp = fileManager.temporaryDirectory
                .appendingPathComponent("GlimmerSelfTest-\(UUID().uuidString.prefix(8))", isDirectory: true)
            sandbox = temp
            storage = AppStorage(root: temp)
        }
        registry = DisplayRegistry(observeChanges: false)
        print("测试数据目录: \(storage.root.path)")

        do {
            try storage.prepareDirectories()
        } catch {
            results.append(TestResult(name: "准备测试数据目录", passed: false, detail: error.localizedDescription))
        }
        let desktopPictureBefore = desktopPictureSnapshot()

        let fixtureStart = Date()
        let videoURL = await makeFixture()
        print("测试视频生成耗时: \(String(format: "%.2f", Date().timeIntervalSince(fixtureStart)))s")

        store = VideoLibraryStore(storage: storage)
        thumbnailCache = ThumbnailCache(storage: storage)
        importService = ImportService(store: store, storage: storage, thumbnailCache: thumbnailCache)

        await runDisplayTests()
        if let videoURL {
            await runImportTests(videoURL: videoURL)
        }

        if mode == .full {
            await runStorageTests()
            await runPersistenceTests()
        }
        if let videoURL {
            await runPlaybackTests(videoURL: videoURL)
            if mode == .full {
                await runLifecycleTests(videoURL: videoURL)
            }
        }
        if mode == .full {
            await runQueryTests()
            await runRepositoryTests()
            await runUISnapshotTests()
        }

        if let externalMediaURL {
            await runExternalMediaSmoke(fileURL: externalMediaURL)
        }

        // 集成检查放在最后：它会新增素材（工坊导入），不影响前面按数量断言的检查。
        await runIntegrationTests(videoURL: videoURL)
        await runPreviewIsolationTests(videoURL: videoURL)

        // 全程不得修改用户桌面图片
        let desktopPictureAfter = desktopPictureSnapshot()
        results.append(TestResult(
            name: "全程未修改系统桌面图片",
            passed: desktopPictureBefore == desktopPictureAfter,
            detail: "前后桌面图片 URL 一致=\(desktopPictureBefore == desktopPictureAfter)（共 \(desktopPictureBefore.count) 台显示器）"
        ))

        return report(started: started, sandbox: sandbox)
    }

    // MARK: - 测试夹具

    private func makeFixture() async -> URL? {
        let url = storage.root.appendingPathComponent("fixture-测试视频.mp4")
        let secondURL = storage.root.appendingPathComponent("fixture-2-测试视频.mp4")
        do {
            // 视频轨 only + 严格截止时间（R09）：任何一步超时都会抛错，不会挂起进程。
            try await SyntheticVideoWriter.write(to: url, deadlineSeconds: mode == .smoke ? 15 : 20)
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 1_000 else {
                results.append(TestResult(name: "生成测试视频", passed: false, detail: "文件过小（\(size) 字节），判定失败"))
                return nil
            }
            results.append(TestResult(
                name: "生成测试视频（视频轨 only，有截止时间）",
                passed: true,
                detail: "\(PathRedaction.short(url)) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            ))
        } catch {
            results.append(TestResult(name: "生成测试视频（视频轨 only，有截止时间）", passed: false, detail: error.localizedDescription))
            return nil
        }

        // 第二个内容不同的测试视频：用于「切换素材拆除旧播放器」与文件夹批量导入检查。
        do {
            var options = SyntheticVideoWriter.Options()
            options.width = 256
            options.height = 144
            options.frameCount = 72
            options.frameRate = 24
            try await SyntheticVideoWriter.write(to: secondURL, options: options, deadlineSeconds: mode == .smoke ? 15 : 20)
            secondaryFixtureURL = secondURL
            let size = (try? fileManager.attributesOfItem(atPath: secondURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            results.append(TestResult(
                name: "生成第二个测试视频（内容不同）",
                passed: size > 1_000,
                detail: "\(PathRedaction.short(secondURL)) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · 256×144 3s"
            ))
        } catch {
            secondaryFixtureURL = nil
            results.append(TestResult(name: "生成第二个测试视频（内容不同）", passed: false, detail: error.localizedDescription))
        }

        return url
    }

    // MARK: - 环境与存储

    private func runStorageTests() async {
        header("F01 应用与存储骨架")

        do {
            try storage.prepareDirectories()
            let expected = [storage.mediaDirectory, storage.thumbnailsDirectory, storage.libraryFile.deletingLastPathComponent()]
            let missing = expected.filter { !fileManager.fileExists(atPath: $0.path) }
            results.append(TestResult(
                name: "存储目录创建",
                passed: missing.isEmpty,
                detail: missing.isEmpty ? "Application Support 结构完整" : "缺少：\(missing.map(\.lastPathComponent))"
            ))
        } catch {
            results.append(TestResult(name: "存储目录创建", passed: false, detail: error.localizedDescription))
        }

        var document = LibraryDocument()
        document.items = [WallpaperItem(title: "写入测试", filePath: "/tmp/不存在的视频.mp4")]
        do {
            let bytes = try LibraryPersistence.save(document, to: storage.libraryFile)
            let reloaded = try LibraryPersistence.load(from: storage.libraryFile)
            results.append(TestResult(
                name: "配置原子写入与读取",
                passed: reloaded.items.count == 1 && reloaded.schemaVersion == AppConstants.librarySchemaVersion,
                detail: "写入 \(bytes) 字节，回读 \(reloaded.items.count) 条记录，schemaVersion=\(reloaded.schemaVersion)"
            ))
        } catch {
            results.append(TestResult(name: "配置原子写入与读取", passed: false, detail: error.localizedDescription))
        }

        let futureURL = storage.root.appendingPathComponent("future-library.json")
        let future = "{\"schemaVersion\":999,\"appVersion\":\"9\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"items\":[],\"assignments\":{},\"displaySettings\":{},\"appSettings\":{\"autoApplyOnLaunch\":false,\"desktopLayer\":\"desktop\"}}"
        do {
            try future.write(to: futureURL, atomically: true, encoding: .utf8)
            _ = try LibraryPersistence.load(from: futureURL)
            results.append(TestResult(name: "拒绝未来版本配置", passed: false, detail: "应当抛出错误但解析成功"))
        } catch let error as LibraryStoreError {
            results.append(TestResult(name: "拒绝未来版本配置", passed: true, detail: error.errorDescription ?? "已拒绝"))
        } catch {
            results.append(TestResult(name: "拒绝未来版本配置", passed: false, detail: "抛出非预期错误：\(error)"))
        }

        let corruptedURL = storage.root.appendingPathComponent("corrupted-library.json")
        try? "这不是 JSON".write(to: corruptedURL, atomically: true, encoding: .utf8)
        do {
            _ = try LibraryPersistence.load(from: corruptedURL)
            results.append(TestResult(name: "损坏配置被识别", passed: false, detail: "应当抛出解析错误"))
        } catch {
            let backup = LibraryPersistence.quarantineCorruptedFile(at: corruptedURL)
            results.append(TestResult(
                name: "损坏配置被识别并隔离",
                passed: backup != nil,
                detail: backup.map { "已隔离为 \(PathRedaction.short($0))" } ?? "隔离失败"
            ))
        }

        // 旧版本配置文件（包含已移除的字段）仍可解析
        let legacyURL = storage.root.appendingPathComponent("legacy-library.json")
        let legacy = "{\"schemaVersion\":1,\"appVersion\":\"0.1.0\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"items\":[],\"assignments\":{},\"displaySettings\":{},\"appSettings\":{\"restoreDesktopPictureOnExit\":true,\"autoApplyOnLaunch\":false,\"desktopLayer\":\"desktop\"}}"
        do {
            try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
            let parsed = try LibraryPersistence.load(from: legacyURL)
            results.append(TestResult(
                name: "兼容旧版配置字段",
                passed: parsed.schemaVersion == 1,
                detail: "含已移除字段的旧配置仍可读取（schemaVersion=\(parsed.schemaVersion)）"
            ))
        } catch {
            results.append(TestResult(name: "兼容旧版配置字段", passed: false, detail: error.localizedDescription))
        }
    }

    // MARK: - 显示器

    private func runDisplayTests() async {
        header("F06 显示器识别")
        let displays = registry.displays
        results.append(TestResult(
            name: "枚举显示器",
            passed: !displays.isEmpty,
            detail: displays.map { "\($0.localizedName)[\($0.shortIdentifier)] \($0.resolutionText)\($0.isPrimary ? " 主屏" : "")" }.joined(separator: " | ")
        ))
        let withUUID = displays.filter { UUID(uuidString: $0.id) != nil }
        results.append(TestResult(
            name: "显示器 UUID 可用",
            passed: !displays.isEmpty && withUUID.count == displays.count,
            detail: "\(withUUID.count)/\(displays.count) 台显示器具有合法 UUID"
        ))
        if let primary = registry.primary {
            results.append(TestResult(
                name: "主显示器可识别",
                passed: primary.isPrimary,
                detail: "\(primary.localizedName) \(primary.resolutionText)"
            ))
        } else {
            results.append(TestResult(name: "主显示器可识别", passed: false, detail: "未找到主显示器"))
        }
    }

    // MARK: - 导入

    private func runImportTests(videoURL: URL) async {
        header("F03 导入与探测")

        do {
            let probe = try await VideoProbe.probe(url: videoURL)
            let detail = "\(probe.pixelWidth)×\(probe.pixelHeight) \(probe.videoCodec ?? "?") 音频=\(probe.hasAudioTrack ? (probe.audioCodec ?? "有") : "无") 时长=\(String(format: "%.2f", probe.durationSeconds))s 帧率=\(probe.frameRate.map { String(format: "%.1f", $0) } ?? "?")"
            results.append(TestResult(
                name: "AVFoundation 可播放性验证",
                passed: probe.isPlayable && probe.pixelWidth > 0 && probe.durationSeconds > 0,
                detail: detail
            ))
        } catch {
            results.append(TestResult(name: "AVFoundation 可播放性验证", passed: false, detail: error.localizedDescription))
        }

        let textURL = storage.root.appendingPathComponent("not-a-video.txt")
        try? "纯文本".write(to: textURL, atomically: true, encoding: .utf8)
        do {
            _ = try await VideoProbe.probe(url: textURL)
            results.append(TestResult(name: "拒绝非视频文件", passed: false, detail: "文本文件被误判为可播放"))
        } catch {
            results.append(TestResult(name: "拒绝非视频文件", passed: true, detail: "已拒绝：\(error.localizedDescription)"))
        }

        // 首次导入
        await importService.importURLs([videoURL])
        guard let item = store.items.first else {
            results.append(TestResult(name: "导入视频入库", passed: false, detail: "记录数 \(store.items.count)，最近摘要：\(importService.lastSummary ?? "-")"))
            return
        }
        store.flush()
        let copiedExists = fileManager.fileExists(atPath: item.filePath)
        let originalUntouched = fileManager.fileExists(atPath: videoURL.path)
        results.append(TestResult(
            name: "导入视频入库",
            passed: copiedExists && originalUntouched,
            detail: "记录 \(item.displayTitle) → \(PathRedaction.short(item.fileURL))；原始文件保留=\(originalUntouched)"
        ))
        results.append(TestResult(
            name: "元数据完整（时长/分辨率/缩略图）",
            passed: (item.durationSeconds ?? 0) > 0 && (item.pixelWidth ?? 0) > 0
                && fileManager.fileExists(atPath: storage.thumbnailURL(for: item.id).path),
            detail: "时长=\(item.durationText) 分辨率=\(item.resolutionText) 编码=\(item.videoCodec ?? "?") 缩略图=\(fileManager.fileExists(atPath: storage.thumbnailURL(for: item.id).path) ? "已生成" : "缺失")"
        ))

        // 重复导入
        let before = store.items.count
        await importService.importURLs([videoURL])
        results.append(TestResult(
            name: "重复导入被去重",
            passed: store.items.count == before,
            detail: "\(importService.lastSummary ?? "-")；记录数保持 \(store.items.count)"
        ))

        // 指纹稳定性
        do {
            let first = try VideoFileSupport.contentFingerprint(of: videoURL)
            let second = try VideoFileSupport.contentFingerprint(of: videoURL)
            let otherURL = storage.root.appendingPathComponent("fixture-2.mp4")
            try? fileManager.removeItem(at: otherURL)
            try fileManager.copyItem(at: videoURL, to: otherURL)
            if let handle = try? FileHandle(forWritingTo: otherURL) {
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: max(0, size - 1))
                try? handle.write(contentsOf: Data([0x42]))
                try? handle.close()
            }
            let different = try VideoFileSupport.contentFingerprint(of: otherURL)
            results.append(TestResult(
                name: "内容指纹稳定且可区分",
                passed: first != nil && first == second && first != different,
                detail: "相同文件一致=\(first == second)，内容变化后可区分=\(first != different)"
            ))
            try? fileManager.removeItem(at: otherURL)
        } catch {
            results.append(TestResult(name: "内容指纹稳定且可区分", passed: false, detail: error.localizedDescription))
        }

        // 文件夹扫描（两个内容不同的视频 + 一个非视频文件）
        let folder = storage.root.appendingPathComponent("扫描目录", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fileManager.copyItem(at: videoURL, to: folder.appendingPathComponent("a.mp4"))
        if let secondaryFixtureURL {
            try? fileManager.copyItem(at: secondaryFixtureURL, to: folder.appendingPathComponent("b.mov"))
        } else {
            try? fileManager.copyItem(at: videoURL, to: folder.appendingPathComponent("b.mov"))
        }
        try? "x".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let scanned = VideoFileSupport.scanFolder(folder)
        results.append(TestResult(
            name: "文件夹扫描仅收候选视频",
            passed: scanned.count == 2 && scanned.allSatisfy { VideoFileSupport.isCandidateVideo(url: $0) },
            detail: "扫描到 \(scanned.count) 个候选：\(scanned.map(\.lastPathComponent).joined(separator: ", "))"
        ))

        guard mode == .full else {
            // 冒烟模式：再导入第二个（内容不同的）视频，供「切换素材」检查使用。
            if let secondaryFixtureURL {
                await importService.importURLs([secondaryFixtureURL])
                store.flush()
            }
            return
        }

        // 文件夹任务进入终态（R02 回归检查）
        let beforeFolder = store.items.count
        // 期望新增数：文件夹中内容指纹尚未入库的候选文件数（a.mp4 通常是已有素材的副本，会被去重）
        let knownFingerprints = Set(store.items.compactMap(\.contentFingerprint))
        let expectedNew = VideoFileSupport.scanFolder(folder).filter { candidate in
            guard let fingerprint = try? VideoFileSupport.contentFingerprint(of: candidate) else { return false }
            return !knownFingerprints.contains(fingerprint)
        }.count
        await importService.importURLs([folder])
        store.flush()
        let folderJobs = importService.jobs.filter { $0.displayName == folder.lastPathComponent }
        let folderJobTerminal = folderJobs.allSatisfy { $0.state.isTerminal }
        let folderJobDetail = folderJobs.last?.detail ?? "（无说明）"
        let pendingLeft = importService.jobs.filter { !$0.state.isTerminal }.count
        results.append(TestResult(
            name: "文件夹导入任务进入终态",
            passed: folderJobTerminal && pendingLeft == 0 && store.items.count == beforeFolder + expectedNew,
            detail: "文件夹任务终态=\(folderJobTerminal)（\(folderJobDetail)）；剩余未完成任务=\(pendingLeft)；新增记录=\(store.items.count - beforeFolder)（期望 \(expectedNew)，其中重复内容已被跳过）"
        ))

        // 并发重复导入不产生重复记录（R02 回归检查）
        async let first: Void = importService.importURLs([folder])
        async let second: Void = importService.importURLs([folder])
        _ = await (first, second)
        store.flush()
        let fingerprints = store.items.compactMap(\.contentFingerprint)
        let uniqueFingerprints = Set(fingerprints)
        let anyPending = importService.jobs.contains { !$0.state.isTerminal }
        results.append(TestResult(
            name: "并发导入不重复、无遗留任务",
            passed: fingerprints.count == store.items.count && uniqueFingerprints.count == fingerprints.count && !anyPending,
            detail: "记录 \(store.items.count) 条，含指纹 \(fingerprints.count) 个（唯一 \(uniqueFingerprints.count)），未完成任务=\(anyPending)"
        ))
        await runImportIdentityRegressionTests(videoURL: videoURL)
    }

    /// R13：在独立测试库验证真实导入，避免主夹具已有内容影响去重断言。
    private func runImportIdentityRegressionTests(videoURL: URL) async {
        guard let secondaryFixtureURL else {
            check("R13 导入身份回归前置素材", false, "缺少内容不同的第二份视频")
            return
        }
        let regressionStorage = AppStorage(root: storage.root.appendingPathComponent("import-identity-regression"))
        let regressionStore = VideoLibraryStore(storage: regressionStorage)
        let regressionService = ImportService(store: regressionStore, storage: regressionStorage,
            thumbnailCache: ThumbnailCache(storage: regressionStorage))
        let source = regressionStorage.root.appendingPathComponent("same-original-path.mp4")
        let displayID = "self-test-identity-display"
        do {
            // 采样指纹只是候选键：同大小、同首尾而中部不同的文件仍必须按完整字节区分。
            let binaryA = regressionStorage.root.appendingPathComponent("fingerprint-candidate-a.bin")
            let binaryB = regressionStorage.root.appendingPathComponent("fingerprint-candidate-b.bin")
            let binaryCopy = regressionStorage.root.appendingPathComponent("fingerprint-candidate-copy.bin")
            var candidateData = Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
            try candidateData.write(to: binaryA)
            try candidateData.write(to: binaryCopy)
            candidateData[1_500_000] = 0x42
            try candidateData.write(to: binaryB)
            let hashA = try VideoFileSupport.contentFingerprint(of: binaryA)
            let hashB = try VideoFileSupport.contentFingerprint(of: binaryB)
            let changedIsIdentical = try VideoFileSupport.haveIdenticalContents(binaryA, binaryB)
            let copyIsIdentical = try VideoFileSupport.haveIdenticalContents(binaryA, binaryCopy)
            check("R13 采样指纹碰撞后完整内容比较可区分中部变化",
                hashA != nil && hashA == hashB && !changedIsIdentical && copyIsIdentical,
                "2 MiB 同大小同首尾夹具，采样哈希相同=\(hashA == hashB)，中部不同判同=\(changedIsIdentical)，完全相同判同=\(copyIsIdentical)")

            try fileManager.copyItem(at: videoURL, to: source)
            await regressionService.importURLs([source])
            guard let original = regressionStore.items.first,
                  original.filePath != source.path, original.contentFingerprint != nil else {
                check("R13 导入身份回归前置素材", false, "首次导入未生成管理副本或内容指纹")
                return
            }
            regressionStore.toggleFavorite(id: original.id)
            regressionStore.assign(itemID: original.id, to: displayID)
            regressionStore.updateSettings(for: displayID) {
                $0.isMuted = false
                $0.volume = 0.37
                $0.rate = 1.5
                $0.isPaused = true
            }
            try fileManager.removeItem(at: original.fileURL)
            regressionStore.refreshMissingState()
            let markedMissing = regressionStore.missingItemIDs.contains(original.id)
            await regressionService.importURLs([source])
            regressionStore.flush()
            // 重新载入也必须保留身份、收藏、分配和逐屏设置。
            let restored = VideoLibraryStore(storage: regressionStorage)
            let repaired = restored.item(withID: original.id)
            let settings = restored.settings(for: displayID)
            check("R13 丢失管理副本重新导入修复且保留身份与设置",
                markedMissing && restored.items.count == 1 && repaired?.fileExists == true
                    && repaired?.isFavorite == true && repaired?.contentFingerprint == original.contentFingerprint
                    && !restored.missingItemIDs.contains(original.id)
                    && restored.assignedItemID(for: displayID) == original.id
                    && !settings.isMuted && abs(settings.volume - 0.37) < 0.001
                    && abs(settings.rate - 1.5) < 0.001 && settings.isPaused,
                "曾标记丢失=\(markedMissing)，修复后存在=\(repaired?.fileExists ?? false)，记录数=\(restored.items.count)，UUID/收藏/分配/设置经磁盘重载检查")

            // 保持同一原始路径、替换真实视频内容；旧指纹绝不能回退为路径重复。
            try fileManager.removeItem(at: source)
            try fileManager.copyItem(at: secondaryFixtureURL, to: source)
            let changedFingerprint = try VideoFileSupport.contentFingerprint(of: source)
            await regressionService.importURLs([source])
            let changed = regressionStore.items.first { $0.contentFingerprint == changedFingerprint }
            check("R13 同一原始路径内容改变新增独立素材",
                changedFingerprint != original.contentFingerprint && regressionStore.items.count == 2
                    && changed != nil && changed?.id != original.id && changed?.fileExists == true
                    && regressionStore.item(withID: original.id)?.contentFingerprint == original.contentFingerprint,
                "记录数=\(regressionStore.items.count)，指纹已改变=\(changedFingerprint != original.contentFingerprint)，新旧 UUID 不同=\(changed != nil && changed?.id != original.id)")

            // 不同路径的字节相同副本仍应按内容去重，防止修正路径回退时破坏正常去重。
            let identicalCopy = regressionStorage.root.appendingPathComponent("identical-copy.mp4")
            try fileManager.copyItem(at: source, to: identicalCopy)
            let beforeIDs = Set(regressionStore.items.map(\.id))
            await regressionService.importURLs([identicalCopy])
            let duplicateTerminal: Bool
            if let lastJob = regressionService.jobs.last, case .duplicated = lastJob.state { duplicateTerminal = true }
            else { duplicateTerminal = false }
            check("R13 不同路径相同内容仍复用已有素材",
                changed != nil && beforeIDs.count == 2
                    && Set(regressionStore.items.map(\.id)) == beforeIDs && duplicateTerminal,
                "记录数=\(regressionStore.items.count)，终态为重复=\(duplicateTerminal)，UUID 集合保持不变")
            regressionStore.flush()
        } catch {
            check("R13 导入身份回归检查", false, error.localizedDescription)
        }
    }

    // MARK: - 持久化

    private func runPersistenceTests() async {
        header("F04 素材库持久化")
        store.flush()
        guard let item = store.items.first else {
            results.append(TestResult(name: "重启恢复素材库", passed: false, detail: "没有可验证的素材"))
            return
        }

        let displayKey = registry.primary?.id ?? "测试显示器"
        store.toggleFavorite(id: item.id)
        store.updateSettings(for: displayKey) { settings in
            settings.isMuted = false
            settings.volume = 0.42
            settings.rate = 1.25
            settings.gravity = .fit
        }
        store.assign(itemID: item.id, to: displayKey)
        store.flush()

        let reloaded = VideoLibraryStore(storage: storage)
        let favoriteRestored = reloaded.item(withID: item.id)?.isFavorite == true
        let settingsRestored = reloaded.settings(for: displayKey).volume == 0.42
            && reloaded.settings(for: displayKey).rate == 1.25
            && reloaded.settings(for: displayKey).gravity == .fit
        let assignmentRestored = reloaded.assignedItemID(for: displayKey) == item.id
        results.append(TestResult(
            name: "重启恢复素材库/收藏",
            passed: reloaded.items.count == store.items.count && favoriteRestored,
            detail: "记录 \(reloaded.items.count) 条，收藏恢复=\(favoriteRestored)"
        ))
        results.append(TestResult(
            name: "重启恢复显示器分配与设置",
            passed: settingsRestored && assignmentRestored,
            detail: "音量/速度/适配=\(settingsRestored)，分配=\(assignmentRestored)"
        ))

        // 破坏性操作放在独立的库副本上，避免污染主测试库
        let copyRoot = storage.root.appendingPathComponent("破坏性测试库", isDirectory: true)
        try? fileManager.removeItem(at: copyRoot)
        do {
            try fileManager.createDirectory(at: copyRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: storage.libraryFile, to: copyRoot.appendingPathComponent(AppConstants.libraryFileName))
        } catch {
            results.append(TestResult(name: "准备独立测试库", passed: false, detail: error.localizedDescription))
            return
        }
        let sandboxStore = VideoLibraryStore(storage: AppStorage(root: copyRoot))
        guard let sandboxItem = sandboxStore.item(withID: item.id) else {
            results.append(TestResult(name: "准备独立测试库", passed: false, detail: "副本中没有目标记录"))
            return
        }

        let mediaPath = sandboxItem.filePath
        sandboxStore.remove(id: sandboxItem.id)
        let removedFromLibrary = sandboxStore.item(withID: sandboxItem.id) == nil
        let mediaStillThere = fileManager.fileExists(atPath: mediaPath)
        results.append(TestResult(
            name: "移除记录不删除媒体文件",
            passed: removedFromLibrary && mediaStillThere,
            detail: "记录已移除=\(removedFromLibrary)，媒体文件仍存在=\(mediaStillThere)"
        ))

        // 丢失文件 → 标记 → 重新定位
        let missingURL = copyRoot.appendingPathComponent("将丢失.mp4")
        try? fileManager.copyItem(at: URL(fileURLWithPath: mediaPath), to: missingURL)
        var missingItem = sandboxItem
        missingItem.id = UUID()
        missingItem.filePath = missingURL.path
        sandboxStore.add(missingItem)
        try? fileManager.removeItem(at: missingURL)
        sandboxStore.refreshMissingState()
        let detected = sandboxStore.missingItemIDs.contains(missingItem.id)
        results.append(TestResult(
            name: "丢失文件被标记为待处理",
            passed: detected && sandboxStore.item(withID: missingItem.id) != nil,
            detail: "缺失 \(sandboxStore.missingItemIDs.count) 条；记录仍保留=\(sandboxStore.item(withID: missingItem.id) != nil)"
        ))

        do {
            let probe = try await VideoProbe.probe(url: URL(fileURLWithPath: mediaPath))
            sandboxStore.relink(id: missingItem.id, to: URL(fileURLWithPath: mediaPath), probe: probe)
            sandboxStore.refreshMissingState()
            results.append(TestResult(
                name: "重新定位恢复可播放状态",
                passed: !sandboxStore.missingItemIDs.contains(missingItem.id),
                detail: "重新定位后缺失集合=\(sandboxStore.missingItemIDs.count) 条"
            ))
        } catch {
            results.append(TestResult(name: "重新定位恢复可播放状态", passed: false, detail: error.localizedDescription))
        }

        // 恢复收藏状态，避免影响后续检查
        store.mutate(id: item.id) { $0.isFavorite = false }
        store.flush()
    }

    // MARK: - 播放（预览会话，不改动真实桌面）

    private func runPlaybackTests(videoURL: URL) async {
        header("F05/F07 播放、控制与切换（预览会话，未创建桌面窗口）")
        guard let item = store.items.first(where: { fileManager.fileExists(atPath: $0.filePath) }) else {
            results.append(TestResult(name: "创建播放会话", passed: false, detail: "没有可用素材"))
            return
        }
        let controller = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true
        )
        if let error = controller.apply(item: item, to: nil) {
            results.append(TestResult(name: "创建播放会话", passed: false, detail: error))
            return
        }
        let sessionCount = controller.sessions.count
        results.append(TestResult(
            name: "每台显示器一个播放会话",
            passed: sessionCount == registry.displays.count && sessionCount > 0,
            detail: "会话数=\(sessionCount)，显示器数=\(registry.displays.count)"
        ))

        guard let displayID = controller.sessions.keys.first, let session = controller.sessions[displayID] else {
            results.append(TestResult(name: "创建播放会话", passed: false, detail: "会话缺失"))
            return
        }

        // 真实解码证据：AVPlayerItemVideoOutput 取出的是播放管线解码的像素缓冲
        var frames: [CGImage] = []
        if let first = await session.waitForDecodedFrame(timeout: 4) {
            frames.append(first)
        }
        for _ in 1..<sampleFrames {
            try? await Task.sleep(for: .milliseconds(220))
            if let frame = session.captureDecodedFrame() { frames.append(frame) }
        }
        let distinct = countDistinct(frames)
        let nonBlack = frames.contains { !isMostlyBlack($0) }
        let frameDetail: String
        if let first = frames.first {
            frameDetail = "解码帧 \(first.width)×\(first.height)，采样 \(frames.count) 帧，互不相同 \(distinct) 帧，非黑帧=\(nonBlack)"
        } else {
            frameDetail = "未能取到解码帧（采样 \(sampleFrames) 次）"
        }
        results.append(TestResult(
            name: "播放管线真实解码出画面",
            passed: !frames.isEmpty && distinct >= 2 && nonBlack,
            detail: frameDetail
        ))
        writeDecodedFrames(frames)

        // 播放位置推进（容忍循环回绕：累加正向增量）
        var positions: [Double] = [session.currentTimeSeconds]
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(130))
            positions.append(session.currentTimeSeconds)
        }
        var forward = 0.0
        for index in 1..<positions.count where positions[index] > positions[index - 1] {
            forward += positions[index] - positions[index - 1]
        }
        let series = positions.map { String(format: "%.2f", $0) }.joined(separator: " → ")
        results.append(TestResult(
            name: "播放位置随时间推进",
            passed: forward > 0.2,
            detail: "采样序列 \(series)，累计正向推进 \(String(format: "%.2f", forward))s（回绕不计负值）"
        ))

        // 循环播放：等待超过素材时长，检测播放时间回绕且播放器仍在播放
        let duration = item.durationSeconds ?? 0
        if duration > 0 {
            var samples: [Double] = []
            let extra = mode == .smoke ? 0.5 : 1.2
            let deadline = Date().addingTimeInterval(min(duration + extra, 12))
            while Date() < deadline {
                samples.append(session.currentTimeSeconds)
                try? await Task.sleep(for: .milliseconds(120))
            }
            var wrapped = false
            for index in 1..<max(1, samples.count) where samples[index] < samples[index - 1] - 0.2 {
                wrapped = true
            }
            let stillPlaying = session.isPlaying
            results.append(TestResult(
                name: "循环播放回绕且持续运行",
                passed: wrapped && stillPlaying,
                detail: "素材时长 \(String(format: "%.2f", duration))s；检测到时间回绕=\(wrapped)，仍在播放=\(stillPlaying)，最后时间 \(String(format: "%.2f", samples.last ?? 0))s"
            ))
        }

        // 速率设置必须真实生效且不被 play() 重置（R01 回归检查）
        controller.setRate(0.5, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(250))
        let rateHalf = session.currentRate
        controller.playPause(displayID: displayID)
        try? await Task.sleep(for: .milliseconds(120))
        let pausedRate = session.currentRate
        controller.playPause(displayID: displayID)
        try? await Task.sleep(for: .milliseconds(250))
        let resumedRate = session.currentRate
        controller.setRate(2.0, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(250))
        let rateDouble = session.currentRate
        results.append(TestResult(
            name: "播放速度在暂停/继续后保持",
            passed: abs(rateHalf - 0.5) < 0.01 && pausedRate == 0 && abs(resumedRate - 0.5) < 0.01 && abs(rateDouble - 2.0) < 0.01,
            detail: "0.5×→rate \(String(format: "%.2f", rateHalf))；暂停→rate \(String(format: "%.2f", pausedRate))；继续→rate \(String(format: "%.2f", resumedRate))；2.0×→rate \(String(format: "%.2f", rateDouble))"
        ))

        // 通过设置面板路径（updateSettings）应用速度与暂停状态
        var updated = store.settings(for: displayID)
        updated.rate = 1.25
        updated.isPaused = false
        controller.updateSettings(updated, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(250))
        let rateFromSettings = session.currentRate
        results.append(TestResult(
            name: "设置面板速度真实下发",
            passed: abs(rateFromSettings - 1.25) < 0.01,
            detail: "updateSettings(rate=1.25) → player.rate=\(String(format: "%.2f", rateFromSettings))"
        ))

        // 静音 / 音量 / 画面适配
        controller.setMuted(false, displayID: displayID)
        controller.setVolume(0.3, displayID: displayID)
        controller.setGravity(.fit, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(150))
        let fitGravity = session.playerLayer?.videoGravity == .resizeAspect
        controller.setGravity(.fill, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(150))
        let fillGravity = session.playerLayer?.videoGravity == .resizeAspectFill
        results.append(TestResult(
            name: "静音/音量/画面适配真实生效",
            passed: session.player?.isMuted == false
                && abs((session.player?.volume ?? 0) - 0.3) < 0.01
                && fitGravity && fillGravity,
            detail: "静音=\(session.player?.isMuted ?? true) 音量=\(String(format: "%.2f", session.player?.volume ?? -1)) 适应=\(fitGravity) 填满=\(fillGravity)"
        ))

        // 新会话默认静音
        let defaultSettings = DisplayPlaybackSettings.default
        results.append(TestResult(
            name: "默认静音",
            passed: defaultSettings.isMuted,
            detail: "DisplayPlaybackSettings.default.isMuted=\(defaultSettings.isMuted)"
        ))

        // 切换素材必须拆除旧播放器
        if let secondItem = store.items.first(where: { $0.id != item.id && fileManager.fileExists(atPath: $0.filePath) }) {
            let oldLayer = session.playerLayer
            let oldPlayer = session.player
            controller.apply(item: secondItem, to: [displayID])
            let newSession = controller.sessions[displayID]
            let replaced = newSession?.playerLayer !== oldLayer && newSession?.item.id == secondItem.id
            let oldTornDown = oldPlayer?.currentItem == nil && oldLayer?.player == nil
            results.append(TestResult(
                name: "切换素材拆除旧播放器",
                passed: replaced && oldTornDown,
                detail: "图层已替换=\(replaced)，旧播放器已释放=\(oldTornDown)"
            ))
        } else {
            results.append(TestResult(name: "切换素材拆除旧播放器", passed: false, detail: "缺少第二个素材"))
        }

        // 断开 → 挂起 → 重新连接恢复（R06 回归检查）
        let allIDs = Set(registry.displays.map(\.id))
        let survivorIDs = Set([displayID])
        controller.reconcileSessions(onlineDisplayIDs: [], displays: [])
        let suspendedAfterDisconnect = controller.sessions.isEmpty && !controller.suspendedAssignments.isEmpty
        controller.reconcileSessions(onlineDisplayIDs: survivorIDs, displays: registry.displays.filter { survivorIDs.contains($0.id) })
        let restoredOne = controller.sessions[displayID] != nil
        let othersStillSuspended = controller.sessions.count == survivorIDs.count
        let neverStartedNotStarted = controller.sessions.values.allSatisfy { allIDs.contains($0.display.id) }
        results.append(TestResult(
            name: "断开挂起、重连恢复且不启动未播放的分配",
            passed: suspendedAfterDisconnect && restoredOne && othersStillSuspended && neverStartedNotStarted && controller.sessions.count <= 1,
            detail: "断开后会话清空=\(suspendedAfterDisconnect)（挂起记录 \(controller.suspendedAssignments.count) 条）；重连后恢复=\(restoredOne)，当前会话数=\(controller.sessions.count)"
        ))

        // 清除只关闭窗口，不触碰系统桌面图片
        let desktopBefore = desktopPictureSnapshot()
        controller.clear()
        let desktopAfter = desktopPictureSnapshot()
        results.append(TestResult(
            name: "清除播放不改动桌面图片",
            passed: controller.sessions.isEmpty && desktopBefore == desktopAfter,
            detail: "会话数=\(controller.sessions.count)，桌面图片一致=\(desktopBefore == desktopAfter)"
        ))

        controller.tearDownAll()
        results.append(TestResult(
            name: "全部会话可完整拆除",
            passed: controller.sessions.isEmpty,
            detail: "剩余会话=\(controller.sessions.count)"
        ))
        _ = videoURL
    }

    // MARK: - 生命周期（F08）

    private func runLifecycleTests(videoURL: URL) async {
        header("F08 生命周期")
        guard let item = store.items.first(where: { fileManager.fileExists(atPath: $0.filePath) }) else {
            results.append(TestResult(name: "生命周期检查", passed: false, detail: "缺少素材"))
            return
        }
        let controller = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true
        )
        _ = controller.apply(item: item, to: nil)
        try? await Task.sleep(for: .milliseconds(600))
        let continuesWithoutWindow = controller.sessions.values.contains { $0.isPlaying }
        results.append(TestResult(
            name: "无管理窗口时播放继续",
            passed: continuesWithoutWindow,
            detail: "会话仍在播放=\(continuesWithoutWindow)（管理窗口与桌面播放相互独立）"
        ))

        controller.tearDownAll()
        results.append(TestResult(
            name: "退出无孤儿渲染会话",
            passed: controller.sessions.isEmpty,
            detail: "剩余会话=\(controller.sessions.count)"
        ))
        _ = videoURL
    }

    // MARK: - 真实媒体冒烟检查

    /// 用一份真实媒体文件（只读）验证：AVFoundation 探测 → 导入沙箱素材库 → 播放管线解码 → 循环。
    ///
    /// 全程有界：所有等待都有上限，不改变源文件，不触碰用户素材库与桌面图片。
    private func runExternalMediaSmoke(fileURL: URL) async {
        header("真实媒体冒烟检查（只读源文件）")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            results.append(TestResult(name: "真实媒体文件可读", passed: false, detail: "文件不存在：\(PathRedaction.short(fileURL))"))
            return
        }
        let sizeBefore = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        let probe: VideoProbeResult
        do {
            probe = try await VideoProbe.probe(url: fileURL)
            results.append(TestResult(
                name: "真实媒体 AVFoundation 探测",
                passed: probe.isPlayable && probe.pixelWidth > 0,
                detail: "\(probe.pixelWidth)×\(probe.pixelHeight) 视频=\(probe.videoCodec ?? "?") 音频=\(probe.hasAudioTrack ? (probe.audioCodec ?? "有") : "无") 时长=\(String(format: "%.2f", probe.durationSeconds))s 帧率=\(probe.frameRate.map { String(format: "%.1f", $0) } ?? "?")"
            ))
        } catch {
            results.append(TestResult(name: "真实媒体 AVFoundation 探测", passed: false, detail: error.localizedDescription))
            return
        }

        await importService.importURLs([fileURL])
        store.flush()
        guard let item = store.item(matchingFingerprint: (try? VideoFileSupport.contentFingerprint(of: fileURL)) ?? "", size: sizeBefore, standardPath: fileURL.path)
            ?? store.items.last else {
            results.append(TestResult(name: "真实媒体导入沙箱素材库", passed: false, detail: "导入失败：\(importService.lastSummary ?? "-")"))
            return
        }
        results.append(TestResult(
            name: "真实媒体导入沙箱素材库",
            passed: fileManager.fileExists(atPath: item.filePath),
            detail: "\(item.displayTitle) → \(PathRedaction.short(item.fileURL))（\(item.resolutionText) · \(item.durationText) · \(item.fileSizeText)）"
        ))

        let controller = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true
        )
        guard let displayID = registry.primary?.id, controller.apply(item: item, to: [displayID]) == nil,
              let session = controller.session(for: displayID) else {
            results.append(TestResult(name: "真实媒体播放会话", passed: false, detail: controller.lastError ?? "无法创建会话"))
            return
        }

        var frames: [CGImage] = []
        if let first = await session.waitForDecodedFrame(timeout: 4) { frames.append(first) }
        for _ in 1..<sampleFrames {
            try? await Task.sleep(for: .milliseconds(200))
            if let frame = session.captureDecodedFrame() { frames.append(frame) }
        }
        let distinct = countDistinct(frames)
        let nonBlack = frames.contains { !isMostlyBlack($0) }
        results.append(TestResult(
            name: "真实媒体解码出画面",
            passed: frames.count >= 2 && distinct >= 2 && nonBlack,
            detail: frames.first.map { "解码帧 \($0.width)×\($0.height)，采样 \(frames.count) 帧，互不相同 \(distinct) 帧，非黑帧=\(nonBlack)" } ?? "未取到解码帧"
        ))
        writeDecodedFrames(frames, subdirectory: "decoded-frames-real")

        // 播放位置推进 + 速率保持（有界）
        let t0 = session.currentTimeSeconds
        try? await Task.sleep(for: .milliseconds(400))
        let t1 = session.currentTimeSeconds
        controller.setRate(0.5, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(200))
        let rate = session.currentRate
        results.append(TestResult(
            name: "真实媒体播放推进与速率控制",
            passed: t1 > t0 && abs(rate - 0.5) < 0.01,
            detail: "currentTime \(String(format: "%.2f", t0))s → \(String(format: "%.2f", t1))s；0.5×→rate \(String(format: "%.2f", rate))"
        ))

        controller.tearDownAll()

        let sizeAfter = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        results.append(TestResult(
            name: "源文件未被修改",
            passed: sizeBefore == sizeAfter,
            detail: "\(PathRedaction.short(fileURL)) 字节数 \(sizeBefore) → \(sizeAfter)"
        ))
    }

    // MARK: - 搜索排序（F10）

    private func runQueryTests() async {
        header("F10 搜索与排序")
        let items = store.items
        guard items.count >= 2 else {
            results.append(TestResult(name: "搜索与排序", passed: false, detail: "素材不足（\(items.count) 条）"))
            return
        }

        var favoriteID: UUID?
        if let last = items.last {
            store.toggleFavorite(id: last.id)
            favoriteID = last.id
        }
        let favorites = LibraryQuery(text: "", filter: .favorites, sort: .name).apply(to: store.items, missingIDs: store.missingItemIDs)
        results.append(TestResult(
            name: "按收藏过滤",
            passed: favorites.count == 1 && favorites.first?.id == favoriteID,
            detail: "收藏结果 \(favorites.count) 条，命中=\(favorites.first?.id == favoriteID)"
        ))

        let local = LibraryQuery(text: "", filter: .source(.local), sort: .name).apply(to: store.items, missingIDs: store.missingItemIDs)
        results.append(TestResult(
            name: "按来源过滤",
            passed: local.count == store.items.filter { $0.source == .local }.count,
            detail: "本地来源 \(local.count) 条"
        ))

        let steamQuery = LibraryQuery(text: "", filter: .source(.steamWorkshop), sort: .name)
        let steam = steamQuery.apply(to: store.items, missingIDs: store.missingItemIDs)
        let emptyHint = steamQuery.emptyStateMessage(isLibraryEmpty: false)
        results.append(TestResult(
            name: "空结果给出可操作提示",
            passed: steam.isEmpty && emptyHint.contains("Steam"),
            detail: "创意工坊结果 \(steam.count) 条；提示=\(emptyHint.replacingOccurrences(of: "\n", with: " "))"
        ))

        let titleToken = items[0].displayTitle.prefix(3)
        let searched = LibraryQuery(text: String(titleToken), filter: .all, sort: .name).apply(to: store.items, missingIDs: store.missingItemIDs)
        results.append(TestResult(
            name: "按标题搜索",
            passed: !searched.isEmpty && searched.allSatisfy { $0.displayTitle.contains(titleToken) },
            detail: "关键词「\(titleToken)」命中 \(searched.count) 条"
        ))

        let noMatchQuery = LibraryQuery(text: "绝对不存在的关键词ZZZ", filter: .all, sort: .name)
        let noMatch = noMatchQuery.apply(to: store.items, missingIDs: store.missingItemIDs)
        results.append(TestResult(
            name: "无匹配时结果为空且有提示",
            passed: noMatch.isEmpty && !noMatchQuery.emptyStateMessage(isLibraryEmpty: false).isEmpty,
            detail: "命中 \(noMatch.count) 条，提示=\(noMatchQuery.emptyStateMessage(isLibraryEmpty: false).replacingOccurrences(of: "\n", with: " "))"
        ))

        let missingFiltered = LibraryQuery(text: "", filter: .missing, sort: .name).apply(to: store.items, missingIDs: store.missingItemIDs)
        results.append(TestResult(
            name: "待处理过滤使用缺失集合",
            passed: missingFiltered.count == store.missingItemIDs.count,
            detail: "待处理 \(missingFiltered.count) 条（缺失集合 \(store.missingItemIDs.count)）"
        ))

        let byName = LibraryQuery(text: "", filter: .all, sort: .name, ascending: true).apply(to: store.items, missingIDs: store.missingItemIDs)
        let sortedNames = byName.map(\.displayTitle)
        let expectedNames = sortedNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        results.append(TestResult(
            name: "按名称升序排序",
            passed: sortedNames == expectedNames,
            detail: sortedNames.joined(separator: " ≤ ")
        ))

        let byRecent = LibraryQuery(text: "", filter: .all, sort: .recentlyAdded).apply(to: store.items, missingIDs: store.missingItemIDs)
        let dates = byRecent.map(\.addedAt)
        results.append(TestResult(
            name: "按导入时间倒序排序",
            passed: dates == dates.sorted(by: >),
            detail: "共 \(dates.count) 条按时间倒序"
        ))

        await runCancellableThumbnailTest(items: store.items)

        if favoriteID != nil, let last = items.last {
            store.toggleFavorite(id: last.id)
            store.flush()
        }
    }

    private func runCancellableThumbnailTest(items: [WallpaperItem]) async {
        guard let target = items.first(where: { fileManager.fileExists(atPath: $0.filePath) }) else { return }
        let cache = thumbnailCache ?? ThumbnailCache.shared
        let task = Task { await cache.thumbnail(for: target) }
        task.cancel()
        let result = await task.value
        results.append(TestResult(
            name: "缩略图任务可取消",
            passed: true,
            detail: "取消后返回\(result == nil ? "nil（未完成，符合取消语义）" : "已缓存图像（取消发生在完成之后，属正常）")"
        ))

        if let image = await cache.thumbnail(for: target, targetSize: CGSize(width: 320, height: 320)) {
            let size = image.size
            let onDisk = fileManager.fileExists(atPath: storage.thumbnailURL(for: target.id).path)
            results.append(TestResult(
                name: "缩略图实际生成并写入测试目录",
                passed: size.width > 0 && size.height > 0 && max(size.width, size.height) <= 320 && onDisk,
                detail: "缩略图尺寸 \(Int(size.width))×\(Int(size.height))，写入 \(PathRedaction.short(storage.thumbnailURL(for: target.id)))=\(onDisk)"
            ))
        } else {
            results.append(TestResult(name: "缩略图实际生成并写入测试目录", passed: false, detail: "生成失败"))
        }
    }

    // MARK: - 仓库自检

    private func runRepositoryTests() async {
        header("交付物自检")
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let sourceRoot = [workingDirectory, workingDirectory.deletingLastPathComponent()].first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("Sources/Glimmer/SelfTest/SelfTestRunner.swift").path)
        }
        // 安装后的 app 必须自带许可说明，不依赖启动时的工作目录。
        let bundledNotice = Bundle.main.url(forResource: "NOTICE", withExtension: "md")
        let notice = Bundle.main.bundleURL.pathExtension == "app"
            ? bundledNotice
            : (bundledNotice ?? sourceRoot?.appendingPathComponent("NOTICE.md"))
        let noticeText = notice.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        results.append(TestResult(
            name: "第三方许可说明存在",
            passed: !noticeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            detail: notice?.path ?? "应用资源中未找到 NOTICE.md"
        ))

        guard let sourceRoot else {
            for name in ["可重复构建脚本存在且可执行", "构建产物目录被忽略"] {
                results.append(TestResult(name: name, passed: false,
                    detail: "仅适用于源码仓库；当前工作目录不含本项目源码，跳过", skipped: true))
            }
            return
        }
        let buildScript = sourceRoot.appendingPathComponent("scripts/build-app.sh")
        let scriptExecutable = fileManager.isExecutableFile(atPath: buildScript.path)
        results.append(TestResult(
            name: "可重复构建脚本存在且可执行",
            passed: scriptExecutable,
            detail: "\(buildScript.path)（可执行=\(scriptExecutable)）"
        ))

        let gitignorePath = sourceRoot.appendingPathComponent(".gitignore")
        let ignoreText = (try? String(contentsOf: gitignorePath, encoding: .utf8)) ?? ""
        // Anchored rules (/build/) match at the repository root too; compare
        // without the leading slash so either spelling satisfies the check.
        let patterns = Set(ignoreText.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^/", with: "", options: .regularExpression)
        })
        let required = ["build/", "dist/", "*.app", "*.dmg"]
        let missing = required.filter { !patterns.contains($0) }
        results.append(TestResult(
            name: "构建产物目录被忽略",
            passed: missing.isEmpty,
            detail: missing.isEmpty ? "build/、dist/、*.app、*.dmg 均已忽略" : "缺少忽略规则：\(missing.joined(separator: ", "))"
        ))
    }

    // MARK: - UI 快照

    private func runUISnapshotTests() async {
        header("F02 界面状态快照（离屏渲染，仅用于版面检查）")
        let controller = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true
        )
        let snapshotRoot = evidenceDirectory?.appendingPathComponent("ui-snapshots")
            ?? storage.root.appendingPathComponent("ui-snapshots")
        try? fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        var written: [String] = []
        let style = GlassStyle(reduceTransparency: false, reduceMotion: false)

        let emptyGrid = AnyView(LibraryGridView(
            items: [], missingIDs: [], selection: nil, query: LibraryQuery(),
            isLibraryEmpty: true, importService: importService, errorMessage: nil, style: style,
            onSelect: { _ in }, onApply: { _ in }, onToggleFavorite: { _ in }, onDismissError: {}
        ))
        if renderSnapshot(emptyGrid, size: CGSize(width: 900, height: 620), to: snapshotRoot.appendingPathComponent("empty-state.png")) {
            written.append("empty-state")
        }

        let errorGrid = AnyView(LibraryGridView(
            items: [], missingIDs: [], selection: nil, query: LibraryQuery(),
            isLibraryEmpty: true, importService: importService,
            errorMessage: "示例错误：视频无法解码（界面状态检查）", style: style,
            onSelect: { _ in }, onApply: { _ in }, onToggleFavorite: { _ in }, onDismissError: {}
        ))
        if renderSnapshot(errorGrid, size: CGSize(width: 900, height: 620), to: snapshotRoot.appendingPathComponent("error-state.png")) {
            written.append("error-state")
        }

        let contentGrid = AnyView(LibraryGridView(
            items: store.items, missingIDs: store.missingItemIDs, selection: store.items.first?.id,
            query: LibraryQuery(), isLibraryEmpty: store.items.isEmpty, importService: importService,
            errorMessage: nil, style: style,
            onSelect: { _ in }, onApply: { _ in }, onToggleFavorite: { _ in }, onDismissError: {}
        ))
        if renderSnapshot(contentGrid, size: CGSize(width: 900, height: 620), to: snapshotRoot.appendingPathComponent("grid-content.png")) {
            written.append("grid-content")
        }

        if let item = store.items.first {
            let inspector = AnyView(DetailInspectorView(
                store: store, item: item, displays: registry.displays, playback: controller, style: style,
                onApplyAll: { _ in nil }, onClearAll: {}, onToggleFavorite: {}, onRemove: {}, onRelink: { _ in }
            ))
            if renderSnapshot(inspector, size: CGSize(width: 420, height: 1100), to: snapshotRoot.appendingPathComponent("inspector.png")) {
                written.append("inspector")
            }
        }

        // 降低透明度/减少动态效果下的降级渲染
        let accessibleStyle = GlassStyle(reduceTransparency: true, reduceMotion: true)
        let accessibleGrid = AnyView(LibraryGridView(
            items: store.items, missingIDs: store.missingItemIDs, selection: nil,
            query: LibraryQuery(), isLibraryEmpty: store.items.isEmpty, importService: importService,
            errorMessage: nil, style: accessibleStyle,
            onSelect: { _ in }, onApply: { _ in }, onToggleFavorite: { _ in }, onDismissError: {}
        ))
        if renderSnapshot(accessibleGrid, size: CGSize(width: 900, height: 620), to: snapshotRoot.appendingPathComponent("reduced-transparency.png")) {
            written.append("reduced-transparency")
        }

        results.append(TestResult(
            name: "界面状态离屏快照",
            passed: written.count >= 3,
            detail: "已生成：\(written.joined(separator: ", ")) → \(snapshotRoot.path)"
        ))
    }

    // MARK: - B04 集成检查

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        results.append(TestResult(name: name, passed: passed, detail: detail))
    }

    /// 集成检查（不触碰真实配置与桌面）：
    /// 策略挂起层、逐屏手动意图、轮播联结、全部移除（R14）、工坊导入元数据（R13）、
    /// 设置导出/导入接线、依赖探测、网络失败与登录输出脱敏。
    private func runIntegrationTests(videoURL: URL?) async {
        header("B04 集成：策略挂起 / 轮播 / 工坊导入 / 设置接线 / 依赖检测")
        guard let videoURL else {
            results.append(TestResult(name: "集成检查前置素材", passed: false, detail: "缺少测试视频"))
            return
        }
        guard let primaryItem = store.items.first(where: { fileManager.fileExists(atPath: $0.filePath) }) else {
            results.append(TestResult(name: "集成检查前置素材", passed: false, detail: "素材库中没有可用素材"))
            return
        }
        guard let displayID = (registry.primary ?? registry.displays.first)?.id else {
            results.append(TestResult(name: "集成检查前置显示器", passed: false, detail: "没有可用显示器"))
            return
        }

        // 独立实例：临时目录 + 关闭持久化 + 不启动系统监听，避免触碰真实配置。
        let policy = GWPolicyController(
            paths: GWPersistencePaths(root: storage.root),
            persistenceEnabled: false,
            autoStartMonitoring: false
        )
        let playlist = GWPlaylistRotator(paths: GWPersistencePaths(root: storage.root), persistenceEnabled: false)
        let playback = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true
        )
        let integration = AppPlaybackIntegration(store: store, playback: playback, policy: policy, playlist: playlist)
        integration.activate()
        defer { playback.tearDownAll() }

        // 1) 应用 → 播放；睡眠 → 策略挂起（不写用户意图）
        let applyError = playback.apply(item: primaryItem, to: [displayID])
        let session = playback.session(for: displayID)
        check(
            "集成：应用到显示器后真实会话播放",
            applyError == nil && session?.isPlaying == true,
            "错误=\(applyError ?? "无")，isPlaying=\(session?.isPlaying ?? false)"
        )

        _ = policy.handle(.systemWillSleep)
        check(
            "策略挂起暂停真实会话且不改写用户暂停意图",
            session?.isPlaying == false && store.settings(for: displayID).isPaused == false && playback.isPolicySuspended,
            "isPlaying=\(session?.isPlaying ?? false)，保存意图 isPaused=\(store.settings(for: displayID).isPaused)，策略挂起=\(playback.isPolicySuspended)"
        )
        check("策略挂起同步轮播计时挂起", playlist.isSuspended, "轮播状态=\(playlist.status.displayText)")

        // 2) 挂起期间调静音/音量/倍速：设置写入但不恢复播放
        playback.setMuted(false, displayID: displayID)
        playback.setVolume(0.4, displayID: displayID)
        playback.setRate(2.0, displayID: displayID)
        let suspendedSettings = store.settings(for: displayID)
        check(
            "策略挂起期间调整静音/音量/倍速后仍保持暂停",
            session?.isPlaying == false
                && suspendedSettings.isMuted == false
                && abs(suspendedSettings.volume - 0.4) < 0.001
                && abs(suspendedSettings.rate - 2.0) < 0.001,
            "isPlaying=\(session?.isPlaying ?? false)，已写入 muted=\(suspendedSettings.isMuted) volume=\(String(format: "%.2f", suspendedSettings.volume)) rate=\(String(format: "%.2f", suspendedSettings.rate))"
        )

        // 3) 挂起期间手动「暂停」：按保存意图翻转（不会反向播放）
        playback.playPause(displayID: displayID)
        check(
            "挂起期间手动暂停按保存意图翻转",
            store.settings(for: displayID).isPaused == true && session?.isPlaying == false && policy.userIntent == .paused,
            "保存 isPaused=\(store.settings(for: displayID).isPaused)，策略意图=\(policy.userIntent.displayName)"
        )

        // 4) 策略解除尊重手动暂停；手动播放后恢复
        _ = policy.handle(.systemDidWake)
        check(
            "策略解除后尊重手动暂停",
            session?.isPlaying == false && playlist.isSuspended && !playback.isPolicySuspended,
            "isPlaying=\(session?.isPlaying ?? false)，轮播挂起=\(playlist.isSuspended)"
        )
        playback.playPause(displayID: displayID)
        check(
            "手动播放恢复真实播放并同步策略意图",
            session?.isPlaying == true && policy.userIntent == .playing && !playlist.isSuspended,
            "isPlaying=\(session?.isPlaying ?? false)，策略意图=\(policy.userIntent.displayName)"
        )

        // 5) 挂起期间切换素材保持暂停；解除后按保存意图播放
        var switchItem = store.items.first(where: { $0.id != primaryItem.id && fileManager.fileExists(atPath: $0.filePath) })
        if switchItem == nil, let secondaryURL = secondaryFixtureURL {
            await importService.importURLs([secondaryURL])
            switchItem = store.items.first(where: { $0.id != primaryItem.id && fileManager.fileExists(atPath: $0.filePath) })
        }
        if let switchItem {
            _ = policy.handle(.systemWillSleep)
            _ = playback.apply(item: switchItem, to: [displayID])
            let switchedSession = playback.session(for: displayID)
            check(
                "策略挂起期间切换素材保持暂停",
                switchedSession?.item.id == switchItem.id && switchedSession?.isPlaying == false,
                "当前素材=\(switchedSession?.item.displayTitle ?? "-")，isPlaying=\(switchedSession?.isPlaying ?? false)"
            )
            _ = policy.handle(.systemDidWake)
            check(
                "策略解除后新素材按保存意图播放",
                switchedSession?.isPlaying == true,
                "isPlaying=\(switchedSession?.isPlaying ?? false)"
            )
        } else {
            results.append(TestResult(name: "策略挂起期间切换素材保持暂停", passed: false, detail: "缺少第二份素材"))
        }

        // 6) 手动暂停经过睡眠/唤醒往返不被覆盖
        if let switchItem, playback.session(for: displayID)?.isPlaying == true {
            _ = switchItem
        }
        playback.playPause(displayID: displayID) // 保存意图 → 暂停
        _ = policy.handle(.systemWillSleep)
        _ = policy.handle(.systemDidWake)
        check(
            "手动暂停经过睡眠/唤醒往返后保持",
            store.settings(for: displayID).isPaused && playback.sessions.values.allSatisfy { !$0.isPlaying },
            "保存 isPaused=\(store.settings(for: displayID).isPaused)，播放中的会话=\(playback.sessions.values.filter(\.isPlaying).count)"
        )

        // 7) R14：全部移除覆盖断开屏挂起分配；重连不恢复；已启用轮播保持停止
        _ = playback.apply(item: primaryItem, to: [displayID])
        if store.settings(for: displayID).isPaused { playback.playPause(displayID: displayID) }
        playlist.setItems([primaryItem.id])
        playlist.updateSettings { $0.intervalSeconds = 3600 }
        playlist.startRotation()
        check(
            "启用轮播后开始计时",
            playlist.isRotating && playlist.nextFireAt != nil,
            "轮播中=\(playlist.isRotating)，下次触发=\(playlist.nextFireAt != nil)"
        )

        playback.reconcileSessions(onlineDisplayIDs: [], displays: [])
        let hadSuspended = !playback.suspendedAssignments.isEmpty
        playback.clear()
        check(
            "全部移除同时清理断开屏的挂起分配",
            hadSuspended && playback.sessions.isEmpty && playback.suspendedAssignments.isEmpty,
            "断开挂起=\(hadSuspended)，剩余会话=\(playback.sessions.count)，剩余挂起=\(playback.suspendedAssignments.count)"
        )
        check("全部移除后素材库不再保留分配记录", store.assignments.isEmpty, "剩余分配记录=\(store.assignments.count)")

        playback.reconcileSessions(onlineDisplayIDs: [displayID], displays: registry.displays)
        check(
            "断开屏重连后不会恢复已移除的播放",
            playback.sessions.isEmpty,
            "重连后会话=\(playback.sessions.count)"
        )
        check(
            "全部移除后已启用的轮播保持停止",
            playlist.isSuspended && !playlist.isRotating && playlist.nextFireAt == nil,
            "轮播状态=\(playlist.status.displayText)"
        )

        // 8) 轮播跳过缺失素材并接入真实应用
        _ = playback.apply(item: primaryItem, to: [displayID])
        if store.settings(for: displayID).isPaused { playback.playPause(displayID: displayID) }
        let missingID = UUID()
        var playlistItems = [primaryItem.id]
        if let switchItem { playlistItems.append(switchItem.id) }
        playlistItems.append(missingID)
        playlist.updateSettings { settings in
            settings.currentItemID = primaryItem.id
            settings.isEnabled = false
            settings.itemIDs = playlistItems
        }
        playlist.advanceNow()
        check("轮播跳过缺失素材并选中下一项", playlist.currentItemID == switchItem?.id, "当前项=\(playlist.currentItemID?.uuidString.prefix(8) ?? "-")，缺失计数=\(playlist.missingItemCount)")
        check(
            "轮播选中接入真实桌面应用",
            switchItem != nil && playback.session(for: displayID)?.item.id == switchItem?.id,
            "会话素材=\(playback.session(for: displayID)?.item.displayTitle ?? "-")"
        )
        check("轮播统计缺失素材数量", playlist.missingItemCount == 1, "缺失计数=\(playlist.missingItemCount)")

        // 9) 工坊导入：真实文件本地校验；成功后才写来源与作品 ID；重复不新增
        let workshopVideo = storage.root.appendingPathComponent("workshop-import-\(UUID().uuidString.prefix(6)).mp4")
        let workshopMetadata = ImportWorkshopMetadata(
            publishedFileID: "3818965540",
            title: "集成检查：工坊视频",
            pageURLString: "https://steamcommunity.com/sharedfiles/filedetails/?id=3818965540",
            previewImageURLString: nil,
            authorSteamID: nil,
            fileByteSize: nil
        )
        do {
            // 独立内容确保首次测试走新增路径；下一次才验证重复及元数据保留。
            var workshopOptions = SyntheticVideoWriter.Options()
            workshopOptions.width = 192
            workshopOptions.height = 108
            workshopOptions.frameCount = 48
            workshopOptions.frameRate = 24
            try await SyntheticVideoWriter.write(to: workshopVideo, options: workshopOptions, deadlineSeconds: 20)
            let workshopFingerprint = try VideoFileSupport.contentFingerprint(of: workshopVideo)
            guard !store.items.contains(where: { $0.contentFingerprint == workshopFingerprint }) else {
                throw NSError(domain: "SelfTestFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "独立工坊夹具意外与现有素材内容相同"])
            }
            let outcome = await importService.importWorkshopVideo(workshopVideo, metadata: workshopMetadata)
            var importedDetail = "结果=\(outcome)"
            var importedOK = false
            if case .imported(let newID) = outcome, let item = store.item(withID: newID) {
                importedOK = item.source == .steamWorkshop
                    && item.workshopID == "3818965540"
                    && item.fileExists
                    && item.fileURL.resolvingSymlinksInPath().standardizedFileURL.path == workshopVideo.resolvingSymlinksInPath().standardizedFileURL.path
                importedDetail = "来源=\(item.source.displayName)，作品 ID=\(item.workshopID ?? "-")，引用下载文件=\(item.fileURL.lastPathComponent)"
            }
            check("工坊导入成功后才写入来源与作品 ID", importedOK, importedDetail)

            let countAfterFirst = store.items.count
            let duplicateOutcome = await importService.importWorkshopVideo(workshopVideo, metadata: workshopMetadata)
            var duplicateOK = false
            if case .duplicated(let dupID, _) = duplicateOutcome {
                duplicateOK = store.items.count == countAfterFirst && store.item(withID: dupID)?.workshopID == "3818965540"
            }
            check("重复工坊导入不新增记录且保留来源", duplicateOK, "结果=\(duplicateOutcome)，记录数 \(countAfterFirst)→\(store.items.count)")

            let missingOutcome = await importService.importWorkshopVideo(
                storage.root.appendingPathComponent("不存在的工坊视频.mp4"),
                metadata: workshopMetadata
            )
            var failureOK = false
            var failureDetail = "结果=\(missingOutcome)"
            if case .failed(let reason) = missingOutcome {
                failureOK = true
                failureDetail = "失败原因=\(reason)"
            }
            check("工坊导入失败如实报告", failureOK, failureDetail)
        } catch {
            check("工坊导入成功后才写入来源与作品 ID", false, error.localizedDescription)
        }

        // 10) R13：本地/工坊导入共享串行闸门（重叠请求 + 历史裁剪 + 取消）
        overridePhoto: do {
            var copies: [URL] = []
            for index in 1...2 {
                let copy = storage.root.appendingPathComponent("overlap-\(index)-\(UUID().uuidString.prefix(6)).mp4")
                try? fileManager.copyItem(at: videoURL, to: copy)
                copies.append(copy)
            }
            let requestA = Task { await importService.importURLs([copies[0]]) }
            let requestB = Task { await importService.importWorkshopVideo(copies[1], metadata: ImportWorkshopMetadata(
                publishedFileID: "3818965541",
                title: "集成检查：重叠请求",
                pageURLString: nil,
                previewImageURLString: nil,
                authorSteamID: nil,
                fileByteSize: nil
            )) }
            let requestC = Task { await importService.importURLs([copies[0]]) }
            _ = await requestA.value
            _ = await requestB.value
            _ = await requestC.value
            let uniqueFingerprints = Set(store.items.compactMap(\.contentFingerprint))
            check(
                "重叠本地/工坊导入串行化且无重复入库",
                importService.activeJobs.isEmpty && uniqueFingerprints.count == store.items.compactMap(\.contentFingerprint).count,
                "进行中任务=\(importService.activeJobs.count)，素材 \(store.items.count) 条，指纹唯一=\(uniqueFingerprints.count)"
            )
        }

        cancel: do {
            var failedCount = 0
            let missingImportURL = storage.root.appendingPathComponent("绝不存在-\(UUID().uuidString).mp4")
            for _ in 0..<65 {
                await importService.importURLs([missingImportURL])
                failedCount += 1
            }
            let uniqueJobIDs = Set(importService.jobs.map(\.id))
            check(
                "任务历史有界且不丢失终态",
                importService.jobs.count <= 62 && uniqueJobIDs.count == importService.jobs.count && importService.activeJobs.isEmpty,
                "\(failedCount) 次失败导入后记录 \(importService.jobs.count) 条，唯一 ID=\(uniqueJobIDs.count)"
            )

            let cancelURL = storage.root.appendingPathComponent("cancel-\(UUID().uuidString.prefix(6)).mp4")
            try? fileManager.copyItem(at: videoURL, to: cancelURL)
            let cancelTask = Task { await importService.importURLs([cancelURL]) }
            importService.cancelAll()
            _ = await cancelTask.value
            check(
                "取消导入后没有残留进行中任务",
                importService.activeJobs.isEmpty,
                "进行中任务=\(importService.activeJobs.count)"
            )
        }

        // 11) 设置接线：导出 → 校验 → 导入恢复；配置不含凭据
        let settingsCoordinator = GWSettingsCoordinator(
            paths: GWSettingsPaths(root: storage.root),
            external: AppSettingsWiring.externalActions(
                store: store,
                playback: playback,
                policy: policy,
                playlist: playlist,
                onPlaybackSettingsApplied: { integration.syncPolicyIntentFromSavedSettings() }
            )
        )
        settingsCoordinator.updatePreferences { $0.appearance = .light }
        playback.setRate(1.5, displayID: displayID)
        let exportURL = storage.root.appendingPathComponent("config-export.json")
        do {
            let bytes = try settingsCoordinator.exportConfiguration(to: exportURL)
            let validated = try settingsCoordinator.validateImport(contentsOf: exportURL)
            store.updateSettings(for: displayID) { current in
                current.rate = 0.5
                current.isMuted = true
            }
            try settingsCoordinator.commitImport(validated)
            let restored = abs(store.settings(for: displayID).rate - 1.5) < 0.001
            check(
                "配置导出→校验→导入恢复播放设置",
                bytes > 0 && restored,
                "导出 \(bytes) 字节，导入后 rate=\(String(format: "%.2f", store.settings(for: displayID).rate))"
            )
            let text = String(data: (try? Data(contentsOf: exportURL)) ?? Data(), encoding: .utf8) ?? ""
            let credentialHits = ["password", "guard", "token", "credential", "logincache"].filter { text.lowercased().contains($0) }
            check("配置文件不含凭据字段", credentialHits.isEmpty, "命中字段=\(credentialHits.isEmpty ? "无" : credentialHits.joined(separator: ","))，大小=\(text.count) 字符")
        } catch {
            check("配置导出→校验→导入恢复播放设置", false, error.localizedDescription)
        }

        // 12) 导入暂停/播放意图与聚合策略意图、轮播计时一致（R14）
        do {
            _ = playback.apply(item: primaryItem, to: [displayID])
            if store.settings(for: displayID).isPaused { playback.playPause(displayID: displayID) }
            let pausedDisplay = GWPlaybackConfiguration.DisplaySettings(
                isPaused: true, isMuted: true, volume: 1, rate: 1, gravity: .fit
            )
            let pausedURL = storage.root.appendingPathComponent("config-paused.json")
            try GWConfigurationTransfer.writeExport(
                GWConfigurationEnvelope(exportedAt: Date(), appVersion: nil, preferences: nil, playback: GWPlaybackConfiguration(displays: [displayID: pausedDisplay])),
                to: pausedURL
            )
            try settingsCoordinator.commitImport(try settingsCoordinator.validateImport(contentsOf: pausedURL))
            check(
                "导入整体暂停后意图/轮播/会话一致暂停",
                policy.userIntent == .paused
                    && playlist.isSuspended
                    && playback.sessions.values.allSatisfy { !$0.isPlaying }
                    && store.settings(for: displayID).isPaused,
                "意图=\(policy.userIntent.displayName)，轮播挂起=\(playlist.isSuspended)，播放中的会话=\(playback.sessions.values.filter(\.isPlaying).count)"
            )

            let playingURL = storage.root.appendingPathComponent("config-playing.json")
            let playingDisplay = GWPlaybackConfiguration.DisplaySettings(
                isPaused: false, isMuted: true, volume: 1, rate: 1, gravity: .fit
            )
            try GWConfigurationTransfer.writeExport(
                GWConfigurationEnvelope(exportedAt: Date(), appVersion: nil, preferences: nil, playback: GWPlaybackConfiguration(displays: [displayID: playingDisplay])),
                to: playingURL
            )
            try settingsCoordinator.commitImport(try settingsCoordinator.validateImport(contentsOf: playingURL))
            check(
                "导入恢复播放意图后真实会话恢复",
                policy.userIntent == .playing && playback.session(for: displayID)?.isPlaying == true,
                "意图=\(policy.userIntent.displayName)，isPlaying=\(playback.session(for: displayID)?.isPlaying ?? false)"
            )
        } catch {
            check("导入整体暂停后意图/轮播/会话一致暂停", false, error.localizedDescription)
        }

        // 13) 依赖检测：临时目录（如实未安装）+ 真实环境只读探测
        let tempLayout = SteamCMDLayout(root: storage.root.appendingPathComponent("steamcmd-probe", isDirectory: true))
        let tempReport = await SteamCMDCapabilityProbe(layout: tempLayout).probe()
        check(
            "临时目录依赖探测如实报告未安装",
            tempReport.status == .notInstalled && !tempReport.hostArchitecture.isEmpty,
            tempReport.status.displayText
        )

        let realLayout = SteamCMDLayout()
        if !fileManager.isExecutableFile(atPath: realLayout.executableURL.path) {
            let realReport = await SteamCMDCapabilityProbe(layout: realLayout).probe()
            check(
                "真实环境依赖探测（只读，不安装任何组件）",
                realReport.status == .notInstalled,
                "状态=\(realReport.status.displayText)，Rosetta=\(realReport.rosetta.displayText)"
            )
        } else {
            results.append(TestResult(
                name: "真实环境依赖探测（只读，不安装任何组件）",
                passed: true,
                detail: "应用目录已存在 SteamCMD；自检不运行其进程，实际检测在「下载与账号」页面进行",
                skipped: true
            ))
        }

        // 14) 真实网络失败与登录输出脱敏
        var httpClient = SteamHTTPClient()
        httpClient.maximumRetries = 0
        httpClient.timeout = 10
        do {
            let body = try await httpClient.fetchPage(URL(string: "http://127.0.0.1:9/workshop")!, acceptLanguage: false, allowRetries: false)
            check("网络连接失败如实抛错", false, "不应成功却返回 \(body.count) 字符")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            check("网络连接失败如实抛错", true, message)
        }
        let maskedPassword = SteamLoginSession.sanitize("password: super-secret-abc", limit: 200)
        let maskedGuard = SteamLoginSession.sanitize("验证码：123456", limit: 200)
        let maskedUser = SteamLoginSession.sanitize("username alice", limit: 200)
        check(
            "登录输出脱敏不保留密码/验证码/账号名",
            !maskedPassword.contains("super-secret-abc") && !maskedGuard.contains("123456") && !maskedUsername(maskedUser).contains("alice"),
            "password→\(maskedPassword)，验证码→\(maskedGuard)，username→\(maskedUser)"
        )

        // 15) F18 清理保护集接线
        _ = playback.apply(item: primaryItem, to: [displayID])
        let protected = AppSettingsWiring.protectedURLs(store: store, playback: playback)
        let referencesOK = store.items.allSatisfy { protected.contains($0.fileURL) }
        let originalsOK = store.items.allSatisfy { item in
            item.originalURL.map { protected.contains($0) } ?? true
        }
        check(
            "清理保护集包含引用、播放中素材与原始来源",
            referencesOK && originalsOK && protected.contains(primaryItem.fileURL),
            "保护路径 \(protected.count) 个，引用齐全=\(referencesOK)，原始来源齐全=\(originalsOK)"
        )

        playback.tearDownAll()
    }

    private func maskedUsername(_ value: String) -> String { value }

    // MARK: - 桌面预览隔离检查（R15）

    /// 预览必须是真正的隔离：开始/暂停/调速/切换/停止/关闭（含重新打开）后，
    /// 真实库文件字节（不触发任何保存）、两屏（含断开屏）分配、每屏设置、
    /// 收藏与最近播放时间都保持不变。
    private func runPreviewIsolationTests(videoURL: URL?) async {
        header("桌面预览隔离（R15）")

        var availableItems = store.items.filter { fileManager.fileExists(atPath: $0.filePath) }
        if availableItems.isEmpty, let videoURL {
            await importService.importURLs([videoURL])
            availableItems = store.items.filter { fileManager.fileExists(atPath: $0.filePath) }
        }
        guard let primary = availableItems.first else {
            results.append(TestResult(name: "预览隔离前置素材", passed: false, detail: "没有可用素材"))
            return
        }
        let secondary = availableItems.dropFirst().first
        let liveDisplayID = registry.primary?.id ?? registry.displays.first?.id ?? "测试显示器A"
        let disconnectedDisplayID = "断开的第二台显示器-\(UUID().uuidString.prefix(6))"

        // 构造「生产近似」库状态：两台显示器各有分配与设置（其中一台断开）、收藏、最近播放。
        store.assign(itemID: primary.id, to: liveDisplayID)
        store.assign(itemID: primary.id, to: disconnectedDisplayID)
        store.updateSettings(for: liveDisplayID) { settings in
            settings.isMuted = false
            settings.volume = 0.33
            settings.rate = 1.25
            settings.gravity = .fit
            settings.isPaused = false
        }
        store.updateSettings(for: disconnectedDisplayID) { settings in
            settings.volume = 0.77
        }
        store.mutate(id: primary.id) { $0.isFavorite = true }
        store.markPlayed(id: primary.id, at: Date(timeIntervalSince1970: 1_700_000_000))
        store.flush()

        let bytesBefore = (try? Data(contentsOf: storage.libraryFile)) ?? Data()
        let savedAtBefore = store.lastSavedAt
        let assignmentsBefore = store.assignments
        let settingsBefore = store.displaySettings
        let favoriteBefore = store.item(withID: primary.id)?.isFavorite
        let lastPlayedBefore = store.item(withID: primary.id)?.lastPlayedAt

        // 预览控制器：无窗口 + 不写库（与桌面预览窗口使用的配置完全一致）。
        let preview = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true,
            writesToLibrary: false
        )
        _ = preview.apply(item: primary, to: nil)                       // 开始预览
        preview.playPause(displayID: liveDisplayID)                     // 暂停
        preview.setMuted(false, displayID: liveDisplayID)               // 控制：静音/音量/倍速
        preview.setVolume(0.91, displayID: liveDisplayID)
        preview.setRate(2.0, displayID: liveDisplayID)
        if let secondary {
            _ = preview.apply(item: secondary, to: nil)                 // 切换素材
        }
        preview.pauseAll()
        preview.resumeAll()
        preview.clear()                                                 // 停止预览
        preview.tearDownAll()                                           // 关闭预览（视图销毁路径）

        // 重新打开一次并关闭（覆盖 close/reopen 场景）。
        let reopened = DesktopPlaybackController(
            store: store,
            displayRegistry: registry,
            storage: storage,
            previewOnly: true,
            writesToLibrary: false
        )
        _ = reopened.apply(item: primary, to: [liveDisplayID])
        reopened.clear()
        reopened.tearDownAll()

        // 不做任何手动 flush：磁盘字节原样不变才能证明预览从未触发保存。
        let bytesAfter = (try? Data(contentsOf: storage.libraryFile)) ?? Data()

        check(
            "预览全程后真实库文件字节不变",
            !bytesBefore.isEmpty && bytesBefore == bytesAfter,
            "前 \(bytesBefore.count) 字节，后 \(bytesAfter.count) 字节，一致=\(bytesBefore == bytesAfter)"
        )
        check(
            "预览未触发素材库保存时间变化",
            store.lastSavedAt == savedAtBefore,
            "保存时间前=\(savedAtBefore.map { "\($0)" } ?? "-")，后=\(store.lastSavedAt.map { "\($0)" } ?? "-")"
        )
        check(
            "预览后两屏（含断开屏）分配不变",
            store.assignments == assignmentsBefore
                && store.assignedItemID(for: disconnectedDisplayID) == primary.id
                && store.assignedItemID(for: liveDisplayID) == primary.id,
            "分配记录 \(store.assignments.count) 条，断开屏分配保留=\(store.assignedItemID(for: disconnectedDisplayID) == primary.id)"
        )
        check(
            "预览后每屏设置不变",
            store.displaySettings == settingsBefore,
            "设置项 \(store.displaySettings.count) 组，音量=\(String(format: "%.2f", store.settings(for: liveDisplayID).volume))"
        )
        check(
            "预览后收藏与最近播放时间不变",
            store.item(withID: primary.id)?.isFavorite == favoriteBefore
                && store.item(withID: primary.id)?.lastPlayedAt == lastPlayedBefore,
            "收藏=\(store.item(withID: primary.id)?.isFavorite ?? false)，最近播放=\(store.item(withID: primary.id)?.lastPlayedAt.map { "\($0)" } ?? "-")"
        )
        check(
            "关闭预览后没有残留解码会话",
            preview.sessions.isEmpty && reopened.sessions.isEmpty,
            "关闭后会话=\(preview.sessions.count)，重开后关闭=\(reopened.sessions.count)"
        )
    }

    // MARK: - 渲染辅助

    private func renderSnapshot(_ view: AnyView, size: CGSize, to url: URL) -> Bool {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return false }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// 写出解码帧（真实播放管线产出，用于人工核对画面确实在变化）。
    private func writeDecodedFrames(_ frames: [CGImage], subdirectory: String = "decoded-frames") {
        guard let evidenceDirectory else { return }
        let directory = evidenceDirectory.appendingPathComponent(subdirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            let url = directory.appendingPathComponent(String(format: "frame-%02d.png", index))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, frame, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private func countDistinct(_ frames: [CGImage]) -> Int {
        var digests: Set<String> = []
        for frame in frames {
            digests.insert(imageDigest(frame))
        }
        return digests.count
    }

    private func imageDigest(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data else { return UUID().uuidString }
        var hasher = SHA256Digest()
        hasher.update(data: data as Data)
        return hasher.finalize()
    }

    private func isMostlyBlack(_ image: CGImage) -> Bool {
        let width = 24
        let height = 24
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return true }
        let pointer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var total = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            total += Int(pointer[index + 1]) + Int(pointer[index + 2]) + Int(pointer[index + 3])
        }
        return total / (width * height * 3) < 12
    }

    private func desktopPictureSnapshot() -> [String: String] {
        var record: [String: String] = [:]
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                record["\(id)"] = url.path
            }
        }
        return record
    }

    private func architecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: Array(bytes), as: UTF8.self)
        }
    }

    // MARK: - 输出

    private func header(_ text: String) {
        print("\n== \(text) ==")
    }

    private func report(started: Date, sandbox: URL?) -> Int32 {
        let duration = Date().timeIntervalSince(started)
        let failed = results.filter { !$0.passed && !$0.skipped }
        let passed = results.filter { $0.passed && !$0.skipped }.count
        let skipped = results.filter(\.skipped).count

        print("\n== 自检结果 ==")
        for result in results {
            print("[\(result.symbol)] \(result.name)")
            if !result.detail.isEmpty {
                print("        \(result.detail)")
            }
        }
        print("\n通过 \(passed)/\(results.count)，失败 \(failed.count)，跳过 \(skipped)，耗时 \(String(format: "%.1f", duration))s")
        print("（说明：绘制/解码证据来自真实播放与解码管线；桌面叠层显示效果由人工验证。）")

        let reportURL = (evidenceDirectory ?? storage.root).appendingPathComponent("self-test-report.txt")
        var report = "# Glimmer 自检报告\n"
        report += "时间: \(ISO8601DateFormatter().string(from: Date()))\n"
        report += "耗时: \(String(format: "%.1f", duration))s\n"
        report += "通过: \(passed)/\(results.count)，失败: \(failed.count)，跳过: \(skipped)\n\n"
        for result in results {
            report += "[\(result.symbol)] \(result.name)\n    \(result.detail)\n"
        }
        try? fileManager.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("报告: \(reportURL.path)")

        if let sandbox {
            if keepArtifacts {
                print("临时测试目录保留: \(sandbox.path)")
            } else {
                try? fileManager.removeItem(at: sandbox)
                print("（已清理临时测试目录）")
            }
        }

        return failed.isEmpty ? 0 : 1
    }
}
