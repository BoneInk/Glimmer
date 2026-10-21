import Darwin
import Foundation

/// 子进程执行封装（SteamCMD 专用）。
///
/// 安全约束：
/// - 不使用 `/bin/sh -c`，不做任何字符串拼接；一律以「可执行文件 + 参数数组」直接启动进程。
/// - 环境变量由 `steamcmdEnvironment(home:)` 显式构造，**完全替换**环境，避免把用户真实
///   Steam 配置或无关变量带进子进程。
/// - 账号密码/令牌通过 stdin 写入，绝不进入 argv；输出不写入任何持久化日志。
///
/// 完成语义（R07 修复）：
/// - `terminationHandler` 在 `run()` **之前**安装，避免进程瞬间退出时漏掉回调；
/// - 完成（退出 / 超时 / 取消 / 管道 EOF）由同一个「恰好一次」闸门裁决，绝不重复 resume；
/// - 额外有一个轻量轮询作为兜底（防止 Foundation 回调丢失）；
/// - 管道由后台 readabilityHandler 消费，不阻塞主线程；保留输出有明确上限（队首 + 队尾截断）。
enum WorkshopProcessError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, outputTail: String)
    case timedOut(afterSeconds: Int)
    case cancelled
    case streamClosed

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "无法启动 SteamCMD：\(detail)"
        case .nonZeroExit(let code, let tail):
            if tail.isEmpty {
                return "SteamCMD 退出码 \(code)"
            }
            return "SteamCMD 退出码 \(code)：\(tail)"
        case .timedOut(let seconds): return "SteamCMD 在 \(seconds) 秒内没有完成，已终止该进程"
        case .cancelled: return "操作已取消"
        case .streamClosed: return "进程输出流已关闭"
        }
    }
}

/// 一次子进程运行的结果。
struct WorkshopProcessResult: Sendable {
    var exitCode: Int32
    var output: String
    var durationSeconds: Double
    var wasTimedOut: Bool
    /// 输出是否因长度上限被截断（诊断用）。
    var outputWasTruncated: Bool

    /// 输出末尾若干字符（脱敏后用于错误展示）。
    func tail(limit: Int) -> String {
        let collapsed = output
            .split(separator: "\n")
            .map { SteamHTML.collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " | ")
        let sanitized = WorkshopLog.sanitize(collapsed)
        guard sanitized.count > limit else { return sanitized }
        return "…" + sanitized.suffix(limit)
    }
}

/// 线程安全的可变盒子（用于跨回调收集状态）。
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// 有界输出缓冲：保留开头与结尾，中间截断（避免大输出撑爆内存）。
struct BoundedOutputBuffer: Sendable {
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tailChunks: [Data] = []
    private var tailBytes = 0
    private(set) var totalBytes = 0

    init(headLimit: Int = 128 * 1024, tailLimit: Int = 128 * 1024) {
        self.headLimit = headLimit
        self.tailLimit = tailLimit
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count
        if head.count < headLimit {
            head.append(data.prefix(headLimit - head.count))
        }
        if data.count >= tailLimit {
            tailChunks = [Data(data.suffix(tailLimit))]
            tailBytes = tailLimit
        } else {
            tailChunks.append(data)
            tailBytes += data.count
            while tailBytes > tailLimit, let first = tailChunks.first {
                let overflow = tailBytes - tailLimit
                if first.count <= overflow {
                    tailChunks.removeFirst()
                    tailBytes -= first.count
                } else {
                    tailChunks[0] = Data(first.dropFirst(overflow))
                    tailBytes -= overflow
                }
            }
        }
    }

    var isTruncated: Bool {
        totalBytes > head.count + tailBytes
    }

    func text() -> String {
        var combined = head
        if isTruncated {
            combined.append(Data("\n…（中间 \(totalBytes - head.count - tailBytes) 字节已省略）…\n".utf8))
        }
        for chunk in tailChunks { combined.append(chunk) }
        return String(decoding: combined, as: UTF8.self)
    }
}

/// 「恰好一次」完成闸门：退出 / 超时 / 取消 / EOF 共用同一裁决点。
final class ProcessCompletionGate: @unchecked Sendable {
    struct Outcome: Sendable {
        var exitCode: Int32
        var timedOut: Bool
    }

    private let lock = NSLock()
    private var processExited = false
    private var exitCode: Int32 = 0
    private var eofCount = 0
    private var expectedPipes = 2
    private var graceExpired = false
    private var timedOut = false
    private var finished = false
    private var callback: ((Outcome) -> Void)?

