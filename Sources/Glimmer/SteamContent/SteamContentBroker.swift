import Foundation
import Observation
import Darwin
import CryptoKit

private struct ContentEvent: Decodable, Sendable {
    let v: Int; let sessionNonce: String; let seq: Int64; let kind: String; let requestID: String
    let jobID: String?; let epoch: String?; let appID: UInt32?; let publishedFileID: String?; let manifestID: String?; let depotID: UInt32?
    let detail: ContentDetail?
}
private struct ContentDetail: Decodable, Sendable {
    let sessionID: String?; let challengeID: String?; let type: String?; let previousIncorrect: Bool?; let challengeURL: String?
    let accountName: String?; let steamID: String?; let refreshToken: String?; let guardData: String?
    let reason: String?; let productionAuthentication: Bool?; let productionWorkshopDownload: Bool?; let productionEngineAssets: Bool?
    let logicalTotalBytes: String?; let receivedPayloadBytes: String?; let downloadedVerifiedBytes: String?; let reusedVerifiedBytes: String?; let successfulCompressedPayloadBytes: String?
    let cdnDirectory: ContentCDNDirectory?
    let counters: ContentCounters?; let contentRelativePath: String?; let validationRequired: Bool?; let planFingerprint: String?
    let cacheRelativePath: String?; let manifestIdentity: ContentManifestIdentity?; let files: [ContentEngineFile]?
    let manifests: [ContentInspectionManifest]?; let paths: [String]?
    let complete: Bool?; let groups: [ContentInventoryGroup]?; let extensions: [ContentInventoryGroup]?
    let totalFileCount: Int?; let totalBytes: String?; let maximumFileBytes: String?
    let excludedExecutableCount: Int?; let excludedExecutableBytes: String?; let reportSHA256: String?; let offset: Int?
    let inventoryFiles: [ContentInventoryFile]?
    let fileCount: Int?
    func progress() throws -> SteamContentProgress {
        try ContentCounters(logicalTotalBytes: logicalTotalBytes, receivedPayloadBytes: receivedPayloadBytes, downloadedVerifiedBytes: downloadedVerifiedBytes, reusedVerifiedBytes: reusedVerifiedBytes, successfulCompressedPayloadBytes: successfulCompressedPayloadBytes).progress()
    }
}
private struct ContentManifestIdentity: Decodable, Sendable { let sha256: String; let depotID: UInt32; let manifestID: String }
private struct ContentEngineFile: Decodable, Sendable {
    let logicalPath: String; let relativePath: String; let sha1: String?; let sha256: String?; let sizeBytes: String
}
private struct ContentInspectionManifest: Decodable, Sendable { let depotID: UInt32; let manifestID: String }
private struct ContentInventoryFile: Decodable, Sendable {
    let logicalPath: String; let manifestPath: String; let depotID: UInt32; let manifestID: String
    let sizeBytes: String; let sha1: String; let category: String; let `extension`: String; let archiveCandidate: Bool
}
private struct ContentInventoryGroup: Decodable, Sendable {
    let category: String; let fileCount: Int; let totalBytes: String; let maximumFileBytes: String
}
private struct ContentCDNDirectory: Decodable, Sendable {
    struct Group: Decodable, Sendable { let type: String; let httpsCapability: String; let rejection: String; let count: Int }
    let total: Int; let accepted: Int; let groups: [Group]
    var publicValue: SteamContentCDNDirectoryDiagnostics? {
        guard (0...1024).contains(total), (0...total).contains(accepted), groups.count <= 96 else { return nil }
        var sum = 0, acceptedSum = 0, seen = Set<String>()
        for group in groups {
            guard ["CDN", "SteamCache", "other"].contains(group.type),
                  ["mandatory", "optional", "unavailable", "other"].contains(group.httpsCapability),
                  ["none", "https_not_advertised", "proxy", "server_type", "hostname", "app_restricted", "metadata"].contains(group.rejection),
                  (1...1024).contains(group.count), sum <= total - group.count,
                  seen.insert(group.type + "|" + group.httpsCapability + "|" + group.rejection).inserted else { return nil }
            sum += group.count
            if group.rejection == "none" { acceptedSum += group.count }
        }
        guard sum == total, acceptedSum == accepted else { return nil }
        return .init(total: total, accepted: accepted, groups: groups.map { .init(type: $0.type, httpsCapability: $0.httpsCapability, rejection: $0.rejection, count: $0.count) })
    }
}
private struct ContentCounters: Decodable, Sendable {
    let logicalTotalBytes: String?; let receivedPayloadBytes: String?; let downloadedVerifiedBytes: String?; let reusedVerifiedBytes: String?; let successfulCompressedPayloadBytes: String?
    func progress() throws -> SteamContentProgress {
        func number(_ value: String?) throws -> UInt64 {
            guard let value, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = UInt64(value) else { throw SteamContentBrokerError.protocolViolation }; return n
        }
        let total = try number(logicalTotalBytes), downloaded = try number(downloadedVerifiedBytes), reused = try number(reusedVerifiedBytes)
        guard downloaded <= total, reused <= total - downloaded, total <= 2 * 1024 * 1024 * 1024 else { throw SteamContentBrokerError.protocolViolation }
        return try .init(logicalTotalBytes: total, receivedPayloadBytes: number(receivedPayloadBytes), downloadedVerifiedBytes: downloaded, reusedVerifiedBytes: reused, successfulCompressedPayloadBytes: number(successfulCompressedPayloadBytes))
    }
}
private struct ContentInventoryDraft {
    let manifests: [ContentInspectionManifest]; let groups: [ContentInventoryGroup]; let extensions: [ContentInventoryGroup]
    let totalFileCount: Int; let totalBytes: String; let maximumFileBytes: String
    let excludedExecutableCount: Int; let excludedExecutableBytes: String
    var files: [ContentInventoryFile]
}
private struct ContentRuntimeDraft {
    let identity: SteamEngineAssetManifestIdentity; let fileCount: Int; let totalBytes: UInt64
    var planned: [ContentEngineFile] = []; var verified: [ContentEngineFile] = []; var verificationStarted = false
}

/// Owns one helper and its authenticated session. Secrets use stdin/private memory
/// and an explicitly injected session store only. No SteamCMD profile, credential
/// log/file, constructor auto-login, or native network IO.
@MainActor @Observable final class SteamContentBroker {
    @ObservationIgnored var onStateChange: (@MainActor (SteamLoginState) -> Void)?
    private(set) var state: SteamLoginState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    private(set) var challenge: SteamContentChallenge?
    private(set) var progress: SteamContentProgress = .zero
    private(set) var lastCDNDirectoryDiagnostics: SteamContentCDNDirectoryDiagnostics?
    private(set) var lastRuntimeDiagnosticPhase: String?
    private(set) var isReady = false
    private(set) var isDownloading = false
    var hasInMemoryRefreshSession: Bool { refreshSession != nil }
    private(set) var hasSavedSession = false
    private(set) var sessionPersistenceMessage: String?
    @ObservationIgnored private let sessionStore: (any SteamContentSessionStoring)?
    @ObservationIgnored private var loadedSavedSession: SteamContentSavedSession?
    @ObservationIgnored private var savedAvailabilityLoaded = false
    @ObservationIgnored private var savedRestoreBlocked = false
    @ObservationIgnored private var restoringSavedSession = false
    @ObservationIgnored private var authUsesRefresh = false
    @ObservationIgnored private var pendingGuardData: String?
    @ObservationIgnored private var savedDeletionCount = 0
    @ObservationIgnored private var persistenceGeneration = UUID()
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTaskID = UUID()
    let workspaceURL: URL
    @ObservationIgnored private let executableURL: URL
    @ObservationIgnored private let responseTimeout: Duration
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var stderrReader: Task<Void, Never>?
    @ObservationIgnored private var nonce: String?
    @ObservationIgnored private var sequence: Int64 = 0
    @ObservationIgnored private var processGeneration = UUID()
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var refreshSession: (username: String, token: String, guardData: String?)?
    @ObservationIgnored private var readyWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var authWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var authRequest: String?
    @ObservationIgnored private var authCancelling = false
    @ObservationIgnored private var authDrainWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var closeOperation: Task<Void, Never>?
    @ObservationIgnored private var controlWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var controls: [String: String] = [:]
    @ObservationIgnored private var downloadWaiter: CheckedContinuation<SteamContentDownloadResult, Error>?
    @ObservationIgnored private var downloadIdentity: (request: String, job: String, epoch: UInt64, item: String, session: String)?
    @ObservationIgnored private var manifest: (id: String, depot: UInt32)?
    @ObservationIgnored private var engineWaiter: CheckedContinuation<SteamEngineAssetBundle, Error>?
    @ObservationIgnored private var inspectionWaiter: CheckedContinuation<SteamEngineAssetInspection, Error>?
    @ObservationIgnored private var engineIdentity: (request: String, job: String, epoch: UInt64, session: String, resources: [String], inspect: Bool)?
    @ObservationIgnored private var enginePlan: (identity: SteamEngineAssetManifestIdentity, files: [ContentEngineFile])?
    @ObservationIgnored private var inventoryWaiter: CheckedContinuation<SteamEngineAssetInventory, Error>?
    @ObservationIgnored private var inventoryIdentity: (request: String, job: String, epoch: UInt64, session: String)?
    @ObservationIgnored private var inventoryDraft: ContentInventoryDraft?
    @ObservationIgnored private var runtimeWaiter: CheckedContinuation<SteamSceneRuntimeAssetBundle, Error>?
    @ObservationIgnored private var runtimeIdentity: (request: String, job: String, epoch: UInt64, session: String)?
    @ObservationIgnored private var runtimeDraft: ContentRuntimeDraft?
    @ObservationIgnored private var epochs: [UUID: UInt64] = [:]
    @ObservationIgnored private var progressHandler: (@MainActor (SteamContentProgress) -> Void)?
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var cancelRequest: String?
    @ObservationIgnored private var acknowledgedCancels: Set<String> = []

