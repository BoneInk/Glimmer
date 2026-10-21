import Foundation
import Darwin

/// Explicit host facts. A missing screen is unknown, never a render-buffer guess.
struct SceneScriptEnvironment: Codable, Equatable, Sendable {
    enum Presentation: String, Codable, Sendable { case wallpaper }
    let canvasSize: SceneVector2
    let screenResolution: SceneVector2?
    let presentation: Presentation
    func validate() throws {
        guard [canvasSize.x,canvasSize.y].allSatisfy({$0.isFinite && $0 > 0 && $0 <= 1_000_000}) else {
            throw SceneWallpaperFailure(message: "SceneScript 项目画布尺寸无效。")
        }
        if let screenResolution { try Self.validateScreen(screenResolution) }
    }
    static func validateScreen(_ size: SceneVector2) throws {
        guard [size.x,size.y].allSatisfy({$0.isFinite && $0 >= 1 && $0 <= 131_072 && $0.rounded() == $0}) else {
            throw SceneWallpaperFailure(message: "SceneScript 显示器像素尺寸无效。")
        }
    }
}

/// Per-frame native facts. The snapshot is copied into the isolated worker;
/// scripts cannot observe or mutate AppKit objects.
struct SceneScriptInputSnapshot: Codable, Equatable, Sendable {
    let cursorWorldPosition: SceneVector3?
    init(cursorWorldPosition: SceneVector3? = nil) { self.cursorWorldPosition = cursorWorldPosition }
    func validate() throws {
        guard let cursorWorldPosition else { return }
        guard [cursorWorldPosition.x,cursorWorldPosition.y,cursorWorldPosition.z]
            .allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000_000 }) else {
            throw SceneWallpaperFailure(message: "SceneScript 鼠标世界坐标无效。")
        }
    }
}

/// Stateful JavaScript stays outside the application. All pipe reads/writes and
/// deadlines run on a transport queue; cancelling an RPC terminates its worker.
actor SceneScriptWorkerClient {
    private let executableURL: URL
    private var transport: SceneScriptTransport?
    init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/GlimmerSceneScriptWorker")
    }

    func configure(program: SceneScriptProgram, userProperties: Data, environment: SceneScriptEnvironment? = nil) async throws -> SceneScriptFrame {
        try environment?.validate()
        await dispose()
        let channel = try SceneScriptTransport(executableURL: executableURL)
        transport = channel
        return try await request(operation: "configure", program: program, properties: userProperties, environment: environment, runtime: 0, frameTime: 0, timeout: 3)
    }
    func step(runtime: Double, frameTime: Double, input: SceneScriptInputSnapshot = .init()) async throws -> SceneScriptFrame {
        try input.validate()
        return try await request(operation: "step", input: input, runtime: runtime, frameTime: frameTime, timeout: 0.3)
    }
    func applyUserProperties(_ payload: Data, runtime: Double) async throws -> SceneScriptFrame {
        try await request(operation: "properties", properties: payload, runtime: runtime, frameTime: 0, timeout: 0.5)
    }
    func resizeScreen(_ environment: SceneScriptEnvironment, runtime: Double) async throws -> SceneScriptFrame {
        try environment.validate()
        guard environment.screenResolution != nil else { throw SceneWallpaperFailure(message: "SceneScript 没有真实显示器尺寸，无法发送 resizeScreen。") }
        return try await request(operation: "resize", environment: environment, runtime: runtime, frameTime: 0, timeout: 0.5)
    }
    func dispose() async {
        transport?.stop(message: "SceneScript 已停止")
        transport = nil
    }
    private func request(operation: String, program: SceneScriptProgram? = nil, properties: Data? = nil,
                         environment: SceneScriptEnvironment? = nil, input: SceneScriptInputSnapshot? = nil,
                         runtime: Double, frameTime: Double, timeout: TimeInterval) async throws -> SceneScriptFrame {
        try Task.checkCancellation()
        guard let channel = transport else { throw SceneWallpaperFailure(message: "SceneScript 尚未就绪，请重新加载壁纸。") }
        let id = UUID().uuidString
        let props = try properties.map { try JSONDecoder().decode(GWJSONValue.self, from: $0) }
        let bytes = try JSONEncoder().encode(SceneScriptRequest(id: id, operation: operation,
            program: program, properties: props, environment: environment, input: input,
            runtime: runtime, frameTime: frameTime))
        guard bytes.count <= 2_097_152 else { throw SceneWallpaperFailure(message: "SceneScript 请求超过大小限制。") }
        let response = try await withTaskCancellationHandler {
            try await channel.send(bytes, timeout: timeout)
        } onCancel: { channel.stop(message: "SceneScript 操作已取消") }
        try Task.checkCancellation()
        let envelope: SceneScriptResponse
        do { envelope = try JSONDecoder().decode(SceneScriptResponse.self, from: response) }
        catch { channel.stop(message: "SceneScript 返回格式无效"); throw error }
        guard envelope.id == id else { channel.stop(message: "SceneScript 响应不匹配"); throw SceneWallpaperFailure(message: "SceneScript 响应已失效。") }
        guard envelope.ok, let frame = envelope.frame else {
            throw SceneWallpaperFailure(message: envelope.error ?? "SceneScript 执行失败。")
        }
        guard frame.layers.count <= 512, Set(frame.layers.map(\.id)).count == frame.layers.count else {
            channel.stop(message: "SceneScript 图层无效")
            throw SceneWallpaperFailure(message: "SceneScript 返回了无效图层。")
        }
        do { for layer in frame.layers { try layer.validate() } }
        catch { channel.stop(message: "SceneScript 返回的图层超出支持范围"); throw error }
        return frame
    }
    deinit { transport?.stop(message: "SceneScript 已释放") }
}