    func setExpectedPipes(_ count: Int) {
        lock.lock()
        expectedPipes = count
        if eofCount >= expectedPipes { graceExpired = true }
        lock.unlock()
    }

    func markExited(code: Int32) {
        lock.lock()
        if !processExited {
            processExited = true
            exitCode = code
        }
        lock.unlock()
        evaluate()
    }

    func markEOF() {
        lock.lock()
        eofCount += 1
        lock.unlock()
        evaluate()
    }

    func markGraceExpired() {
        lock.lock()
        graceExpired = true
        lock.unlock()
        evaluate()
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    /// 注册恰好一次的回调；若已完成则立即触发。
    func onComplete(_ body: @escaping (Outcome) -> Void) {
        lock.lock()
        if finished {
            let outcome = Outcome(exitCode: exitCode, timedOut: timedOut)
            lock.unlock()
            body(outcome)
            return
        }
        callback = body
        lock.unlock()
        evaluate()
    }

    private func evaluate() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let ready = processExited && (eofCount >= expectedPipes || graceExpired)
        guard ready else {
            lock.unlock()
            return
        }
        finished = true
        let outcome = Outcome(exitCode: exitCode, timedOut: timedOut)
        let body = callback
        callback = nil
        lock.unlock()
        body?(outcome)
    }
}

/// 可控进程句柄：句柄关闭时确保子进程被终止（避免孤儿进程）。
final class WorkshopProcessHandle: @unchecked Sendable {
    let process: Process
    let stdinPipe: Pipe?
    private let lock = NSLock()
    private var finished = false
    private var terminationRequested = false

    init(process: Process, stdinPipe: Pipe?) {
        self.process = process
        self.stdinPipe = stdinPipe
    }

    var isRunning: Bool { process.isRunning }