    init(executableURL: URL? = nil, workspaceURL: URL, responseTimeout: Duration = .seconds(10), sessionStore: (any SteamContentSessionStoring)? = nil) throws {
        self.workspaceURL = try Self.canonicalWorkspaceURL(workspaceURL)
        self.executableURL = executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SteamContent/GlimmerSteamContent")
        self.responseTimeout = responseTimeout
        self.sessionStore = sessionStore
        try Self.validateWorkspace(self.workspaceURL)
    }
    deinit {
        if let owned = process {
            if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
            Task.detached { owned.waitUntilExit() }
        }
    }
    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private static func canonicalWorkspaceURL(_ url: URL) throws -> URL {
        // Foundation intentionally hides /private in macOS /var aliases. Resolve
        // the actual POSIX spelling for the helper's component no-follow walk,
        // while still rejecting caller-created symlink aliases.
        guard url.isFileURL, let path = realPath(url),
              url.standardizedFileURL.path == path || url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw SteamContentBrokerError.invalidWorkspace }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private static func validateWorkspace(_ url: URL) throws {
        guard url.isFileURL, url.path == realPath(url) else { throw SteamContentBrokerError.invalidWorkspace }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw SteamContentBrokerError.invalidWorkspace }
    }
    func start() async throws {
        if isReady { return }
        guard process == nil else { throw SteamContentBrokerError.busy }
        try Self.validateWorkspace(workspaceURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw SteamContentBrokerError.unavailable }
        let owned = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        let generation = UUID(); processGeneration = generation; sequence = 0; nonce = nil
        owned.executableURL = executableURL; owned.arguments = ["--workspace-root", workspaceURL.path]
        // Deliberately do not inherit ambient application credentials/proxy/session variables.
        owned.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        owned.currentDirectoryURL = workspaceURL
        owned.standardInput = stdinPipe; owned.standardOutput = stdoutPipe; owned.standardError = stderrPipe
        do { try owned.run() } catch { throw SteamContentBrokerError.unavailable }
        process = owned; input = stdinPipe.fileHandleForWriting
        let stream = SteamContentPipe.lines(stdoutPipe.fileHandleForReading)
        reader = Task { [weak self] in
            do {
                for try await line in stream { guard let self, self.processGeneration == generation else { return }; try self.receive(line) }
                guard let self, self.processGeneration == generation else { return }
                await self.abort(.processExited)
            } catch { guard let self, self.processGeneration == generation else { return }; await self.abort(.protocolViolation) }
        }
        // Drain and discard stderr without retaining arbitrary secret-bearing text.
        stderrReader = Task.detached {
            while let bytes = try? stderrPipe.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {}
        }
        try await withCheckedThrowingContinuation { readyWaiter = $0; deadline(generation: generation, request: "startup") }
    }
    private func send(_ command: String, request: String = UUID().uuidString, fields: [String: Any] = [:]) throws -> String {
        guard let input, process?.isRunning == true else { throw SteamContentBrokerError.processExited }
        var body = fields; body["v"] = 1; body["commandName"] = command; body["requestID"] = request
        guard JSONSerialization.isValidJSONObject(body) else { throw SteamContentBrokerError.invalidInput }
        var data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= SteamContentPipe.lineLimit else { throw SteamContentBrokerError.invalidInput }
        data.append(10)
        do { try input.write(contentsOf: data) } catch { throw SteamContentBrokerError.processExited }
        return request
    }
    func loginCredentials(username: String, password: String, guardData: String? = nil) async throws {
        guard !username.isEmpty, username.count <= 128, !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !password.isEmpty, password.count <= 512, (guardData?.count ?? 0) <= 8192 else { throw SteamContentBrokerError.invalidInput }
        var auth: [String: Any] = ["method": "credentials", "username": username, "password": password]
        if let guardData { auth["guardData"] = guardData }
        try await login(auth)
    }
    func loginQR() async throws { try await login(["method": "qr"]) }
    func restoreInMemorySession() async throws {
        guard let saved = refreshSession else { throw SteamContentBrokerError.unavailable }
        try await login(["method": "refresh", "username": saved.username, "refreshToken": saved.token])
    }
    /// Explicit caller-triggered lookup only. Constructors/start never read Keychain.
    func loadSavedSessionAvailability() async throws -> Bool {
        guard !savedRestoreBlocked, let sessionStore else { hasSavedSession = false; return false }
        let ticket = persistenceGeneration
        await persistenceTask?.value
        do {
            let saved = try await sessionStore.load()
            guard ticket == persistenceGeneration, !savedRestoreBlocked else { throw SteamContentBrokerError.cancelled }
            try saved?.validate()
            loadedSavedSession = saved; savedAvailabilityLoaded = true; hasSavedSession = saved != nil
            return hasSavedSession
        } catch {
            if ticket == persistenceGeneration {
                sessionPersistenceMessage = "无法读取 macOS 钥匙串中的登录状态。若旧版凭据访问被拒绝，请重新登录；旧项目不会被删除。"
            }
            if ticket != persistenceGeneration { throw SteamContentBrokerError.cancelled }
            throw SteamContentBrokerError.savedSessionAccessFailed
        }
    }
    func restoreSavedSession() async throws {
        guard !restoringSavedSession, authRequest == nil, sessionID == nil, !state.isActive, !isDownloading else { throw SteamContentBrokerError.busy }
        guard !savedRestoreBlocked, sessionStore != nil else { throw SteamContentBrokerError.savedSessionUnavailable }
        restoringSavedSession = true; defer { restoringSavedSession = false }
        let ticket = persistenceGeneration
        if !savedAvailabilityLoaded { _ = try await loadSavedSessionAvailability() }
        guard !Task.isCancelled, ticket == persistenceGeneration, !savedRestoreBlocked else { throw SteamContentBrokerError.cancelled }
        guard let saved = loadedSavedSession else { throw SteamContentBrokerError.savedSessionUnavailable }
        var auth: [String:Any] = ["method":"refresh", "username":saved.username, "refreshToken":saved.refreshToken]
        if let guardData = saved.guardData { auth["guardData"] = guardData }
        try await login(auth, savedRestore: true)
    }
    private func scheduleAcknowledgedSessionSave(ticket: UUID) -> Task<Void, Never>? {
        guard let sessionStore else { return nil }
        guard let refreshSession else {
            sessionPersistenceMessage = "当前连接可用，但 Steam 未返回可保存的会话，下次可能需要重新连接。"; return nil
        }
        let saved = SteamContentSavedSession(username: refreshSession.username, refreshToken: refreshSession.token, guardData: refreshSession.guardData)
        let identifier = UUID(), previous = persistenceTask
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if self.persistenceTaskID == identifier { self.persistenceTask = nil } }
            guard self.persistenceGeneration == ticket else { return }
            do {
                try await sessionStore.save(saved)
                guard self.persistenceGeneration == ticket else { return }
                self.loadedSavedSession = saved; self.savedAvailabilityLoaded = true; self.savedRestoreBlocked = false
                self.hasSavedSession = true; self.sessionPersistenceMessage = "登录状态已保存到 macOS 钥匙串。"
            } catch {
                guard self.persistenceGeneration == ticket else { return }
                self.hasSavedSession = false; self.loadedSavedSession = nil; self.savedAvailabilityLoaded = true; self.savedRestoreBlocked = true
                self.sessionPersistenceMessage = "当前 Steam 连接可用，但登录状态未能保存到 macOS 钥匙串，请确认系统授权后重试。"
            }
        }
        persistenceTaskID = identifier; persistenceTask = operation
        return operation
    }
    func retryPersistCurrentSession() async -> Bool {
        guard isReady, case .loggedIn = state, refreshSession != nil, savedDeletionCount == 0 else { return false }
        if let operation = scheduleAcknowledgedSessionSave(ticket: persistenceGeneration) { await operation.value }
        return hasSavedSession && !savedRestoreBlocked
    }
    private func deleteSavedSession() async {
        savedDeletionCount += 1; defer { savedDeletionCount -= 1 }
        persistenceGeneration = UUID(); let ticket = persistenceGeneration
        savedRestoreBlocked = true; loadedSavedSession = nil; savedAvailabilityLoaded = true; hasSavedSession = false
        await persistenceTask?.value
        guard let sessionStore else { return }
        do {
            try await sessionStore.delete()
            if persistenceGeneration == ticket { sessionPersistenceMessage = nil }
        } catch {
            if persistenceGeneration == ticket { sessionPersistenceMessage = "钥匙串中的登录状态未能清除，本应用已停止自动恢复；请重试退出登录。" }
        }
    }
    private func login(_ auth: [String: Any], savedRestore: Bool = false) async throws {
        guard authRequest == nil, !isDownloading, !state.isActive, sessionID == nil, savedDeletionCount == 0, !restoringSavedSession || savedRestore else { throw SteamContentBrokerError.busy }
        let request = UUID().uuidString
        let persistenceTicket = persistenceGeneration
        authUsesRefresh = auth["method"] as? String == "refresh"
        pendingGuardData = auth["guardData"] as? String
        authRequest = request; authCancelling = false; state = .preparing; challenge = nil
        do { try await start() } catch {
            state = .failed(reason: error.localizedDescription); finishAuth(.failure(error)); throw error
        }
        guard authRequest == request, !authCancelling, !Task.isCancelled else {
            state = .cancelled; finishAuth(.failure(SteamContentBrokerError.cancelled)); throw SteamContentBrokerError.cancelled
        }
        state = .loggingIn
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                authWaiter = continuation
                do {
                    _ = try send("login", request: request, fields: ["auth": auth])
                    let generation = processGeneration
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(310))
                        guard let self, self.processGeneration == generation, self.authRequest == request else { return }
                        await self.abort(.timeout)
                    }
                }
                catch { finishAuth(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in await self?.cancelAuthentication() } }
        guard !Task.isCancelled, persistenceTicket == persistenceGeneration, !authCancelling else { throw SteamContentBrokerError.cancelled }
    }
    func respondToChallenge(code: String? = nil, accepted: Bool? = nil) throws {
        guard let challenge, challenge.kind != .qr, !authCancelling else { throw SteamContentBrokerError.invalidInput }
        var response: [String: Any] = ["sessionID": challenge.sessionID, "challengeID": challenge.challengeID]
        if challenge.kind == .deviceConfirmation {
            guard let accepted, code == nil else { throw SteamContentBrokerError.invalidInput }; response["accepted"] = accepted
        } else {
            guard accepted == nil, let code, (4...16).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw SteamContentBrokerError.invalidInput }; response["code"] = code
        }
        let request = try send("auth_response", fields: ["response": response]); controls[request] = "auth_response"
        self.challenge = nil; state = .loggingIn
    }
    func cancelAuthentication() async {
        guard authRequest != nil else { return }
        authCancelling = true; challenge = nil
        if let sessionID { await closeSession(command: "auth_cancel", session: sessionID) }
        else { await withCheckedContinuation { authDrainWaiters.append($0) } }
        // A request cancelled during ready-handshake is never sent to the helper.
    }
    func logout() async {
        authCancelling = true; refreshSession = nil
        await deleteSavedSession()
        if let sessionID { authCancelling = true; await closeSession(command: "logout", session: sessionID) }
        else if authRequest != nil { await cancelAuthentication(); state = .idle }
        else { state = .idle }
    }
    private func closeSession(command: String, session: String) async {
        if let closeOperation { await closeOperation.value; return }
        let task = Task { await performCloseSession(command: command, session: session) }
        closeOperation = task
        await task.value
        closeOperation = nil
    }
    private func performCloseSession(command: String, session: String) async {
        let request = UUID().uuidString
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                controlWaiters[request] = continuation; controls[request] = command
                do { _ = try send(command, request: request, fields: ["sessionID": session]); deadline(generation: processGeneration, request: request) }
                catch { controlWaiters.removeValue(forKey: request)?.resume(throwing: SteamContentBrokerError.processExited) }
            }
            if self.sessionID == session { self.sessionID = nil }
            finishAuth(.failure(SteamContentBrokerError.cancelled)); state = command == "logout" ? .idle : .cancelled
        } catch { await abort(.processExited) }
    }
    func download(publishedFileID: String, jobID: UUID = UUID(), epoch: UInt64 = 1, onProgress: (@MainActor (SteamContentProgress) -> Void)? = nil) async throws -> SteamContentDownloadResult {
        guard let sessionID, case .loggedIn = state, isReady else { throw SteamContentBrokerError.unavailable }
        guard !isDownloading, authRequest == nil, !authCancelling else { throw SteamContentBrokerError.busy }
        guard epoch > 0, epoch > (epochs[jobID] ?? 0), epochs.count < 1024 || epochs[jobID] != nil,
              !publishedFileID.isEmpty, publishedFileID.utf8.allSatisfy({ (48...57).contains($0) }), let item = UInt64(publishedFileID), item > 0, String(item) == publishedFileID else { throw SteamContentBrokerError.invalidInput }
        try Task.checkCancellation()
        let request = UUID().uuidString; epochs[jobID] = epoch
        downloadIdentity = (request, jobID.uuidString, epoch, publishedFileID, sessionID); manifest = nil
        progress = .zero; lastCDNDirectoryDiagnostics = nil; isDownloading = true; progressHandler = onProgress; cancelRequest = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloadWaiter = continuation
                do { _ = try send("download", request: request, fields: ["sessionID": sessionID, "jobID": jobID.uuidString, "epoch": epoch, "publishedFileID": publishedFileID]) }
                catch { finishDownload(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.requestDownloadCancellation() } }
    }
    func engineAssets(desiredResources: [String], jobID: UUID = UUID(), epoch: UInt64 = 1,
                      onProgress: (@MainActor (SteamContentProgress) -> Void)? = nil) async throws -> SteamEngineAssetBundle {
        let resources = try Self.validatedEngineResources(desiredResources)
        guard let sessionID, case .loggedIn = state, isReady else { throw SteamContentBrokerError.unavailable }
        guard !isDownloading, authRequest == nil, !authCancelling else { throw SteamContentBrokerError.busy }
        guard epoch > 0, epoch > (epochs[jobID] ?? 0), epochs.count < 1024 || epochs[jobID] != nil else { throw SteamContentBrokerError.invalidInput }
        try Task.checkCancellation()
        let request = UUID().uuidString; epochs[jobID] = epoch
        engineIdentity = (request, jobID.uuidString, epoch, sessionID, resources, false); enginePlan = nil
        progress = .zero; lastCDNDirectoryDiagnostics = nil; isDownloading = true; progressHandler = onProgress; cancelRequest = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                engineWaiter = continuation
                do { _ = try send("engine_assets", request: request, fields: ["sessionID":sessionID, "jobID":jobID.uuidString,
                    "epoch":epoch, "appID":431960, "desiredResources":resources, "inspectOnly":false]) }
                catch { finishEngine(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.requestDownloadCancellation() } }
    }
    func inspectEngineAssets(desiredResources: [String] = SteamContentBroker.defaultEngineAssetInspectionResources,
                             jobID: UUID = UUID(), epoch: UInt64 = 1) async throws -> SteamEngineAssetInspection {
        let resources = try Self.validatedEngineResources(desiredResources)
        guard let sessionID, case .loggedIn = state, isReady else { throw SteamContentBrokerError.unavailable }
        guard !isDownloading, authRequest == nil, !authCancelling else { throw SteamContentBrokerError.busy }
        guard epoch > 0, epoch > (epochs[jobID] ?? 0), epochs.count < 1024 || epochs[jobID] != nil else { throw SteamContentBrokerError.invalidInput }
        try Task.checkCancellation()
        let request = UUID().uuidString; epochs[jobID] = epoch
        engineIdentity = (request, jobID.uuidString, epoch, sessionID, resources, true); enginePlan = nil
        progress = .zero; lastCDNDirectoryDiagnostics = nil; isDownloading = true; progressHandler = nil; cancelRequest = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inspectionWaiter = continuation
                do { _ = try send("engine_assets", request: request, fields: ["sessionID":sessionID, "jobID":jobID.uuidString,
                    "epoch":epoch, "appID":431960, "desiredResources":resources, "inspectOnly":true]) }
                catch { finishInspection(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.requestDownloadCancellation() } }
    }
    func inspectEngineAssetInventory(jobID: UUID = UUID(), epoch: UInt64 = 1) async throws -> SteamEngineAssetInventory {
        guard let sessionID, case .loggedIn = state, isReady else { throw SteamContentBrokerError.unavailable }
        guard !isDownloading, authRequest == nil, !authCancelling else { throw SteamContentBrokerError.busy }
        guard epoch > 0, epoch > (epochs[jobID] ?? 0), epochs.count < 1024 || epochs[jobID] != nil else { throw SteamContentBrokerError.invalidInput }
        try Task.checkCancellation()
        let request = UUID().uuidString; epochs[jobID] = epoch
        inventoryIdentity = (request, jobID.uuidString, epoch, sessionID); inventoryDraft = nil
        progress = .zero; lastCDNDirectoryDiagnostics = nil; isDownloading = true; progressHandler = nil; cancelRequest = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inventoryWaiter = continuation
                do { _ = try send("engine_assets_inventory", request: request, fields: ["sessionID":sessionID,
                    "jobID":jobID.uuidString, "epoch":epoch, "appID":431960]) }
                catch { finishInventory(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.requestDownloadCancellation() } }
    }
    func sceneRuntimeAssets(jobID: UUID = UUID(), epoch: UInt64 = 1,
                            onProgress: (@MainActor (SteamContentProgress) -> Void)? = nil) async throws -> SteamSceneRuntimeAssetBundle {
        guard let sessionID, case .loggedIn = state, isReady else { throw SteamContentBrokerError.unavailable }
        guard !isDownloading, authRequest == nil, !authCancelling else { throw SteamContentBrokerError.busy }
        guard epoch > 0, epoch > (epochs[jobID] ?? 0), epochs.count < 1024 || epochs[jobID] != nil else { throw SteamContentBrokerError.invalidInput }
        try Task.checkCancellation()
        let request = UUID().uuidString; epochs[jobID] = epoch
        runtimeIdentity = (request, jobID.uuidString, epoch, sessionID); runtimeDraft = nil
        lastRuntimeDiagnosticPhase = "request_sent"
        progress = .zero; lastCDNDirectoryDiagnostics = nil; isDownloading = true; progressHandler = onProgress; cancelRequest = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runtimeWaiter = continuation
                do { _ = try send("scene_runtime_assets", request: request, fields: ["sessionID":sessionID,
                    "jobID":jobID.uuidString, "epoch":epoch, "appID":431960]) }
                catch { finishRuntime(.failure(SteamContentBrokerError.processExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.requestDownloadCancellation() } }
    }
    static let requiredEngineAssetResources: [String] = [
        "materials/particle/halo.tex", "materials/particle/beam/beam_1.tex", "materials/particle/fog/fog1.tex",
        "materials/particle/beam/hose_2.tex", "materials/particle/beam/hose_2_normal.tex", "materials/util/noise.tex",
        "materials/gradient/gradient_iridescent.tex"
    ]
    static let sceneFontEngineAssetResource = "fonts/Alcubierre.otf"
    static let sceneEngineAssetResources = requiredEngineAssetResources + [sceneFontEngineAssetResource]
    static let defaultEngineAssetInspectionResources = sceneEngineAssetResources + ["shaders/common_blending.h"]
    private static let engineResourceAllowlist = Set(defaultEngineAssetInspectionResources)
    private static func validatedEngineResources(_ resources: [String]) throws -> [String] {
        guard (1...16).contains(resources.count), Set(resources).count == resources.count,
              resources.allSatisfy(engineResourceAllowlist.contains) else { throw SteamContentBrokerError.invalidInput }
        return resources
    }
    private func requestDownloadCancellation() {
        let identity: (job: String, epoch: UInt64)? = downloadIdentity.map { ($0.job, $0.epoch) } ?? engineIdentity.map { ($0.job, $0.epoch) } ?? inventoryIdentity.map { ($0.job, $0.epoch) } ?? runtimeIdentity.map { ($0.job, $0.epoch) }
        guard let identity, cancelRequest == nil else { return }
        let request = UUID().uuidString; cancelRequest = request; controls[request] = "cancel"
        do { _ = try send("cancel", request: request, fields: ["jobID": identity.job, "epoch": identity.epoch]); deadline(generation: processGeneration, request: request) }
        catch { Task { await abort(.processExited) } }
    }
    func cancelDownload() async {
        guard isDownloading else { return }
        requestDownloadCancellation()
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    func shutdown() async {
        await persistenceTask?.value
        persistenceGeneration = UUID()
        refreshSession = nil; loadedSavedSession = nil; savedAvailabilityLoaded = false
        guard process != nil else { state = .idle; return }
        let request = UUID().uuidString
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                controls[request] = "shutdown"; controlWaiters[request] = c
                do { _ = try send("shutdown", request: request); deadline(generation: processGeneration, request: request) }
                catch { controlWaiters.removeValue(forKey: request)?.resume(throwing: SteamContentBrokerError.processExited) }
            }
        } catch {}
        await abort(.cancelled); state = .idle
    }
    private func deadline(generation: UUID, request: String) {
        let timeout = responseTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.processGeneration == generation else { return }
            if (request == "startup" && !self.isReady) || self.controlWaiters[request] != nil || (self.cancelRequest == request && self.isDownloading) { await self.abort(.timeout) }
        }
    }
    private func finishAuth(_ result: Result<Void, Error>) {
        let waiter = authWaiter; authWaiter = nil; authRequest = nil; challenge = nil; pendingGuardData = nil
        waiter?.resume(with: result)
        let drains = authDrainWaiters; authDrainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func finishDownload(_ result: Result<SteamContentDownloadResult, Error>) {
        let waiter = downloadWaiter; downloadWaiter = nil; downloadIdentity = nil; manifest = nil; progressHandler = nil; isDownloading = false
        if let cancelRequest, acknowledgedCancels.remove(cancelRequest) != nil { controls.removeValue(forKey: cancelRequest) }; cancelRequest = nil
        waiter?.resume(with: result)
        let drains = drainWaiters; drainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func finishEngine(_ result: Result<SteamEngineAssetBundle, Error>) {
        let waiter = engineWaiter; engineWaiter = nil; engineIdentity = nil; enginePlan = nil; progressHandler = nil; isDownloading = false
        if let cancelRequest, acknowledgedCancels.remove(cancelRequest) != nil { controls.removeValue(forKey: cancelRequest) }; cancelRequest = nil
        waiter?.resume(with: result)
        let drains = drainWaiters; drainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func finishInspection(_ result: Result<SteamEngineAssetInspection, Error>) {
        let waiter = inspectionWaiter; inspectionWaiter = nil; engineIdentity = nil; enginePlan = nil; progressHandler = nil; isDownloading = false
        if let cancelRequest, acknowledgedCancels.remove(cancelRequest) != nil { controls.removeValue(forKey: cancelRequest) }; cancelRequest = nil
        waiter?.resume(with: result)
        let drains = drainWaiters; drainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func finishInventory(_ result: Result<SteamEngineAssetInventory, Error>) {
        let waiter = inventoryWaiter; inventoryWaiter = nil; inventoryIdentity = nil; inventoryDraft = nil; progressHandler = nil; isDownloading = false
        if let cancelRequest, acknowledgedCancels.remove(cancelRequest) != nil { controls.removeValue(forKey: cancelRequest) }; cancelRequest = nil
        waiter?.resume(with: result)
        let drains = drainWaiters; drainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func finishRuntime(_ result: Result<SteamSceneRuntimeAssetBundle, Error>) {
        let waiter = runtimeWaiter; runtimeWaiter = nil; runtimeIdentity = nil; runtimeDraft = nil; progressHandler = nil; isDownloading = false
        if let cancelRequest, acknowledgedCancels.remove(cancelRequest) != nil { controls.removeValue(forKey: cancelRequest) }; cancelRequest = nil
        waiter?.resume(with: result)
        let drains = drainWaiters; drainWaiters.removeAll(); drains.forEach { $0.resume() }
    }
    private func abort(_ error: SteamContentBrokerError) async {
        guard let owned = process else { return }
        processGeneration = UUID(); isReady = false; input = nil
        try? (owned.standardInput as? Pipe)?.fileHandleForWriting.close()
        if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        await Task.detached { owned.waitUntilExit() }.value
        process = nil; reader?.cancel(); reader = nil; stderrReader?.cancel(); stderrReader = nil
        sessionID = nil; nonce = nil; sequence = 0; controls.removeAll(); acknowledgedCancels.removeAll(); epochs.removeAll()
        readyWaiter?.resume(throwing: error); readyWaiter = nil
        finishAuth(.failure(error)); finishDownload(.failure(error)); finishEngine(.failure(error)); finishInspection(.failure(error)); finishInventory(.failure(error)); finishRuntime(.failure(error))
        let waiters = controlWaiters.values; controlWaiters.removeAll(); waiters.forEach { $0.resume(throwing: error) }
        state = error == .cancelled ? .cancelled : .failed(reason: error.localizedDescription)
    }
    private func receive(_ line: Data) throws {
        let event: ContentEvent
        do { event = try JSONDecoder().decode(ContentEvent.self, from: line) } catch { throw SteamContentBrokerError.protocolViolation }
        guard event.v == 1, event.seq > 0, sequence < Int64.max, event.seq == sequence + 1,
              !event.sessionNonce.isEmpty, event.sessionNonce.count <= 64 else { throw SteamContentBrokerError.protocolViolation }
        if let nonce { guard event.sessionNonce == nonce else { throw SteamContentBrokerError.protocolViolation } }
        else { guard event.kind == "ready", event.requestID == "startup", event.seq == 1 else { throw SteamContentBrokerError.protocolViolation }; nonce = event.sessionNonce }
        sequence = event.seq
        if event.kind == "fatal" { throw SteamContentBrokerError.protocolViolation }
        if event.kind == "ready" {
            guard !isReady, event.detail?.productionAuthentication == true, event.detail?.productionWorkshopDownload == true,
                  event.detail?.productionEngineAssets == true else { throw SteamContentBrokerError.protocolViolation }
            isReady = true; readyWaiter?.resume(); readyWaiter = nil; return
        }
        if let command = controls[event.requestID] {
            if event.kind == "rejected" { let error = rejection(event.detail?.reason); controls.removeValue(forKey: event.requestID); controlWaiters.removeValue(forKey: event.requestID)?.resume(throwing: error); if command == "auth_response" { Task { await abort(error) } }; return }
            let expected = command == "cancel" ? "cancel_requested" : command == "auth_response" ? "auth_response_accepted" : command == "shutdown" ? "stopped" : "logged_out"
            guard event.kind == expected else { throw SteamContentBrokerError.protocolViolation }
            if command == "auth_response" || command == "logout" || command == "auth_cancel" {
                guard event.detail?.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
            }
            if command == "cancel" { try matchActiveTransfer(event); acknowledgedCancels.insert(event.requestID); return } // Keep timeout until original terminal.
            controls.removeValue(forKey: event.requestID); controlWaiters.removeValue(forKey: event.requestID)?.resume(); return
        }
        if event.requestID == authRequest {
            if event.kind == "rejected" { let error = rejection(event.detail?.reason); sessionID = nil; state = .failed(reason: error.localizedDescription); finishAuth(.failure(error)); return }
            guard let detail = event.detail, let id = detail.sessionID, UUID(uuidString: id) != nil,
                  sessionID == nil || sessionID == id else { throw SteamContentBrokerError.protocolViolation }
            switch event.kind {
            case "auth_started":
                guard sessionID == nil else { throw SteamContentBrokerError.protocolViolation }; sessionID = id
                if authCancelling { Task { await closeSession(command: "auth_cancel", session: id) } }
            case "auth_challenge":
                guard sessionID == id, let challengeID = detail.challengeID, UUID(uuidString: challengeID) != nil,
                      let type = detail.type, let kind = SteamContentChallenge.Kind(rawValue: type) else { throw SteamContentBrokerError.protocolViolation }
                if authCancelling { return }
                var url: URL?
                if kind == .qr {
                    guard let raw = detail.challengeURL, raw.count <= 8192, let parsed = URL(string: raw), parsed.scheme == "https", parsed.host != nil else { throw SteamContentBrokerError.protocolViolation }; url = parsed
                }
                challenge = .init(sessionID: id, challengeID: challengeID, kind: kind, previousIncorrect: detail.previousIncorrect ?? false, challengeURL: url)
                state = kind == .deviceConfirmation || kind == .qr ? .awaitingMobileConfirmation : .awaitingGuardCode
            case "auth_result":
                guard sessionID == id else { throw SteamContentBrokerError.protocolViolation }
                if authCancelling { return } // Do not publish a late secret result during cancellation.
                guard let account = detail.accountName, !account.isEmpty, account.count <= 128,
                      let steamID = detail.steamID, !steamID.isEmpty, steamID.utf8.allSatisfy({ (48...57).contains($0) }),
                      (detail.refreshToken?.count ?? 0) <= 8192, (detail.guardData?.count ?? 0) <= 8192 else { throw SteamContentBrokerError.protocolViolation }
                if let token = detail.refreshToken, !token.isEmpty { refreshSession = (account, token, detail.guardData ?? pendingGuardData) }
                state = .loggedIn(userID: nil)
                if let operation = scheduleAcknowledgedSessionSave(ticket: persistenceGeneration) {
                    let request = event.requestID, generation = processGeneration
                    Task { [weak self] in
                        await operation.value
                        guard let self, self.processGeneration == generation, self.authRequest == request else { return }
                        self.finishAuth(self.authCancelling ? .failure(SteamContentBrokerError.cancelled) : .success(()))
                    }
                } else { finishAuth(.success(())) }
            case "auth_failed":
                let error = rejection(detail.reason); sessionID = nil
                if authUsesRefresh, ["steam_logon_5", "steam_logon_26", "steam_logon_27", "steam_logon_121"].contains(detail.reason ?? "") {
                    state = .failed(reason: SteamContentBrokerError.savedSessionRevoked.localizedDescription)
                    let request = event.requestID
                    Task { [weak self] in
                        guard let self else { return }
                        await self.deleteSavedSession()
                        guard self.authRequest == request else { return }
                        self.finishAuth(.failure(SteamContentBrokerError.savedSessionRevoked))
                    }
                } else { state = .failed(reason: error.localizedDescription); finishAuth(.failure(error)) }
            case "auth_cancelled":
                if !authCancelling { sessionID = nil; state = .cancelled; finishAuth(.failure(SteamContentBrokerError.cancelled)) }
            default: throw SteamContentBrokerError.protocolViolation
            }
            return
        }
        if event.requestID == downloadIdentity?.request {
            if event.kind == "rejected" { failCurrentDownload(event.detail); return }
            try matchDownload(event)
            switch event.kind {
            case "resolving":
                guard manifest == nil, event.manifestID == "0", event.depotID == 0, event.detail?.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
            case "started":
                guard manifest == nil, let id = event.manifestID, let number = UInt64(id), number > 0,
                      let depot = event.depotID, depot > 0, event.detail?.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
                manifest = (id, depot)
            case "progress":
                guard manifest != nil, let detail = event.detail else { throw SteamContentBrokerError.protocolViolation }
                try updateProgress(detail.progress())
            case "transfer_complete":
                guard manifest != nil, let detail = event.detail, detail.sessionID == sessionID, detail.validationRequired == true,
                      let counters = detail.counters, let relative = detail.contentRelativePath,
                      let fingerprint = detail.planFingerprint, fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw SteamContentBrokerError.protocolViolation }
                try updateProgress(counters.progress())
                guard progress.verifiedBytes == progress.logicalTotalBytes else { throw SteamContentBrokerError.protocolViolation }
                let content = try contentURL(relative)
                if cancelRequest != nil { finishDownload(.failure(SteamContentBrokerError.cancelled)) }
                else { finishDownload(.success(.init(contentURL: content, progress: progress, planFingerprint: fingerprint, validationRequired: true))) }
            case "cancelled": finishDownload(.failure(SteamContentBrokerError.cancelled))
            case "failed": failCurrentDownload(event.detail)
            default: throw SteamContentBrokerError.protocolViolation
            }
            return
        }
        if event.requestID == engineIdentity?.request {
            if event.kind == "rejected" { failCurrentEngine(event.detail); return }
            try matchEngine(event)
            guard let operation = engineIdentity else { throw SteamContentBrokerError.protocolViolation }
            switch event.kind {
            case "engine_assets_resolving":
                guard enginePlan == nil, event.manifestID == nil, event.depotID == nil,
                      event.detail?.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
            case "engine_assets_plan":
                guard !operation.inspect, enginePlan == nil, let detail = event.detail,
                      detail.sessionID == sessionID, let identity = try parseManifestIdentity(detail.manifestIdentity),
                      event.manifestID == String(identity.manifestID), event.depotID == identity.depotID,
                      let files = detail.files else { throw SteamContentBrokerError.protocolViolation }
                try validateEnginePlan(files, resources: operation.resources)
                enginePlan = (identity, files)
            case "progress":
                guard !operation.inspect, enginePlan != nil, let detail = event.detail else { throw SteamContentBrokerError.protocolViolation }
                try updateProgress(detail.progress())
            case "engine_assets_complete":
                guard !operation.inspect, let plan = enginePlan, let detail = event.detail,
                      detail.sessionID == sessionID, let identity = try parseManifestIdentity(detail.manifestIdentity),
                      identity == plan.identity, let files = detail.files, let relative = detail.cacheRelativePath else { throw SteamContentBrokerError.protocolViolation }
                let publicFiles = try validateEngineCompletion(files, planned: plan.files, resources: operation.resources)
                guard let counters = detail.counters else { throw SteamContentBrokerError.protocolViolation }
                try updateProgress(counters.progress())
                guard progress.verifiedBytes == progress.logicalTotalBytes else { throw SteamContentBrokerError.protocolViolation }
                let root = try validateEngineCache(relative: relative, identity: identity, files: publicFiles)
                if cancelRequest != nil { finishEngine(.failure(SteamContentBrokerError.cancelled)) }
                else { finishEngine(.success(.init(cacheRoot: root, manifestIdentity: identity, files: publicFiles))) }
            case "engine_assets_inspection":
                guard operation.inspect, enginePlan == nil, let detail = event.detail, detail.sessionID == sessionID,
                      let manifests = detail.manifests, let paths = detail.paths else { throw SteamContentBrokerError.protocolViolation }
                let result = try validateEngineInspection(manifests: manifests, paths: paths)
                if cancelRequest != nil { finishInspection(.failure(SteamContentBrokerError.cancelled)) }
                else { finishInspection(.success(result)) }
            case "cancelled":
                if operation.inspect { finishInspection(.failure(SteamContentBrokerError.cancelled)) }
                else { finishEngine(.failure(SteamContentBrokerError.cancelled)) }
            case "failed": failCurrentEngine(event.detail)
            default: throw SteamContentBrokerError.protocolViolation
            }
            return
        }
        if event.requestID == inventoryIdentity?.request {
            if event.kind == "rejected" { failCurrentInventory(event.detail); return }
            try matchInventory(event)
            guard let detail = event.detail, detail.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
            switch event.kind {
            case "engine_inventory_resolving":
                guard inventoryDraft == nil, event.manifestID == nil, event.depotID == nil else { throw SteamContentBrokerError.protocolViolation }
            case "engine_inventory_begin":
                guard inventoryDraft == nil, detail.complete == true, let manifests = detail.manifests,
                      let groups = detail.groups, let extensions = detail.extensions,
                      let fileCount = detail.totalFileCount, let total = detail.totalBytes,
                      let maximum = detail.maximumFileBytes, let excludedCount = detail.excludedExecutableCount,
                      let excludedBytes = detail.excludedExecutableBytes else { throw SteamContentBrokerError.protocolViolation }
                inventoryDraft = .init(manifests: manifests, groups: groups, extensions: extensions,
                    totalFileCount: fileCount, totalBytes: total, maximumFileBytes: maximum,
                    excludedExecutableCount: excludedCount, excludedExecutableBytes: excludedBytes, files: [])
            case "engine_inventory_chunk":
                guard var draft = inventoryDraft, detail.offset == draft.files.count,
                      let files = detail.inventoryFiles, (1...4).contains(files.count),
                      draft.files.count <= 20_000 - files.count else { throw SteamContentBrokerError.protocolViolation }
                draft.files.append(contentsOf: files); inventoryDraft = draft
            case "engine_inventory_complete":
                guard detail.complete == true, let hash = detail.reportSHA256, let draft = inventoryDraft else { throw SteamContentBrokerError.protocolViolation }
                let result = try validateInventory(draft, reportSHA256: hash)
                if cancelRequest != nil { finishInventory(.failure(SteamContentBrokerError.cancelled)) }
                else { finishInventory(.success(result)) }
            case "cancelled": finishInventory(.failure(SteamContentBrokerError.cancelled))
            case "failed": failCurrentInventory(detail)
            default: throw SteamContentBrokerError.protocolViolation
            }
            return
        }
        if event.requestID == runtimeIdentity?.request {
            if event.kind == "rejected" { failCurrentRuntime(event.detail); return }
            try matchRuntime(event)
            guard let detail = event.detail else { throw SteamContentBrokerError.protocolViolation }
            switch event.kind {
            case "scene_runtime_assets_resolving":
                lastRuntimeDiagnosticPhase = "resolving"
                guard runtimeDraft == nil, event.manifestID == nil, event.depotID == nil, detail.sessionID == sessionID else { throw SteamContentBrokerError.protocolViolation }
            case "scene_runtime_assets_plan":
                lastRuntimeDiagnosticPhase = "plan"
                guard runtimeDraft == nil, detail.sessionID == sessionID, let identity = try parseManifestIdentity(detail.manifestIdentity),
                      event.manifestID == String(identity.manifestID), event.depotID == identity.depotID,
                      let count = detail.fileCount, (1...4096).contains(count), let bytesText = detail.totalBytes,
                      let bytes = Self.decimal(bytesText), bytes <= 128 * 1024 * 1024 else { throw SteamContentBrokerError.protocolViolation }
                runtimeDraft = .init(identity: identity, fileCount: count, totalBytes: bytes)
            case "scene_runtime_assets_plan_chunk":
                lastRuntimeDiagnosticPhase = "plan_chunk"
                guard var draft = runtimeDraft, !draft.verificationStarted, detail.offset == draft.planned.count,
                      let files = detail.files, (1...4).contains(files.count), draft.planned.count <= draft.fileCount - files.count else { throw SteamContentBrokerError.protocolViolation }
                draft.planned.append(contentsOf: files); runtimeDraft = draft
            case "progress":
                lastRuntimeDiagnosticPhase = "transfer"
                guard let draft = runtimeDraft, draft.planned.count == draft.fileCount else { throw SteamContentBrokerError.protocolViolation }
                try updateProgress(detail.progress())
            case "scene_runtime_assets_verified_begin":
                lastRuntimeDiagnosticPhase = "verified_begin"
                guard var draft = runtimeDraft, draft.planned.count == draft.fileCount, !draft.verificationStarted,
                      detail.fileCount == draft.fileCount else { throw SteamContentBrokerError.protocolViolation }
                draft.verificationStarted = true; runtimeDraft = draft
            case "scene_runtime_assets_verified_chunk":
                lastRuntimeDiagnosticPhase = "verified_chunk"
                guard var draft = runtimeDraft, draft.verificationStarted, detail.offset == draft.verified.count,
                      let files = detail.files, (1...4).contains(files.count), draft.verified.count <= draft.fileCount - files.count else { throw SteamContentBrokerError.protocolViolation }
                draft.verified.append(contentsOf: files); runtimeDraft = draft
            case "scene_runtime_assets_complete":
                lastRuntimeDiagnosticPhase = "complete_validation"
                guard let draft = runtimeDraft, draft.verificationStarted, draft.verified.count == draft.fileCount,
                      detail.fileCount == draft.fileCount, let identity = try parseManifestIdentity(detail.manifestIdentity), identity == draft.identity,
                      let relative = detail.cacheRelativePath, let counters = detail.counters else { throw SteamContentBrokerError.protocolViolation }
                let files = try validateRuntimeFiles(draft)
                try updateProgress(counters.progress())
                guard progress.logicalTotalBytes == draft.totalBytes, progress.verifiedBytes == draft.totalBytes else { throw SteamContentBrokerError.protocolViolation }
                let root = try validateRuntimeCache(relative: relative, identity: identity, files: files)
                if cancelRequest != nil { finishRuntime(.failure(SteamContentBrokerError.cancelled)) }
                else { finishRuntime(.success(.init(cacheRoot: root, manifestIdentity: identity, files: files))) }
            case "cancelled": lastRuntimeDiagnosticPhase = "cancelled"; finishRuntime(.failure(SteamContentBrokerError.cancelled))
            case "failed": lastRuntimeDiagnosticPhase = "helper_failed"; failCurrentRuntime(detail)
            default: throw SteamContentBrokerError.protocolViolation
            }
            return
        }
        // Unknown/stale request IDs never update state, counters or credentials.
        throw SteamContentBrokerError.protocolViolation
    }
    private func failCurrentDownload(_ detail: ContentDetail?) {
        let error = rejection(detail?.reason)
        lastCDNDirectoryDiagnostics = detail?.cdnDirectory?.publicValue
        if Self.isAuthenticationLoss(error) {
            // Invalidate synchronously before the queue sees the terminal failure.
            // The waiter resumes only after this owned process has stopped/drained;
            // a new login must not inherit the helper's stale SessionController.
            isReady = false; sessionID = nil; refreshSession = nil; challenge = nil
            state = .failed(reason: error.localizedDescription)
            let generation = processGeneration
            Task { [weak self] in
                guard let self, self.processGeneration == generation else { return }
                await self.abort(error)
            }
        } else { finishDownload(.failure(error)) }
    }
    private func failCurrentEngine(_ detail: ContentDetail?) {
        let error = rejection(detail?.reason)
        lastCDNDirectoryDiagnostics = detail?.cdnDirectory?.publicValue
        if Self.isAuthenticationLoss(error) {
            isReady = false; sessionID = nil; refreshSession = nil; challenge = nil
            state = .failed(reason: error.localizedDescription)
            let generation = processGeneration
            Task { [weak self] in
                guard let self, self.processGeneration == generation else { return }
                await self.abort(error)
            }
        } else if engineIdentity?.inspect == true { finishInspection(.failure(error)) }
        else { finishEngine(.failure(error)) }
    }
    private func failCurrentInventory(_ detail: ContentDetail?) {
        let error = rejection(detail?.reason)
        lastCDNDirectoryDiagnostics = detail?.cdnDirectory?.publicValue
        if Self.isAuthenticationLoss(error) {
            isReady = false; sessionID = nil; refreshSession = nil; challenge = nil; state = .failed(reason: error.localizedDescription)
            let generation = processGeneration
            Task { [weak self] in guard let self, self.processGeneration == generation else { return }; await self.abort(error) }
        } else { finishInventory(.failure(error)) }
    }
    private func failCurrentRuntime(_ detail: ContentDetail?) {
        let error = rejection(detail?.reason); lastCDNDirectoryDiagnostics = detail?.cdnDirectory?.publicValue
        if Self.isAuthenticationLoss(error) {
            isReady = false; sessionID = nil; refreshSession = nil; challenge = nil; state = .failed(reason: error.localizedDescription)
            let generation = processGeneration
            Task { [weak self] in guard let self, self.processGeneration == generation else { return }; await self.abort(error) }
        } else { finishRuntime(.failure(error)) }
    }
    /// Fixed helper codes only. Callers may use this to offer one saved-session
    /// recovery without treating ordinary CDN/network failures as authentication.
    static func isAuthenticationLoss(_ error: Error) -> Bool {
        guard case .helperRejected(let code) = error as? SteamContentBrokerError else { return false }
        return ["session_not_authenticated", "steam_disconnected", "stale_session", "auth_adapter_not_authenticated"].contains(code)
    }
    private func matchDownload(_ event: ContentEvent) throws {
        guard let job = downloadIdentity, event.jobID == job.job, event.epoch == String(job.epoch),
              event.appID == 431960, event.publishedFileID == job.item, sessionID == job.session else { throw SteamContentBrokerError.protocolViolation }
        if let manifest { guard event.manifestID == manifest.id, event.depotID == manifest.depot else { throw SteamContentBrokerError.protocolViolation } }
    }
    private func matchActiveTransfer(_ event: ContentEvent) throws {
        if downloadIdentity != nil { try matchDownload(event); return }
        if inventoryIdentity != nil { try matchInventory(event); return }
        if runtimeIdentity != nil { try matchRuntime(event); return }
        try matchEngine(event)
    }
    private func matchInventory(_ event: ContentEvent) throws {
        guard let job = inventoryIdentity, event.jobID == job.job, event.epoch == String(job.epoch),
              event.appID == 431960, event.publishedFileID == nil, event.manifestID == nil, event.depotID == nil,
              sessionID == job.session else { throw SteamContentBrokerError.protocolViolation }
    }
    private func matchRuntime(_ event: ContentEvent) throws {
        guard let job = runtimeIdentity, event.jobID == job.job, event.epoch == String(job.epoch),
              event.appID == 431960, event.publishedFileID == nil, sessionID == job.session else { throw SteamContentBrokerError.protocolViolation }
        if let draft = runtimeDraft {
            guard event.manifestID == String(draft.identity.manifestID), event.depotID == draft.identity.depotID else { throw SteamContentBrokerError.protocolViolation }
        }
    }
    private func matchEngine(_ event: ContentEvent) throws {
        guard let job = engineIdentity, event.jobID == job.job, event.epoch == String(job.epoch),
              event.appID == 431960, event.publishedFileID == nil, sessionID == job.session else { throw SteamContentBrokerError.protocolViolation }
        if let plan = enginePlan {
            guard event.manifestID == String(plan.identity.manifestID), event.depotID == plan.identity.depotID else { throw SteamContentBrokerError.protocolViolation }
        }
    }
    private func parseManifestIdentity(_ value: ContentManifestIdentity?) throws -> SteamEngineAssetManifestIdentity? {
        guard let value, Self.isLowerHex(value.sha256, count: 64), value.depotID > 0,
              let manifest = UInt64(value.manifestID), manifest > 0, String(manifest) == value.manifestID else { throw SteamContentBrokerError.protocolViolation }
        return .init(sha256: value.sha256, depotID: value.depotID, manifestID: manifest)
    }
    private func validateEnginePlan(_ files: [ContentEngineFile], resources: [String]) throws {
        guard files.count == resources.count, files.count <= 16 else { throw SteamContentBrokerError.protocolViolation }
        var seen = Set<String>(), total: UInt64 = 0
        for file in files {
            guard resources.contains(file.logicalPath), seen.insert(file.logicalPath).inserted,
                  file.relativePath == "assets/" + file.logicalPath, let sha1 = file.sha1,
                  Self.isLowerHex(sha1, count: 40), file.sha256 == nil,
                  let size = Self.decimal(file.sizeBytes), size <= 64 * 1024 * 1024,
                  total <= 64 * 1024 * 1024 - size else { throw SteamContentBrokerError.protocolViolation }
            total += size
        }
    }
    private func validateEngineCompletion(_ files: [ContentEngineFile], planned: [ContentEngineFile],
                                          resources: [String]) throws -> [SteamEngineAssetFile] {
        guard files.count == resources.count, files.count == planned.count else { throw SteamContentBrokerError.protocolViolation }
        let plan = Dictionary(uniqueKeysWithValues: planned.map { ($0.logicalPath, $0) })
        var result: [SteamEngineAssetFile] = [], seen = Set<String>(), total: UInt64 = 0
        for file in files {
            guard let expected = plan[file.logicalPath], resources.contains(file.logicalPath), seen.insert(file.logicalPath).inserted,
                  file.relativePath == expected.relativePath, file.sizeBytes == expected.sizeBytes,
                  file.sha1 == nil, let sha256 = file.sha256, Self.isLowerHex(sha256, count: 64),
                  let size = Self.decimal(file.sizeBytes), size <= 64 * 1024 * 1024,
                  total <= 64 * 1024 * 1024 - size else { throw SteamContentBrokerError.protocolViolation }
            total += size; result.append(.init(logicalPath: file.logicalPath, relativePath: file.relativePath, sha256: sha256, sizeBytes: size))
        }
        return result.sorted { $0.logicalPath < $1.logicalPath }
    }
    private func validateRuntimeFiles(_ draft: ContentRuntimeDraft) throws -> [SteamEngineAssetFile] {
        guard draft.planned.count == draft.fileCount, draft.verified.count == draft.fileCount else { throw SteamContentBrokerError.protocolViolation }
        var plans: [String: ContentEngineFile] = [:], total: UInt64 = 0, previous = ""
        let forbidden = [".exe", ".dll", ".dylib", ".so"]
        for file in draft.planned {
            guard (try? Self.normalizedRelativePath(file.relativePath)) == file.relativePath,
                  file.relativePath == "assets/" + file.logicalPath, file.relativePath > previous,
                  !forbidden.contains(where: { file.relativePath.lowercased().hasSuffix($0) }),
                  let sha1 = file.sha1, Self.isLowerHex(sha1, count: 40), file.sha256 == nil,
                  let size = Self.decimal(file.sizeBytes), size <= 16 * 1024 * 1024,
                  total <= 128 * 1024 * 1024 - size, plans.updateValue(file, forKey: file.relativePath) == nil else { throw SteamContentBrokerError.protocolViolation }
            total += size; previous = file.relativePath
        }
        guard total == draft.totalBytes else { throw SteamContentBrokerError.protocolViolation }
        var result: [SteamEngineAssetFile] = []; previous = ""
        for file in draft.verified {
            guard let planned = plans[file.relativePath], file.relativePath > previous,
                  file.logicalPath == planned.logicalPath, file.sizeBytes == planned.sizeBytes, file.sha1 == nil,
                  let sha256 = file.sha256, Self.isLowerHex(sha256, count: 64), let size = Self.decimal(file.sizeBytes) else { throw SteamContentBrokerError.protocolViolation }
            result.append(.init(logicalPath: file.logicalPath, relativePath: file.relativePath, sha256: sha256, sizeBytes: size)); previous = file.relativePath
        }
        guard result.count == plans.count else { throw SteamContentBrokerError.protocolViolation }
        return result
    }
    private func validateEngineInspection(manifests: [ContentInspectionManifest], paths: [String]) throws -> SteamEngineAssetInspection {
        guard (1...32).contains(manifests.count), paths.count <= 256, paths == paths.sorted(), Set(paths).count == paths.count,
              paths.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else { throw SteamContentBrokerError.protocolViolation }
        var publicManifests: [SteamEngineAssetInspection.Manifest] = [], seen = Set<String>()
        for value in manifests {
            guard value.depotID > 0, let id = UInt64(value.manifestID), id > 0, String(id) == value.manifestID,
                  seen.insert("\(value.depotID):\(id)").inserted else { throw SteamContentBrokerError.protocolViolation }
            publicManifests.append(.init(depotID: value.depotID, manifestID: id))
        }
        guard publicManifests == publicManifests.sorted(by: { $0.depotID == $1.depotID ? $0.manifestID < $1.manifestID : $0.depotID < $1.depotID }),
              paths.allSatisfy(Self.allowedInspectionPath) else { throw SteamContentBrokerError.protocolViolation }
        return .init(manifests: publicManifests, paths: paths)
    }
    private func validateInventory(_ draft: ContentInventoryDraft, reportSHA256: String) throws -> SteamEngineAssetInventory {
        guard Self.isLowerHex(reportSHA256, count: 64), (1...32).contains(draft.manifests.count),
              draft.totalFileCount == draft.files.count, draft.files.count <= 20_000,
              (0...20_000).contains(draft.excludedExecutableCount),
              let declaredTotal = Self.decimal(draft.totalBytes), let declaredMaximum = Self.decimal(draft.maximumFileBytes),
              let excludedBytes = Self.decimal(draft.excludedExecutableBytes) else { throw SteamContentBrokerError.protocolViolation }
        var manifests: [SteamEngineAssetInventory.Manifest] = [], manifestKeys = Set<String>()
        for value in draft.manifests {
            guard value.depotID > 0, let id = UInt64(value.manifestID), id > 0, String(id) == value.manifestID,
                  manifestKeys.insert("\(value.depotID):\(id)").inserted else { throw SteamContentBrokerError.protocolViolation }
            manifests.append(.init(depotID: value.depotID, manifestID: id))
        }
        guard manifests == manifests.sorted(by: { $0.depotID == $1.depotID ? $0.manifestID < $1.manifestID : $0.depotID < $1.depotID }) else { throw SteamContentBrokerError.protocolViolation }
        let categories = Set(["shaders", "effects", "materials", "particles", "fonts", "scripts", "models", "assets-root", "other-assets"])
        let forbidden = Set([".exe", ".dll", ".dylib", ".so"])
        var files: [SteamEngineAssetInventory.File] = [], seen = Set<String>(), pathBytes = 0, total: UInt64 = 0, maximum: UInt64 = 0
        for value in draft.files {
            guard (try? Self.normalizedRelativePath(value.logicalPath)) == value.logicalPath,
                  value.manifestPath == "assets/" + value.logicalPath,
                  manifestKeys.contains("\(value.depotID):\(value.manifestID)"),
                  Self.isLowerHex(value.sha1, count: 40), categories.contains(value.category),
                  let size = Self.decimal(value.sizeBytes), size <= 2 * 1024 * 1024 * 1024,
                  seen.insert("\(value.depotID):\(value.manifestID):\(value.manifestPath)").inserted else { throw SteamContentBrokerError.protocolViolation }
            let extValue = URL(fileURLWithPath: value.manifestPath).pathExtension.lowercased()
            let ext = extValue.isEmpty ? "(none)" : "." + extValue
            let parts = value.logicalPath.split(separator: "/", omittingEmptySubsequences: false)
            let category = parts.count == 1 ? "assets-root" : categories.contains(String(parts[0])) ? String(parts[0]) : "other-assets"
            guard value.extension == ext, value.category == category, !forbidden.contains(ext), value.archiveCandidate == (ext == ".pkg"),
                  total <= UInt64.max - size else { throw SteamContentBrokerError.protocolViolation }
            total += size; maximum = max(maximum, size); pathBytes += value.manifestPath.utf8.count
            guard pathBytes <= 4 * 1024 * 1024 else { throw SteamContentBrokerError.protocolViolation }
            files.append(.init(logicalPath: value.logicalPath, manifestPath: value.manifestPath, depotID: value.depotID,
                manifestID: UInt64(value.manifestID)!, sizeBytes: size, sha1: value.sha1, category: value.category,
                extension: value.extension, archiveCandidate: value.archiveCandidate))
        }
        guard files == files.sorted(by: { $0.manifestPath == $1.manifestPath ? ($0.depotID == $1.depotID ? $0.manifestID < $1.manifestID : $0.depotID < $1.depotID) : $0.manifestPath < $1.manifestPath }),
              total == declaredTotal, maximum == declaredMaximum else { throw SteamContentBrokerError.protocolViolation }
        func groups(_ input: [ContentInventoryGroup], by key: (SteamEngineAssetInventory.File) -> String) throws -> [SteamEngineAssetInventory.Group] {
            var result: [SteamEngineAssetInventory.Group] = [], names = Set<String>()
            for value in input {
                guard !value.category.isEmpty, names.insert(value.category).inserted, value.fileCount > 0,
                      let bytes = Self.decimal(value.totalBytes), let maxBytes = Self.decimal(value.maximumFileBytes) else { throw SteamContentBrokerError.protocolViolation }
                result.append(.init(category: value.category, fileCount: value.fileCount, totalBytes: bytes, maximumFileBytes: maxBytes))
            }
            guard result == result.sorted(by: { $0.category < $1.category }) else { throw SteamContentBrokerError.protocolViolation }
            let actual = Dictionary(grouping: files, by: key).map { SteamEngineAssetInventory.Group(category: $0.key,
                fileCount: $0.value.count, totalBytes: $0.value.reduce(0) { $0 + $1.sizeBytes }, maximumFileBytes: $0.value.map(\.sizeBytes).max() ?? 0) }.sorted { $0.category < $1.category }
            guard result == actual else { throw SteamContentBrokerError.protocolViolation }; return result
        }
        let publicGroups = try groups(draft.groups, by: { $0.category })
        let publicExtensions = try groups(draft.extensions, by: { $0.extension })
        var canonical = "gw-engine-inventory-v1\n"
        for m in manifests { canonical += "m\0\(m.depotID)\0\(m.manifestID)\n" }
        for f in files { canonical += "f\0\(f.logicalPath)\0\(f.manifestPath)\0\(f.depotID)\0\(f.manifestID)\0\(f.sizeBytes)\0\(f.sha1)\0\(f.category)\0\(f.extension)\0\(f.archiveCandidate ? "1" : "0")\n" }
        for g in publicGroups { canonical += "g\0\(g.category)\0\(g.fileCount)\0\(g.totalBytes)\0\(g.maximumFileBytes)\n" }
        for g in publicExtensions { canonical += "x\0\(g.category)\0\(g.fileCount)\0\(g.totalBytes)\0\(g.maximumFileBytes)\n" }
        canonical += "e\0\(draft.excludedExecutableCount)\0\(excludedBytes)\n"
        let computed = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        guard computed == reportSHA256 else { throw SteamContentBrokerError.protocolViolation }
        return .init(complete: true, manifests: manifests, files: files, groups: publicGroups, extensions: publicExtensions,
            totalFileCount: files.count, totalBytes: total, maximumFileBytes: maximum,
            excludedExecutableCount: draft.excludedExecutableCount, excludedExecutableBytes: excludedBytes, reportSHA256: reportSHA256)
    }
    private static func allowedInspectionPath(_ path: String) -> Bool {
        guard (try? normalizedRelativePath(path)) == path else { return false }
        let lower = path.lowercased()
        return lower.hasPrefix("assets/materials/particle/") || lower.hasPrefix("assets/materials/util/") ||
            lower.hasPrefix("assets/materials/gradient/") || lower.hasPrefix("assets/shaders/") ||
            lower == "assets/fonts/alcubierre.otf" ||
            (lower.hasSuffix(".pkg") && (lower.contains("asset") || lower.contains("shader")))
    }
    private static func decimal(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value), String(number) == value else { return nil }
        return number
    }
    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func updateProgress(_ next: SteamContentProgress) throws {
        guard (progress.logicalTotalBytes == 0 || next.logicalTotalBytes == progress.logicalTotalBytes),
              next.receivedPayloadBytes >= progress.receivedPayloadBytes,
              next.downloadedVerifiedBytes >= progress.downloadedVerifiedBytes,
              next.reusedVerifiedBytes >= progress.reusedVerifiedBytes,
              next.successfulCompressedPayloadBytes >= progress.successfulCompressedPayloadBytes else { throw SteamContentBrokerError.protocolViolation }
        progress = next; progressHandler?(next)
    }
    private func contentURL(_ relative: String) throws -> URL {
        guard let job = downloadIdentity, let manifest else { throw SteamContentBrokerError.protocolViolation }
        let expected = "items/\(job.item)/\(manifest.id)/content"
        guard relative == expected else { throw SteamContentBrokerError.protocolViolation }
        let url = workspaceURL.appendingPathComponent(relative, isDirectory: true)
        guard url.path == Self.realPath(url),
              url.path.hasPrefix(workspaceURL.path + "/"),
              (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { throw SteamContentBrokerError.protocolViolation }
        return url
    }
    private func validateEngineCache(relative: String, identity: SteamEngineAssetManifestIdentity,
                                     files: [SteamEngineAssetFile]) throws -> URL {
        guard relative == "engine-assets/\(identity.sha256)/content",
              (try? Self.normalizedRelativePath(relative)) == relative else { throw SteamContentBrokerError.protocolViolation }
        let rootFD = Darwin.open(workspaceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SteamContentBrokerError.protocolViolation }
        defer { Darwin.close(rootFD) }
        let contentFD = try Self.openPrivateDirectory(rootFD, relative: relative)
        defer { Darwin.close(contentFD) }
        for file in files {
            let fd = try Self.openOwnedFile(contentFD, relative: file.relativePath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_size >= 0, UInt64(info.st_size) == file.sizeBytes,
                  file.sizeBytes <= 64 * 1024 * 1024 else { try? handle.close(); throw SteamContentBrokerError.protocolViolation }
            let data = try handle.readToEnd() ?? Data()
            guard UInt64(data.count) == file.sizeBytes else { throw SteamContentBrokerError.protocolViolation }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else { throw SteamContentBrokerError.protocolViolation }
        }
        let url = workspaceURL.appendingPathComponent(relative, isDirectory: true)
        guard url.path == Self.realPath(url), url.path.hasPrefix(workspaceURL.path + "/") else { throw SteamContentBrokerError.protocolViolation }
        return url
    }
    private func validateRuntimeCache(relative: String, identity: SteamEngineAssetManifestIdentity,
                                      files: [SteamEngineAssetFile]) throws -> URL {
        guard relative == "scene-runtime-assets/\(identity.sha256)/content",
              (try? Self.normalizedRelativePath(relative)) == relative else { throw SteamContentBrokerError.protocolViolation }
        let rootFD = Darwin.open(workspaceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SteamContentBrokerError.protocolViolation }
        defer { Darwin.close(rootFD) }
        let contentFD = try Self.openPrivateDirectory(rootFD, relative: relative)
        defer { Darwin.close(contentFD) }
        for file in files {
            let fd = try Self.openOwnedFile(contentFD, relative: file.relativePath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_size >= 0, UInt64(info.st_size) == file.sizeBytes, file.sizeBytes <= 16 * 1024 * 1024 else {
                try? handle.close(); throw SteamContentBrokerError.protocolViolation
            }
            let data = try handle.readToEnd() ?? Data()
            guard UInt64(data.count) == file.sizeBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw SteamContentBrokerError.protocolViolation }
        }
        let url = workspaceURL.appendingPathComponent(relative, isDirectory: true)
        guard url.path == Self.realPath(url), url.path.hasPrefix(workspaceURL.path + "/") else { throw SteamContentBrokerError.protocolViolation }
        return url
    }
    private static func normalizedRelativePath(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1024, !value.hasPrefix("/"), !value.hasPrefix("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.precomposedStringWithCanonicalMapping == value else { throw SteamContentBrokerError.protocolViolation }
        let parts = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 200 &&
            !$0.contains(":") && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }) else { throw SteamContentBrokerError.protocolViolation }
        return parts.joined(separator: "/")
    }
    private static func openPrivateDirectory(_ parent: Int32, relative: String) throws -> Int32 {
        let path = try normalizedRelativePath(relative); var current = Darwin.openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw SteamContentBrokerError.protocolViolation }
        do {
            for component in path.split(separator: "/") {
                let next = component.withCString { Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
                guard next >= 0 else { throw SteamContentBrokerError.protocolViolation }
                Darwin.close(current); current = next
                var info = stat()
                guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                      info.st_mode & 0o077 == 0 else { throw SteamContentBrokerError.protocolViolation }
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    private static func openOwnedFile(_ parent: Int32, relative: String) throws -> Int32 {
        let path = try normalizedRelativePath(relative), parts = path.split(separator: "/").map(String.init)
        var directory = Darwin.openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SteamContentBrokerError.protocolViolation }
        defer { Darwin.close(directory) }
        for component in parts.dropLast() {
            let next = component.withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard next >= 0 else { throw SteamContentBrokerError.protocolViolation }
            Darwin.close(directory); directory = next
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  info.st_mode & 0o077 == 0 else { throw SteamContentBrokerError.protocolViolation }
        }
        let fd = parts.last!.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw SteamContentBrokerError.protocolViolation }
        return fd
    }
    private static let publicFailureCodes: Set<String> = [
        "app_token_denied",
        "appinfo_depots_missing",
        "appinfo_http_delivery_not_supported",
        "appinfo_not_available",
        "auth_adapter_not_authenticated",
        "auth_challenge_state",
        "auth_request_missing",
        "busy",
        "cancelled",
        "cdn_auth_denied",
        "cdn_context_missing",
        "cdn_directory_denied",
        "cdn_directory_cm_failed",
        "cdn_directory_public_failed",
        "cdn_auth_failed",
        "manifest_protocol_failed",
        "chunk_protocol_failed",
        "chunk_download_failed",
        "proxy_auth_required",
        "proxy_connect_failed",
        "proxy_connect_boundary",
        "cdn_directory_limit",
        "cdn_sdk_adapter_contract",
        "cdn_request_outside_authorized_scope",
        "cdn_response_limit",
        "cdn_server_mutated",
        "cdn_servers_not_authorized",
        "checkpoint_write_failed",
        "chunk_outside_authorized_manifest",
        "command_not_available",
        "content_transfer_failed",
        "depot_key_denied",
        "downloaded_chunk_hash_mismatch",
        "existing_content_length_changed",
        "engine_asset_cache_invalid",
        "engine_asset_cache_limit",
        "engine_asset_destination_invalid",
        "engine_asset_inspection_limit",
        "engine_inventory_incomplete",
        "engine_inventory_limit",
        "engine_inventory_manifest_invalid",
        "scene_runtime_manifest_ambiguous",
        "scene_runtime_manifest_incomplete",
        "scene_runtime_manifest_invalid",
        "scene_runtime_manifest_limit",
        "engine_asset_selection_invalid",
        "engine_asset_size_limit",
        "engine_assets_not_found",
        "engine_depot_key_denied",
        "final_content_tree_mismatch",
        "final_file_hash",
        "final_file_length",
        "final_file_truncated",
        "invalid_auth_request",
        "invalid_download_request",
        "invalid_engine_asset_request",
        "invalid_engine_inventory_request",
        "invalid_scene_runtime_asset_request",
        "invalid_envelope",
        "invalid_json",
        "invalid_plan",
        "invalid_published_file_id",
        "invalid_qr_challenge",
        "legacy_ugc_http_not_supported",
        "managed_directory_not_private_or_link",
        "managed_file_not_owned_regular",
        "manifest_access_denied",
        "manifest_chunk_coverage",
        "manifest_chunk_invalid",
        "manifest_directory_data",
        "manifest_download_failed",
        "manifest_duplicate_or_link",
        "manifest_file_invalid",
        "manifest_file_parent",
        "manifest_identity_or_limit",
        "manifest_no_files",
        "manifest_path_invalid",
        "manifest_section_bounds",
        "manifest_session_mismatch",
        "manifest_size_limit",
        "manifest_tree_limit",
        "manifest_zip_length",
        "manifest_zip_limit",
        "no_supported_https_cdn",
        "session_busy",
        "session_closing",
        "session_job_limit",
        "session_not_authenticated",
        "stale_epoch",
        "stale_job",
        "stale_or_invalid_auth_response",
        "stale_session",
        "steam_auth_failed",
        "steam_auth_timeout",
        "steam_content_failed",
        "steam_disconnected",
        "steam_identity_missing",
        "ugc_collection_or_filetype_not_supported",
        "ugc_lookup_failed",
        "ugc_manifest_missing",
        "ugc_not_authorized_or_wrong_item",
        "workshop_depot_invalid",
        "workspace_not_private_canonical_directory",
    ]
    private func rejection(_ code: String?) -> SteamContentBrokerError {
        guard let code else { return .helperRejected("steam_content_failed") }
        if Self.publicFailureCodes.contains(code) { return .helperRejected(code) }
        let runtimeParts = code.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        if runtimeParts.count == 4, runtimeParts[0] == "scene", runtimeParts[1] == "runtime",
           ["transfer", "checkpoint", "validation"].contains(runtimeParts[2]),
           ["access", "io", "disposed", "state", "argument", "crypto", "memory", "unexpected"].contains(runtimeParts[3]) {
            return .helperRejected(code)
        }
        if code.hasPrefix("steam_logon_"), let n = UInt16(code.dropFirst("steam_logon_".count)), n <= 999,
           code == "steam_logon_" + String(n) { return .helperRejected(code) }
        return .helperRejected("steam_content_failed")
    }
}