private struct SceneScriptRequest: Encodable {
    let id: String
    let operation: String
    let program: SceneScriptProgram?
    let properties: GWJSONValue?
    let environment: SceneScriptEnvironment?
    let input: SceneScriptInputSnapshot?
    let runtime: Double
    let frameTime: Double
}
private struct SceneScriptResponse: Decodable {
    let id: String
    let ok: Bool
    let frame: SceneScriptFrame?
    let error: String?
}

private final class SceneScriptTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Glimmer.SceneScript.transport")
    private let writeQueue = DispatchQueue(label: "Glimmer.SceneScript.write")
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: DispatchWorkItem?
    private var buffer = Data()
    private var stopped = false
    private var requestTicket: UUID?
    private var memoryWatch: DispatchSourceTimer?

    init(executableURL: URL) throws {
        guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SceneWallpaperFailure(message: "SceneScript 运行组件缺失，请重新安装应用。")
        }
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.resume()
        source = reader
        // This is an observed RSS watchdog, not an OS hard allocation quota.
        // It also runs while a script is looping and cannot service another RPC.
        let watcher = DispatchSource.makeTimerSource(queue: queue)
        watcher.schedule(deadline: .now() + 0.05, repeating: 0.05)
        watcher.setEventHandler { [weak self] in
            guard let self, self.process.isRunning else { return }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(self.process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size) == size,
               info.pti_resident_size > 384 * 1024 * 1024 {
                self.stop(message: "SceneScript 内存占用过高，已停止此脚本。")
            }
        }
        watcher.resume()
        memoryWatch = watcher
        process.terminationHandler = { [weak self] _ in self?.stop(message: "SceneScript 进程已退出，请重新加载壁纸。") }
    }

    func send(_ payload: Data, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { pending in
            lock.lock()
            guard !stopped, continuation == nil else {
                lock.unlock()
                pending.resume(throwing: SceneWallpaperFailure(message: "SceneScript 操作已停止或仍在处理上一帧。"))
                return
            }
            let ticket = UUID()
            continuation = pending; requestTicket = ticket; buffer.removeAll(keepingCapacity: true)
            let deadline = DispatchWorkItem { [weak self] in self?.expire(ticket) }
            timeoutTask = deadline
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            writeQueue.async { [weak self] in
                guard let self else { return }
                do { try self.input.fileHandleForWriting.write(contentsOf: payload + Data([10])) }
                catch { self.stop(message: "无法向 SceneScript 发送数据。") }
            }
        }
    }

    private func expire(_ ticket: UUID) {
        lock.lock(); let expired = requestTicket == ticket; lock.unlock()
        if expired { stop(message: "SceneScript 执行超时，已停止此脚本；可以重新加载壁纸。") }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if count == 0 { stop(message: "SceneScript 已断开连接，请重新加载壁纸。"); return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                stop(message: "无法读取 SceneScript 画面。"); return
            }
            lock.lock()
            guard !stopped, continuation != nil else { lock.unlock(); stop(message: "SceneScript 返回了意外数据。"); return }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 524_288 else { lock.unlock(); stop(message: "SceneScript 返回数据超过限制。"); return }
            if let newline = buffer.firstIndex(of: 10) {
                guard newline == buffer.endIndex - 1 else { lock.unlock(); stop(message: "SceneScript 返回多余数据。"); return }
                let result = Data(buffer[..<newline]), pending = continuation
                continuation = nil; requestTicket = nil; timeoutTask?.cancel(); timeoutTask = nil; buffer.removeAll(keepingCapacity: true)
                lock.unlock(); pending?.resume(returning: result); return
            }
            lock.unlock()
        }
    }

    func stop(message: String) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let pending = continuation; continuation = nil; requestTicket = nil
        timeoutTask?.cancel(); timeoutTask = nil
        let reader = source; source = nil
        let watcher = memoryWatch; memoryWatch = nil
        lock.unlock()
        reader?.cancel()
        watcher?.cancel()
        if process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            queue.asyncAfter(deadline: .now() + 0.1) { [process] in
                if process.isRunning, process.processIdentifier == pid { _ = kill(pid, SIGKILL) }
            }
        }
        pending?.resume(throwing: SceneWallpaperFailure(message: message))
    }
    deinit { source?.cancel(); memoryWatch?.cancel(); if process.isRunning { process.terminate() } }
}
