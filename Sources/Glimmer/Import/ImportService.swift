import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

/// 一次导入任务的状态。
struct ImportJob: Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case pending
        case scanning
        case validating
        case copying
        case generatingThumbnail
        case done
        case duplicated(String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .done, .duplicated, .failed, .cancelled: return true
            default: return false
            }
        }

        var isSuccess: Bool {
            if case .done = self { return true }
            return false
        }

        var displayText: String {
            switch self {
            case .pending: return "等待导入"
            case .scanning: return "正在扫描文件夹"
            case .validating: return "正在验证可播放性"
            case .copying: return "正在复制到素材库"
            case .generatingThumbnail: return "正在生成缩略图"
            case .done: return "完成"
            case .duplicated(let reason): return "已跳过：\(reason)"
            case .failed(let reason): return "失败：\(reason)"
            case .cancelled: return "已取消"
            }
        }
    }

    var id = UUID()
    var displayName: String
    var sourceURL: URL?
    var state: State = .pending
    /// 导入成功后素材库中的条目 ID。
    var createdItemID: UUID?
    /// 附加说明（例如文件夹扫描到的候选数量）。
    var detail: String?

    init(displayName: String, sourceURL: URL?) {
        self.displayName = displayName
        self.sourceURL = sourceURL
    }
}

struct ImportPolicy: Sendable {
    /// 复制到应用管理目录（v1 默认 true，保证源文件不被后续操作影响）。
    var copyIntoLibrary: Bool
    /// 命中内容指纹时跳过。
    var skipDuplicates: Bool
    /// 拖入文件夹时递归扫描候选视频。
    var scanFolders: Bool

    static let `default` = ImportPolicy(copyIntoLibrary: true, skipDuplicates: true, scanFolders: true)
}

// MARK: - 创意工坊导入（B02 下载结果 → 素材库）

/// 工坊下载视频导入时携带的最小元数据。
///
/// 刻意使用与 Steam 模块解耦的普通结构：由 App 集成层把 `WorkshopMetadata`
/// 转换成本类型，Import 层不依赖 Steam 模块的类型。
struct ImportWorkshopMetadata: Sendable, Equatable {
    var publishedFileID: String
    var title: String
    var pageURLString: String?
    var previewImageURLString: String?
    var authorSteamID: String?
    var fileByteSize: Int64?
}

/// 视频或完整 Web 项目的导入结果。
enum ImportWorkshopOutcome: Sendable, Equatable {
    /// 新增素材（视频已实际探测；Web 已验证完整本地树与 HTML 入口）。
    case imported(UUID)
    /// 素材库中已有相同内容：复用原记录（必要时修复丢失的文件），并补齐工坊来源信息。
    case duplicated(UUID, existingTitle: String)
    /// 导入失败或被更新的请求取代（原因可直接展示给用户）。
    case failed(String)
}

/// 导入服务：文件选择/拖放 → 扫描 → AVFoundation 验证 → 复制 → 元数据与缩略图。
///
/// 安全与数据保护约定：
/// - 只读取用户显式选择的 URL 或应用管理目录中的工坊下载，不执行任何 shell 命令。
/// - 原始文件只读，不移动、不删除、不覆盖。
/// - 复制失败或取消时清理半成品，避免管理目录残留。
///
/// 并发约定（R02/R13）：
/// - 本地与创意工坊导入共用同一个串行闸门：同一时刻最多只有一个导入在修改素材库与任务列表；
///   排队请求按到达顺序执行，取消会同时覆盖等待中的请求。
/// - 新的本地导入会取代旧的本地导入（运行中的被取消、排队中的直接跳过），符合用户
///   「重新选择文件」的预期；工坊导入只排队，不取消其他操作。
/// - 所有任务状态都通过稳定 ID 更新，绝不跨 `await` 持有数组下标，因此列表裁剪/重排后仍然安全。
/// - 去重命中但旧的管理副本已丢失时不会报告「重复成功」：改用新的有效文件修复原记录
///   （保留 UUID、收藏、显示器分配与播放设置）。
@MainActor
@Observable
final class ImportService {
    /// 保留的最近任务条数上限（避免长时间运行后列表无限增长）。
    private static let jobHistoryLimit = 60

    private(set) var jobs: [ImportJob] = []
    /// 最近一次导入的汇总（用于界面横幅）。
    private(set) var lastSummary: String?