    func writeLine(_ line: String) {
        guard let stdinPipe else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            WorkshopLog.info("写入子进程 stdin 失败（内容不记录）")
        }
    }

    func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    /// 请求终止（SIGTERM → 2 秒宽限 → SIGKILL）。可重复调用。
    func terminate() {
        lock.lock()
        terminationRequested = true
        let alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    fileprivate func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// 进程运行器：读取 stdout/stderr 行，支持超时、取消与 stdin 交互。
actor WorkshopProcessRunner {

    /// 构造 SteamCMD 的隔离环境变量（完全替换环境）。
    ///
    /// 关键点：`HOME` 指向应用管理目录下的私有目录，使 SteamCMD 的账号缓存
    /// 只写入应用目录，既不读取也不修改用户全局 Steam 配置。
    static func steamcmdEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb"
        ]
    }

    /// 运行一次完整命令。
    ///
    /// - Parameters:
    ///   - stdinLines: 预先写入 stdin 的文本行（例如 `+login <user>`），写完后关闭 stdin。
    ///   - lineHandler: 每读取一行输出时回调（**调用方负责不落盘、限长**）。
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 300,
        stdinLines: [String]? = nil,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> WorkshopProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment ?? ProcessInfo.processInfo.environment

        // 防御：工作目录不存在时先创建（管理目录内的私有目录）。
        if let currentDirectory, !FileManager.default.fileExists(atPath: currentDirectory.path) {
            try? FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if let stdinLines {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
            let payload = stdinLines.joined(separator: "\n") + "\n"
            if let data = payload.data(using: .utf8) {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? pipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let output = LockedBox(BoundedOutputBuffer())
        let lineBuffer = LockedBox("")
        let gate = ProcessCompletionGate()
        gate.setExpectedPipes(2)

        let consume: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            var finishedLines: [String] = []
            lineBuffer.with { buffer in
                var text = String(decoding: data, as: UTF8.self)
                // 部分工具（进度条）使用 \r 分隔行。
                text = text.replacingOccurrences(of: "\r", with: "\n")
                buffer += text
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline]).trimmingCharacters(in: .controlCharacters)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    finishedLines.append(line)
                }
                if buffer.count > 8_192 {
                    finishedLines.append(String(buffer.prefix(8_192)))
                    buffer.removeFirst(min(buffer.count, 8_192))
                }
            }
            output.with { $0.append(data) }
            for line in finishedLines { lineHandler?(line) }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                gate.markEOF()
                return
            }
            consume(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                gate.markEOF()
                return
            }
            consume(data)
        }

        // 关键（R07）：terminationHandler 必须在 run() 之前安装。
        process.terminationHandler = { finishedProcess in
            gate.markExited(code: finishedProcess.terminationStatus)
        }

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw WorkshopProcessError.launchFailed(error.localizedDescription)
        }

        let handle = WorkshopProcessHandle(process: process, stdinPipe: stdinPipe)

        // 兜底轮询：即使 Foundation 回调缺失也能完成；同时处理取消。
        let poller = Task.detached(priority: .utility) { [weak handle] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let handle else { return }
                if !handle.isRunning {
                    gate.markExited(code: handle.process.terminationStatus)
                    return
                }
            }
        }
        _ = poller

        // 超时看门狗：超时只负责终止进程并标记；完成仍由闸门统一裁决。
        let watchdog = Task.detached(priority: .utility) { [weak handle] in
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let handle else { return }
                if !handle.isRunning { return }
                if Date() >= deadline {
                    gate.markTimedOut()
                    WorkshopLog.notice("子进程超时（\(Int(timeout)) 秒），正在终止")
                    handle.terminate()
                    return
                }
            }
        }

        // 宽限：进程退出后 3 秒内管道未 EOF（例如孙进程持有写端）也强制完成。
        let grace = Task.detached(priority: .utility) { [weak handle] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let handle else { return }
                if !handle.isRunning {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    gate.markGraceExpired()
                    return
                }
            }
        }

        let outcome: ProcessCompletionGate.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessCompletionGate.Outcome, Never>) in
                gate.onComplete { result in
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            handle.terminate()
        }

        watchdog.cancel()
        grace.cancel()
        poller.cancel()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        handle.markFinished()
        process.terminationHandler = nil

        // 冲刷未换行的残留内容（例如末尾 prompt）。
        let trailing = lineBuffer.with { buffer -> String in
            let value = buffer
            buffer = ""
            return value
        }
        if !trailing.isEmpty {
            lineHandler?(trailing)
        }

        if Task.isCancelled {
            throw WorkshopProcessError.cancelled
        }

        let duration = Date().timeIntervalSince(startedAt)
        let (text, truncated) = output.with { ($0.text(), $0.isTruncated) }

        if outcome.timedOut {
            throw WorkshopProcessError.timedOut(afterSeconds: Int(timeout))
        }
        if outcome.exitCode != 0 {
            let tail = WorkshopProcessResult(
                exitCode: outcome.exitCode,
                output: text,
                durationSeconds: duration,
                wasTimedOut: false,
                outputWasTruncated: truncated
            ).tail(limit: 300)
            throw WorkshopProcessError.nonZeroExit(code: outcome.exitCode, outputTail: tail)
        }
        return WorkshopProcessResult(
            exitCode: outcome.exitCode,
            output: text,
            durationSeconds: duration,
            wasTimedOut: false,
            outputWasTruncated: truncated
        )
    }
}

/// 交互式控制台输出事件。
///
/// 区分「换行结束的完整行」与「空闲冲刷的片段」很重要：SteamCMD 的关键输出
/// （例如 `Waiting for user info...` 与随后的 `OK` / `FAILED`）可能被拆成两个片段。
/// 调用方需要把连续片段拼接成逻辑行后再判定，避免把未完成的提示当成就绪，
/// 或漏掉稍后才到达的失败。
enum WorkshopConsoleEvent: Sendable, Equatable {
    /// 以换行结束的完整行。
    case line(String)
    /// 空闲（300ms 无换行）冲刷出来的片段（提示词常常没有换行，例如 `password: `）。
    case partial(String)
}

/// 把控制台事件拼接成逻辑行（R12）。
///
/// - `.partial`：返回「累积至今的片段」，使无换行提示能被立即识别为提示词；
/// - `.line`：与先前累积的片段拼接后返回，并清空累积。
struct SteamConsoleLineAssembler {
    private var pending = ""
    /// 累积上限，防御异常输出导致无限增长。
    private static let maxPending = 4_096

    /// 消费一个事件，返回本次应当判定的文本（空文本返回 nil）。
    mutating func consume(_ event: WorkshopConsoleEvent) -> String? {
        switch event {
        case .partial(let text):
            pending += text
            if pending.count > Self.maxPending {
                pending = String(pending.suffix(Self.maxPending))
            }
            return pending.isEmpty ? nil : pending
        case .line(let text):
            let merged = pending + text
            pending = ""
            return merged.isEmpty ? nil : merged
        }
    }
}