    private let store: VideoLibraryStore
    private let storage: AppStorage
    private let thumbnailCache: ThumbnailCache
    private let probeOperation: @Sendable (URL) async throws -> VideoProbeResult

    // MARK: 串行闸门状态

    private enum OperationKind {
        case local
        case workshop
    }

    private struct GateWaiter {
        let kind: OperationKind
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isGateBusy = false
    private var runningKind: OperationKind?
    private var runningTask: Task<Void, Never>?
    private var gateWaiters: [GateWaiter] = []
    /// 取消纪元：cancelAll 后，已排队但尚未开始的请求不再执行。
    private var cancellationEpoch = 0

    init(store: VideoLibraryStore, storage: AppStorage = AppStorage(), thumbnailCache: ThumbnailCache? = nil,
         probeOperation: (@Sendable (URL) async throws -> VideoProbeResult)? = nil) {
        self.store = store
        self.storage = storage
        self.thumbnailCache = thumbnailCache ?? ThumbnailCache.shared
        self.probeOperation = probeOperation ?? { try await VideoProbe.probe(url: $0) }
    }

    var activeJobs: [ImportJob] { jobs.filter { !$0.state.isTerminal } }
    /// 是否有导入正在进行（由任务状态推导，避免多任务交叉修改标志位）。
    var isImporting: Bool { !activeJobs.isEmpty }

    /// 取消当前导入：取消运行中的任务，并让所有排队请求直接结束。
    func cancelAll() {
        cancellationEpoch += 1
        runningTask?.cancel()
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
        for index in jobs.indices where !jobs[index].state.isTerminal {
            jobs[index].state = .cancelled
        }
    }

    // MARK: - 入口

    /// 用户显式选择的文件与文件夹入口。
    ///
    /// 串行化策略：与工坊导入共用同一闸门；新的本地导入会取代仍在运行/排队的旧本地导入。
    func importURLs(_ urls: [URL], policy: ImportPolicy = .default) async {
        await runImport(kind: .local) {
            await self.performLocalImport(urls: urls, policy: policy)
        }
    }

    /// 导入一个已完成下载与校验的工坊视频。
    ///
    /// 与本地导入的差异与约定（F16）：
    /// - 文件位于应用管理的工坊下载目录，**不复制**，直接引用（避免多份数 GB 副本）；
    /// - 只有真实探测通过并成功入库后才写入 `source = .steamWorkshop` 与作品 ID；
    /// - 命中有效重复时复用既有记录并补齐工坊来源信息（不重命名用户已改过的标题）；
    /// - 命中记录但旧文件已丢失时，用本次下载的文件修复原记录；
    /// - 任何失败都以具体原因返回，绝不静默当作成功。
    func importWorkshopVideo(_ source: URL, metadata: ImportWorkshopMetadata, copyIntoLibrary: Bool = false) async -> ImportWorkshopOutcome {
        var outcome = ImportWorkshopOutcome.failed("导入未执行：已有更新的导入请求")
        let ran = await runImport(kind: .workshop) {
            outcome = copyIntoLibrary ? await self.performCopiedWorkshopVideo(source, metadata: metadata)
                : await self.performWorkshopImport(source, metadata: metadata)
        }
        return ran ? outcome : ImportWorkshopOutcome.failed("导入未执行：已有更新的导入请求")
    }

    func importWorkshopWeb(_ sourceProjectURL: URL, metadata: ImportWorkshopMetadata,
                           managedDownloadRoot: URL? = nil) async -> ImportWorkshopOutcome {
        let origin = WebWallpaperImportOrigin(workshopID: metadata.publishedFileID, title: metadata.title,
            pageURLString: metadata.pageURLString, authorSteamID: metadata.authorSteamID,
            managedDownloadRoot: managedDownloadRoot)
        return await importWeb(sourceProjectURL, origin: origin, kind: .workshop)
    }

    func importLocalWebProject(_ selectedURL: URL) async -> ImportWorkshopOutcome {
        await importWeb(selectedURL, origin: nil, kind: .local)
    }

    private func importWeb(_ selectedURL: URL, origin: WebWallpaperImportOrigin?, kind: OperationKind) async -> ImportWorkshopOutcome {
        var outcome = ImportWorkshopOutcome.failed("导入未执行：请求已取消或被取代")
        let ran = await runImport(kind: kind) {
            let jobID = self.appendJob(ImportJob(displayName: origin?.title ?? selectedURL.lastPathComponent, sourceURL: selectedURL))
            do {
                try Task.checkCancellation()
                self.setJobState(jobID, .copying)
                let ids = Set(self.store.items.map(\.id))
                let item = try await WebWallpaperProjectImporter.importProject(selectedURL, store: self.store, origin: origin)
                self.setJobCreatedItem(jobID, item.id)
                if ids.contains(item.id) {
                    self.setJobState(jobID, .duplicated("素材库中已有相同 Web 项目"))
                    outcome = .duplicated(item.id, existingTitle: item.displayTitle)
                } else {
                    self.setJobState(jobID, .done)
                    outcome = .imported(item.id)
                }
            } catch is CancellationError {
                self.setJobState(jobID, .cancelled)
                outcome = .failed("导入已取消")
            } catch {
                self.setJobState(jobID, .failed(error.localizedDescription))
                outcome = .failed(error.localizedDescription)
            }
        }
        return ran ? outcome : .failed("导入未执行：请求已取消或被取代")
    }

    func importWorkshopScene(_ sourceProjectURL: URL, metadata: ImportWorkshopMetadata,
                           managedDownloadRoot: URL? = nil) async -> ImportWorkshopOutcome {
        let origin = SceneWallpaperImportOrigin(workshopID: metadata.publishedFileID, title: metadata.title,
            pageURLString: metadata.pageURLString, authorSteamID: metadata.authorSteamID,
            managedDownloadRoot: managedDownloadRoot)
        return await importScene(sourceProjectURL, origin: origin, kind: .workshop)
    }

    func importLocalSceneProject(_ selectedURL: URL) async -> ImportWorkshopOutcome {
        await importScene(selectedURL, origin: nil, kind: .local)
    }

    private func importScene(_ selectedURL: URL, origin: SceneWallpaperImportOrigin?, kind: OperationKind) async -> ImportWorkshopOutcome {
        var outcome = ImportWorkshopOutcome.failed("导入未执行：请求已取消或被取代")
        let ran = await runImport(kind: kind) {
            let jobID = self.appendJob(ImportJob(displayName: origin?.title ?? selectedURL.lastPathComponent, sourceURL: selectedURL))
            do {
                try Task.checkCancellation()
                self.setJobState(jobID, .copying)
                let ids = Set(self.store.items.map(\.id))
                let item = try await SceneWallpaperProjectImporter.importProject(selectedURL, store: self.store, origin: origin)
                self.setJobCreatedItem(jobID, item.id)
                if ids.contains(item.id) {
                    self.setJobState(jobID, .duplicated("素材库中已有相同 Scene 项目"))
                    outcome = .duplicated(item.id, existingTitle: item.displayTitle)
                } else {
                    self.setJobState(jobID, .done)
                    outcome = .imported(item.id)
                }
            } catch is CancellationError {
                self.setJobState(jobID, .cancelled)
                outcome = .failed("导入已取消")
            } catch {
                self.setJobState(jobID, .failed(error.localizedDescription))
                outcome = .failed(error.localizedDescription)
            }
        }
        return ran ? outcome : .failed("导入未执行：请求已取消或被取代")
    }

    // MARK: - 串行闸门

    /// 获取导入闸门。返回 false 表示请求已被取代或取消，调用方不应执行主体。
    private func acquireGate(kind: OperationKind) async -> Bool {
        if kind == .local {
            // 新的本地导入取代旧的本地导入：运行中的取消，排队中的直接跳过。
            if isGateBusy, runningKind == .local {
                runningTask?.cancel()
            }
            if !gateWaiters.isEmpty {
                var kept: [GateWaiter] = []
                for waiter in gateWaiters {
                    if waiter.kind == .local {
                        waiter.continuation.resume(returning: false)
                    } else {
                        kept.append(waiter)
                    }
                }
                gateWaiters = kept
            }
        }

        if Task.isCancelled { return false }
        let epoch = cancellationEpoch
        if !isGateBusy {
            isGateBusy = true
            runningKind = kind
            return true
        }

        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gateWaiters.append(GateWaiter(kind: kind, continuation: continuation))
        }
        guard granted else { return false }
        if cancellationEpoch != epoch || Task.isCancelled {
            releaseGate()
            return false
        }
        return true
    }