/// Byte framing preserves UTF-8 split across reads; CR completes overwritten lines.
struct SteamConsoleOutputFramer {
    private var pending = Data()
    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 || byte == 13 {
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
                if pending.count >= 16_384, let text = flushPartial() { lines.append(text) }
            }
        }
        return lines
    }
    /// Idle prompt flushes retain any incomplete UTF-8 suffix for the next read.
    mutating func flushPartial() -> String? {
        guard !pending.isEmpty else { return nil }
        var incomplete = 0
        var continuations = 0
        for byte in pending.suffix(4).reversed() {
            if byte & 0xc0 == 0x80 { continuations += 1; continue }
            let expected = byte & 0xf8 == 0xf0 ? 4 : byte & 0xf0 == 0xe0 ? 3 : byte & 0xe0 == 0xc0 ? 2 : 1
            if expected > continuations + 1 { incomplete = continuations + 1 }
            break
        }
        let count = pending.count - incomplete
        guard count > 0 else { return nil }
        let text = String(decoding: pending.prefix(count), as: UTF8.self)
        pending.removeFirst(count)
        return text
    }
}

/// 交互式子进程会话（SteamCMD 登录用：stdin 保持打开，实时读取输出行）。
final class WorkshopInteractiveSession: @unchecked Sendable {
    let handle: WorkshopProcessHandle
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let eventStream: AsyncStream<WorkshopConsoleEvent>
    private let eventContinuation: AsyncStream<WorkshopConsoleEvent>.Continuation
    private let lock = NSLock()
    private var terminated = false
    private let startedAt = Date()
    private var idleFlushTimer: DispatchSourceTimer?

    /// 输出行流（stdout + stderr 合并）。
    var lines: AsyncStream<String> { stream }

    /// 带「完整行 / 空闲片段」区分的输出事件流（R12：登录与下载状态机使用）。
    var events: AsyncStream<WorkshopConsoleEvent> { eventStream }

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory

        // 防御：工作目录不存在时先创建（管理目录内的私有目录）。
        if !FileManager.default.fileExists(atPath: currentDirectory.path) {
            try? FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        let makeStreamResult = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(600))
        self.stream = makeStreamResult.stream
        self.continuation = makeStreamResult.continuation
        let continuation = makeStreamResult.continuation
        let makeEventResult = AsyncStream<WorkshopConsoleEvent>.makeStream(bufferingPolicy: .bufferingNewest(600))
        self.eventStream = makeEventResult.stream
        self.eventContinuation = makeEventResult.continuation
        let eventContinuation = makeEventResult.continuation
        let handle = WorkshopProcessHandle(process: process, stdinPipe: stdinPipe)
        self.handle = handle

        let stdoutBuffer = LockedBox(SteamConsoleOutputFramer())
        let stderrBuffer = LockedBox(SteamConsoleOutputFramer())
        let emitLock = NSLock()

        let emit: @Sendable (Data, LockedBox<SteamConsoleOutputFramer>) -> Void = { data, buffer in
            emitLock.lock()
            defer { emitLock.unlock() }
            for line in buffer.with({ $0.append(data) }) {
                continuation.yield(line)
                eventContinuation.yield(.line(line))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { emit(data, stdoutBuffer) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { emit(data, stderrBuffer) }
        }

        // R07：terminationHandler 在 run() 之前安装。
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw WorkshopProcessError.launchFailed(error.localizedDescription)
        }

        startIdleFlushTimer(buffers: [stdoutBuffer, stderrBuffer], emitLock: emitLock)
    }

    /// 无换行提示（例如 `Enter account name: `）也会在 300ms 空闲后送达。
    private func startIdleFlushTimer(buffers: [LockedBox<SteamConsoleOutputFramer>], emitLock: NSLock) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            emitLock.lock()
            defer { emitLock.unlock() }
            for buffer in buffers {
                guard let pending = buffer.with({ $0.flushPartial() }), !pending.isEmpty else { continue }
                self.continuation.yield(pending)
                self.eventContinuation.yield(.partial(pending))
            }
        }
        timer.resume()
        idleFlushTimer = timer
    }

    var isRunning: Bool { handle.isRunning }

    var uptimeSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }

    func send(line: String) {
        handle.writeLine(line)
    }

    func terminate() {
        handle.terminate()
        finish()
    }

    private func finish() {
        lock.lock()
        let already = terminated
        terminated = true
        lock.unlock()
        guard !already else { return }
        idleFlushTimer?.cancel()
        idleFlushTimer = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        handle.closeStdin()
        handle.markFinished()
        continuation.finish()
        eventContinuation.finish()
    }
}