    private func releaseGate() {
        runningTask = nil
        if gateWaiters.isEmpty {
            isGateBusy = false
            runningKind = nil
            return
        }
        let next = gateWaiters.removeFirst()
        runningKind = next.kind
        next.continuation.resume(returning: true)
    }

    /// 串行执行一次导入主体。返回 false 表示被取代/取消，主体未执行。
    @discardableResult
    private func runImport(kind: OperationKind, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        guard await acquireGate(kind: kind) else { return false }
        let task = Task { @MainActor in
            await body()
        }
        runningTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        releaseGate()
        return true
    }

    // MARK: - 本地导入流程

    private func performLocalImport(urls: [URL], policy: ImportPolicy) async {
        trimHistory()
        // Each local batch publishes a fresh completion value so page-level transient
        // feedback is emitted even when two consecutive batches have identical counts.
        lastSummary = nil

        var imported = 0
        var duplicated = 0
        var failed = 0
        var cancelled = 0

        // 1) 展开文件夹，收集待处理文件
        var candidates: [URL] = []
        for url in urls {
            if Task.isCancelled {
                cancelled += 1
                break
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists else {
                let jobID = appendJob(ImportJob(displayName: url.lastPathComponent, sourceURL: url))
                setJobState(jobID, .failed("文件不存在"))
                failed += 1
                continue
            }

            if isDirectory.boolValue {
                guard policy.scanFolders else {
                    let jobID = appendJob(ImportJob(displayName: url.lastPathComponent, sourceURL: url))
                    setJobState(jobID, .failed("当前设置不扫描文件夹"))
                    failed += 1
                    continue
                }
                let jobID = appendJob(ImportJob(displayName: url.lastPathComponent, sourceURL: url))
                setJobState(jobID, .scanning)
                let found = await Task.detached(priority: .userInitiated) {
                    VideoFileSupport.scanFolder(url)
                }.value
                if Task.isCancelled {
                    setJobState(jobID, .cancelled)
                    cancelled += 1
                    break
                }
                if found.isEmpty {
                    setJobState(jobID, .failed("文件夹中没有找到候选视频文件"))
                    failed += 1
                } else {
                    // 文件夹任务在展开完成时即进入终态，子文件各自有独立任务。
                    setJobState(jobID, .done)
                    setJobDetail(jobID, "已找到 \(found.count) 个候选视频")
                    candidates.append(contentsOf: found)
                }
            } else if VideoFileSupport.isCandidateVideo(url: url) {
                candidates.append(url)
            } else {
                let jobID = appendJob(ImportJob(displayName: url.lastPathComponent, sourceURL: url))
                setJobState(jobID, .failed(AppFileError.unsupportedType(url.lastPathComponent).errorDescription ?? "不支持的文件类型"))
                failed += 1
            }
        }

        // 2) 逐个验证与导入
        for candidate in candidates {
            if Task.isCancelled {
                cancelled += 1
                break
            }
            let jobID = appendJob(ImportJob(displayName: candidate.lastPathComponent, sourceURL: candidate))
            do {
                _ = try await importSingle(candidate, policy: policy, jobID: jobID)
                imported += 1
            } catch is CancellationError {
                setJobState(jobID, .cancelled)
                cancelled += 1
            } catch let error as AppFileError {
                switch error {
                case .cancelled:
                    setJobState(jobID, .cancelled)
                    cancelled += 1
                case .duplicate(let title):
                    setJobState(jobID, .duplicated("素材库中已有相同文件 \(title)"))
                    duplicated += 1
                default:
                    setJobState(jobID, .failed(error.errorDescription ?? "未知错误"))
                    failed += 1
                }
            } catch {
                setJobState(jobID, .failed(error.localizedDescription))
                failed += 1
            }
        }

        // 兜底：确保没有任务停留在非终态
        for index in jobs.indices where !jobs[index].state.isTerminal {
            jobs[index].state = .cancelled
        }

        lastSummary = "导入完成：新增 \(imported) 个，跳过重复 \(duplicated) 个，失败 \(failed) 个" + (cancelled > 0 ? "，取消 \(cancelled) 个" : "")
    }

    private func importSingle(_ source: URL, policy: ImportPolicy, jobID: UUID) async throws {
        // 规范化符号链接，避免同一文件多路径
        let standardized = source.resolvingSymlinksInPath().standardizedFileURL

        // 2a) 内容指纹（轻量、可取消点）
        setJobState(jobID, .validating)
        let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date

        let fingerprint = await Task.detached(priority: .userInitiated) {
            try? VideoFileSupport.contentFingerprint(of: standardized)
        }.value

        // 去重：命中且旧文件仍可用 → 跳过；命中但旧管理副本已丢失 → 继续导入并在入库后修复原记录。
        var repairTarget: WallpaperItem?
        if policy.skipDuplicates {
            if let existing = await matchingImportCandidate(source: standardized, fingerprint: fingerprint, size: size, modified: modified) {
                if existing.fileExists {
                    throw AppFileError.duplicate(existingTitle: existing.displayTitle)
                }
                repairTarget = existing
            }
        }

        if Task.isCancelled { throw AppFileError.cancelled }

        // 2b) 真实可播放性验证（元数据也在此处取得）
        let probe = try await probeOperation(standardized)
        if Task.isCancelled { throw AppFileError.cancelled }

        // 2c) 复制到应用管理目录（或按策略引用原路径）
        let mediaURL: URL
        if policy.copyIntoLibrary {
            setJobState(jobID, .copying)
            try storage.prepareDirectories()
            let destination = storage.uniqueMediaURL(for: standardized.lastPathComponent)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: standardized, to: destination)
                }.value
            } catch {
                throw AppFileError.copyFailed(standardized.lastPathComponent, underlying: error.localizedDescription)
            }
            mediaURL = destination
        } else {
            mediaURL = standardized
        }

        if Task.isCancelled {
            if policy.copyIntoLibrary { try? FileManager.default.removeItem(at: mediaURL) }
            throw AppFileError.cancelled
        }

        // 2d) 入库：修复丢失的原记录，或新增素材。
        let createdItemID: UUID
        if let repairTarget {
            store.relink(id: repairTarget.id, to: mediaURL, probe: probe)
            createdItemID = repairTarget.id
            setJobDetail(jobID, "已用新导入的文件修复此前丢失的素材记录")
        } else {
            let item = WallpaperItem(
                title: Self.defaultTitle(for: standardized),
                filePath: mediaURL.path,
                originalPath: policy.copyIntoLibrary ? standardized.path : nil,
                source: .local,
                isFavorite: false,
                addedAt: Date(),
                fileSizeBytes: size,
                contentFingerprint: fingerprint,
                durationSeconds: probe.durationSeconds,
                pixelWidth: probe.pixelWidth,
                pixelHeight: probe.pixelHeight,
                frameRate: probe.frameRate,
                videoCodec: probe.videoCodec,
                audioCodec: probe.audioCodec,
                hasAudioTrack: probe.hasAudioTrack,
                sourceModifiedAt: modified
            )
            store.add(item)
            createdItemID = item.id
        }
        setJobCreatedItem(jobID, createdItemID)

        // 2e) 缩略图（失败不阻塞导入）
        setJobState(jobID, .generatingThumbnail)
        if let storedItem = store.item(withID: createdItemID) {
            _ = await thumbnailCache.thumbnail(for: storedItem)
        }

        setJobState(jobID, .done)
    }

    // MARK: - 创意工坊导入流程

    private func performWorkshopImport(_ source: URL, metadata: ImportWorkshopMetadata) async -> ImportWorkshopOutcome {
        let standardized = source.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return .failed("下载文件不存在：\(PathRedaction.short(standardized))")
        }

        let trimmedTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedTitle.isEmpty ? Self.defaultTitle(for: standardized) : trimmedTitle
        let jobID = appendJob(ImportJob(displayName: displayName, sourceURL: standardized))

        do {
            guard !Task.isCancelled else { throw AppFileError.cancelled }
            setJobState(jobID, .validating)

            let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? metadata.fileByteSize ?? 0
            let modified = attributes?[.modificationDate] as? Date

            let fingerprint = await Task.detached(priority: .userInitiated) {
                try? VideoFileSupport.contentFingerprint(of: standardized)
            }.value

            // 去重：命中且旧文件仍可用 → 补齐工坊来源信息并复用；
            // 命中但旧文件已丢失 → 用本次下载文件修复原记录（保留 UUID/收藏/设置）。
            var repairTarget: WallpaperItem?
            if let existing = await matchingImportCandidate(source: standardized, fingerprint: fingerprint, size: size, modified: modified, workshopID: metadata.publishedFileID) {
                guard !Task.isCancelled else { throw AppFileError.cancelled }
                if existing.fileExists {
                    stampWorkshopMetadata(on: existing.id, metadata: metadata)
                    setJobState(jobID, .duplicated("素材库中已有相同文件 \(existing.displayTitle)"))
                    return .duplicated(existing.id, existingTitle: existing.displayTitle)
                }
                repairTarget = existing
            }

            guard !Task.isCancelled else { throw AppFileError.cancelled }

            // 真实可播放性验证（与本地导入相同路径）。
            let probe = try await probeOperation(standardized)
            guard !Task.isCancelled else { throw AppFileError.cancelled }

            if let repairTarget {
                store.relink(id: repairTarget.id, to: standardized, probe: probe)
                stampWorkshopMetadata(on: repairTarget.id, metadata: metadata)
                setJobCreatedItem(jobID, repairTarget.id)
                setJobDetail(jobID, "已用本次下载的文件修复此前丢失的素材记录")
                setJobState(jobID, .generatingThumbnail)
                if let storedItem = store.item(withID: repairTarget.id) {
                    _ = await thumbnailCache.thumbnail(for: storedItem)
                }
                setJobState(jobID, .done)
                lastSummary = "已修复并更新创意工坊视频：\(repairTarget.displayTitle)"
                return .duplicated(repairTarget.id, existingTitle: repairTarget.displayTitle)
            }

            let item = WallpaperItem(
                title: displayName,
                filePath: standardized.path,
                originalPath: nil,
                source: .steamWorkshop,
                isFavorite: false,
                addedAt: Date(),
                fileSizeBytes: size,
                contentFingerprint: fingerprint,
                durationSeconds: probe.durationSeconds,
                pixelWidth: probe.pixelWidth,
                pixelHeight: probe.pixelHeight,
                frameRate: probe.frameRate,
                videoCodec: probe.videoCodec,
                audioCodec: probe.audioCodec,
                hasAudioTrack: probe.hasAudioTrack,
                sourceModifiedAt: modified,
                workshopID: metadata.publishedFileID,
                notes: Self.workshopNote(metadata)
            )
            store.add(item)
            setJobCreatedItem(jobID, item.id)
            setJobDetail(jobID, "来自 Steam 创意工坊 \(metadata.publishedFileID)")

            // 缩略图（失败不阻塞导入）。
            setJobState(jobID, .generatingThumbnail)
            _ = await thumbnailCache.thumbnail(for: item)

            setJobState(jobID, .done)
            lastSummary = "已导入创意工坊视频：\(item.displayTitle)"
            return .imported(item.id)
        } catch let error as AppFileError {
            let message = error.errorDescription ?? "导入失败"
            if case .cancelled = error {
                setJobState(jobID, .cancelled)
            } else {
                setJobState(jobID, .failed(message))
            }
            return .failed(message)
        } catch {
            setJobState(jobID, .failed(error.localizedDescription))
            return .failed(error.localizedDescription)
        }
    }

    /// External Steam libraries remain read-only. Copy and probe before atomic origin stamping.
    private func performCopiedWorkshopVideo(_ source: URL, metadata: ImportWorkshopMetadata) async -> ImportWorkshopOutcome {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let jobID = appendJob(ImportJob(displayName: metadata.title, sourceURL: source))
        var ownedCopy: URL?
        var committed = false
        defer { if !committed, let ownedCopy { try? FileManager.default.removeItem(at: ownedCopy) } }
        do {
            try Task.checkCancellation()
            var sourceInfo = stat()
            guard source.isFileURL, lstat(source.path, &sourceInfo) == 0,
                  sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw AppFileError.storageUnavailable("源视频必须是实际的常规文件") }
            try storage.prepareDirectories()
            let canonicalMedia = try WebProjectPaths.canonical(storage.mediaDirectory)
            guard canonicalMedia.path == (try WebProjectPaths.canonical(storage.root)).path + "/Media" else { throw AppFileError.storageUnavailable("媒体目录不能是符号链接") }
            let destination = canonicalMedia.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
            ownedCopy = destination
            setJobState(jobID, .copying)
            let work = Task.detached(priority: .userInitiated) { try Self.copyExternalVideo(source, destination: destination) }
            let copied = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            let candidates = store.items.filter {  $0.isVideoWallpaper && $0.workshopID == metadata.publishedFileID &&
                ($0.contentFingerprint == copied.fingerprint || copied.legacyFingerprint != nil && $0.contentFingerprint == copied.legacyFingerprint) && $0.fileSizeBytes == copied.bytes }
            var repair: WallpaperItem?
            for candidate in candidates {
                if !candidate.fileExists { repair = repair ?? candidate; continue }
                let comparison = Task.detached(priority: .userInitiated) { (try? Self.identicalRegularFiles(candidate.fileURL, destination)) == true }
                let identical = await withTaskCancellationHandler { await comparison.value } onCancel: { comparison.cancel() }
                try Task.checkCancellation()
                if identical {
                    let managed = (try? WebProjectPaths.canonical(candidate.fileURL))?.path.hasPrefix(canonicalMedia.path + "/") == true
                    if !managed { repair = candidate; break }
                    setJobState(jobID, .duplicated("素材库中已有相同视频"))
                    return .duplicated(candidate.id, existingTitle: candidate.displayTitle)
                }
            }
            setJobState(jobID, .validating)
            let probe = try await probeOperation(destination)
            try Task.checkCancellation()
            var item = repair ?? WallpaperItem(title: metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultTitle(for: source) : metadata.title, filePath: destination.path)
            item.filePath = destination.path
            item.originalPath = source.path
            item.source = .steamWorkshop
            item.workshopID = metadata.publishedFileID
            item.contentKind = .video
            item.contentFingerprint = copied.fingerprint
            item.fileSizeBytes = copied.bytes
            item.durationSeconds = probe.durationSeconds
            item.pixelWidth = probe.pixelWidth; item.pixelHeight = probe.pixelHeight
            item.frameRate = probe.frameRate; item.videoCodec = probe.videoCodec; item.audioCodec = probe.audioCodec
            item.hasAudioTrack = probe.hasAudioTrack
            if item.notes == nil { item.notes = Self.workshopNote(metadata) }
            if repair != nil { try store.replacePersistedItem(item) } else { try store.addPersistedItem(item) }
            committed = true
            setJobCreatedItem(jobID, item.id); setJobState(jobID, .done)
            return repair != nil ? .duplicated(item.id, existingTitle: item.displayTitle) : .imported(item.id)
        } catch is CancellationError {
            setJobState(jobID, .cancelled); return .failed("导入已取消")
        } catch {
            setJobState(jobID, .failed(error.localizedDescription)); return .failed(error.localizedDescription)
        }
    }

    nonisolated private static func copyExternalVideo(_ source: URL, destination: URL?) throws -> (bytes: Int64, fingerprint: String, legacyFingerprint: String?) {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AppFileError.storageUnavailable("无法读取源视频") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw AppFileError.storageUnavailable("源视频不是常规文件") }
        let output: FileHandle?
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppFileError.storageUnavailable("无法创建视频副本") }
            output = try FileHandle(forWritingTo: destination)
        } else { output = nil }
        defer { try? output?.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); bytes += Int64(chunk.count); digest.update(data: chunk); try output?.write(contentsOf: chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, bytes == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw AppFileError.storageUnavailable("复制期间源视频已改变") }
        return (bytes, "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined(), destination.flatMap { try? VideoFileSupport.contentFingerprint(of: $0) })
    }

    nonisolated private static func identicalRegularFiles(_ lhs: URL, _ rhs: URL) throws -> Bool {
        func input(_ url: URL) throws -> (FileHandle, stat) {
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw AppFileError.storageUnavailable("重复候选不可读取") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { close(fd); throw AppFileError.storageUnavailable("重复候选不是常规文件") }
            return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info)
        }
        let (left, leftBefore) = try input(lhs); defer { try? left.close() }
        let (right, rightBefore) = try input(rhs); defer { try? right.close() }
        guard leftBefore.st_size == rightBefore.st_size else { return false }
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let a = try left.read(upToCount: 1_048_576) ?? Data()
            let b = try right.read(upToCount: 1_048_576) ?? Data()
            guard a == b else { return false }
            count += Int64(a.count)
            if a.isEmpty { break }
        }
        var leftAfter = stat(), rightAfter = stat()
        guard fstat(left.fileDescriptor, &leftAfter) == 0, fstat(right.fileDescriptor, &rightAfter) == 0 else { return false }
        return count == leftBefore.st_size && leftAfter.st_size == leftBefore.st_size && rightAfter.st_size == rightBefore.st_size &&
            leftAfter.st_mtimespec.tv_sec == leftBefore.st_mtimespec.tv_sec && leftAfter.st_mtimespec.tv_nsec == leftBefore.st_mtimespec.tv_nsec &&
            rightAfter.st_mtimespec.tv_sec == rightBefore.st_mtimespec.tv_sec && rightAfter.st_mtimespec.tv_nsec == rightBefore.st_mtimespec.tv_nsec
    }

    /// 轻量指纹只筛选候选；已有副本必须逐字节相同才算重复。
    /// 缺失副本无法重验历史内容，保留既有轻量身份的修复行为。
    private func matchingImportCandidate(source: URL, fingerprint: String?, size: Int64, modified: Date?, workshopID: String? = nil) async -> WallpaperItem? {
        let candidates: [WallpaperItem]
        if let fingerprint {
            candidates = store.items.filter {  $0.isVideoWallpaper && $0.fileSizeBytes == size &&
                ($0.contentFingerprint == fingerprint || $0.contentFingerprint?.hasPrefix("sha256:") == true && (workshopID == nil || $0.workshopID == workshopID)) }
        } else if let existing = store.item(matchingStandardPath: source.path),
                  existing.fileSizeBytes == size,
                  let modified,
                  existing.sourceModifiedAt == modified {
            // 无指纹时只接受路径、大小、已知源修改时间都一致的回退候选。
            candidates = [existing]
        } else {
            return nil
        }

        for candidate in candidates where candidate.fileExists {
            guard !Task.isCancelled else { return nil }
            let existingURL = candidate.fileURL
            let comparison = Task.detached(priority: .userInitiated) {
                (try? Self.identicalRegularFiles(source, existingURL)) == true
            }
            let identical = await withTaskCancellationHandler {
                await comparison.value
            } onCancel: {
                comparison.cancel()
            }
            guard !Task.isCancelled else { return nil }
            if identical { return candidate }
        }
        // 优先寻找可用且完整相同的副本，再考虑修复旧的缺失记录。
        if let legacy = candidates.first(where: { !$0.fileExists && $0.contentFingerprint == fingerprint }) { return legacy }
        let missingFull = candidates.filter { !$0.fileExists && $0.contentFingerprint?.hasPrefix("sha256:") == true }
        if !missingFull.isEmpty {
            let hashing = Task.detached(priority: .userInitiated) { try? Self.copyExternalVideo(source, destination: nil).fingerprint }
            let full = await withTaskCancellationHandler { await hashing.value } onCancel: { hashing.cancel() }
            guard !Task.isCancelled else { return nil }
            return missingFull.first { $0.contentFingerprint == full }
        }
        return nil
    }

    /// 命中重复后补齐工坊来源信息（不修改用户可能已改过的标题）。
    private func stampWorkshopMetadata(on itemID: UUID, metadata: ImportWorkshopMetadata) {
        store.mutate(id: itemID) { item in
            item.source = .steamWorkshop
            item.workshopID = metadata.publishedFileID
            if let note = Self.workshopNote(metadata) {
                let existing = item.notes ?? ""
                if !existing.contains(metadata.publishedFileID) {
                    item.notes = existing.isEmpty ? note : existing + " · " + note
                }
            }
        }
    }

    private static func workshopNote(_ metadata: ImportWorkshopMetadata) -> String? {
        var parts: [String] = ["Steam 创意工坊作品 \(metadata.publishedFileID)"]
        if let page = metadata.pageURLString, !page.isEmpty {
            parts.append(page)
        }
        if let author = metadata.authorSteamID, !author.isEmpty {
            parts.append("作者 ID \(author)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 任务记录（稳定 ID，绝不跨 await 持有下标）

    private func appendJob(_ job: ImportJob) -> UUID {
        jobs.append(job)
        return job.id
    }

    private func setJobState(_ jobID: UUID, _ state: ImportJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = state
    }

    private func setJobDetail(_ jobID: UUID, _ detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].detail = detail
    }

    private func setJobCreatedItem(_ jobID: UUID, _ itemID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].createdItemID = itemID
    }

    /// 只保留最近的任务记录，且不丢弃仍在进行中的任务。
    private func trimHistory() {
        guard jobs.count > Self.jobHistoryLimit else { return }
        let active = jobs.filter { !$0.state.isTerminal }
        let finished = jobs.filter { $0.state.isTerminal }.suffix(Self.jobHistoryLimit - active.count)
        jobs = Array(finished) + active
    }

    static func defaultTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.lastPathComponent : trimmed
    }
}
