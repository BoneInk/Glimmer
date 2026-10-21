import Foundation
import Darwin

/// Original local pipe peer, never a Steam service mock claimed as live acceptance.
@main @MainActor enum SteamContentQueueIntegrationTests {
    struct Failure: Error { let text: String }
    static let fm = FileManager.default
    static var checks = 0
    actor MemorySessionStore: SteamContentSessionStoring {
        var saved: SteamContentSavedSession?
        init(_ saved: SteamContentSavedSession? = nil) { self.saved = saved }
        func load() async throws -> SteamContentSavedSession? { saved }
        func save(_ session: SteamContentSavedSession) async throws { saved = session }
        func delete() async throws { saved = nil }
    }
    static func check(_ value: Bool, _ text: String) throws {
        guard value else { throw Failure(text: text) }
        checks += 1; print("PASS \(text)")
    }
    static func wait(_ text: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<800 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw Failure(text: "timeout: " + text)
    }
    static func child(_ root: URL) throws {
        let nonce = UUID().uuidString, session = UUID().uuidString.lowercased()
        var seq = 0, held: [String: Any]?
        func emit(_ kind: String, _ request: String, _ detail: [String: Any] = [:], _ identity: [String: Any]? = nil) throws {
            seq += 1
            var event: [String: Any] = ["v": 1, "sessionNonce": nonce, "seq": seq, "kind": kind, "requestID": request, "detail": detail]
            if let identity {
                event["jobID"] = identity["jobID"]; event["epoch"] = String(describing: identity["epoch"]!)
                event["publishedFileID"] = identity["publishedFileID"]; event["appID"] = 431960
                event["manifestID"] = kind == "resolving" ? "0" : "99"; event["depotID"] = kind == "resolving" ? 0 : 431960
            }
            var data = try JSONSerialization.data(withJSONObject: event); data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        func counters(_ downloaded: String, reused: String = "0") -> [String: String] {
            let received = downloaded == "0" ? "0" : downloaded == "2048" && reused == "0" ? "1024" : "3072"
            return ["logicalTotalBytes": "4096", "receivedPayloadBytes": received, "downloadedVerifiedBytes": downloaded, "reusedVerifiedBytes": reused, "successfulCompressedPayloadBytes": downloaded == "0" ? "0" : downloaded == "2048" && reused == "0" ? "1024" : "2048"]
        }
        try String(getpid()).write(to: root.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try emit("ready", "startup", ["productionAuthentication": true, "productionWorkshopDownload": true, "productionEngineAssets": true])
        while let line = readLine() {
            let cmd = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let request = cmd["requestID"] as! String
            switch cmd["commandName"] as? String {
            case "login":
                let method = ((cmd["auth"] as? [String: Any])?["method"] as? String) ?? "missing"
                let authHistory = root.appendingPathComponent("auth-methods")
                let prior = (try? String(contentsOf: authHistory, encoding: .utf8)) ?? ""
                try (prior + method + "\n").write(to: authHistory, atomically: true, encoding: .utf8)
                try emit("auth_started", request, ["sessionID": session])
                if method == "refresh", fm.fileExists(atPath: root.appendingPathComponent("cancel-recovery-partial").path) { continue }
                try emit("auth_result", request, ["sessionID": session, "accountName": "fixture_user", "steamID": "76561190000000000", "refreshToken": "fixture_memory_token"])
            case "download":
                try emit("resolving", request, ["sessionID": session], cmd)
                try emit("started", request, ["sessionID": session], cmd)
                let item = cmd["publishedFileID"] as! String
                let lostMarker = root.appendingPathComponent("lost-once-partial")
                if item == "10", !fm.fileExists(atPath: lostMarker.path) {
                    try emit("progress", request, counters("2048"), cmd)
                    try Data("same-workspace-partial".utf8).write(to: lostMarker)
                    try emit("failed", request, ["reason": "steam_disconnected", "counters": counters("2048")], cmd)
                    continue
                }
                if item == "11" {
                    let marker = root.appendingPathComponent("cancel-recovery-partial")
                    guard !fm.fileExists(atPath: marker.path) else { throw Failure(text: "cancelled recovery started another download") }
                    try emit("progress", request, counters("2048"), cmd)
                    try Data("partial".utf8).write(to: marker)
                    try emit("failed", request, ["reason": "steam_disconnected", "counters": counters("2048")], cmd)
                    continue
                }
                if item == "10" {
                    guard ((cmd["sessionID"] as? String) == session), fm.fileExists(atPath: lostMarker.path) else { throw Failure(text: "resume lost workspace/session") }
                    try emit("progress", request, counters("0", reused: "2048"), cmd)
                } else { try emit("progress", request, counters("2048"), cmd) }
                if item == "8" { held = cmd; continue }
                Thread.sleep(forTimeInterval: 0.16)
                let content = root.appendingPathComponent("items/\(item)/99/content")
                try fm.createDirectory(at: content, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("{\"type\":\"web\",\"file\":\"index.html\",\"title\":\"Pipe integration\"}".utf8).write(to: content.appendingPathComponent("project.json"))
                try Data("<!doctype html><title>Original fixture</title><p>Wallpaper</p>".utf8).write(to: content.appendingPathComponent("index.html"))
                let complete = item == "10" ? counters("2048", reused: "2048") : counters("4096")
                try emit("transfer_complete", request, ["sessionID": session, "counters": complete, "contentRelativePath": "items/\(item)/99/content", "planFingerprint": String(repeating: "a", count: 64), "validationRequired": true], cmd)
            case "cancel":
                guard let held else { throw Failure(text: "cancel without owned transfer") }
                try emit("cancel_requested", request, [:], held)
                Thread.sleep(forTimeInterval: 0.1)
                try Data("closed".utf8).write(to: root.appendingPathComponent("drained"))
                try emit("cancelled", held["requestID"] as! String, counters("2048"), held)
            case "shutdown": try emit("stopped", request); return
            case "logout", "auth_cancel": try emit("logged_out", request, ["sessionID": session])
            default: throw Failure(text: "unexpected fixture command")
            }
        }
    }
    static func run(_ root: URL) async throws {
        func inspection(_ diagnostics: [SceneDiagnostic]) -> SceneWallpaperInspection {
            .init(canvasSize: .init(x: 16, y: 16), clearColor: .init(x: 0, y: 0, z: 0),
                  layers: [], textures: [:], diagnostics: diagnostics)
        }
        let halo = "materials/particle/halo.tex"
        let typedMissing = inspection([.init(severity: .missing, path: halo, message: "arbitrary localized text")])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for: typedMissing) == [halo],
                  "typed allowlisted missing dependency authorizes only the fixed Scene resource recovery path")
        let font = SteamContentBroker.sceneFontEngineAssetResource
        let missingFont = inspection([.init(severity:.missing,path:font,message:"missing")])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for:missingFont) == [font],
                  "typed exact builtin font dependency authorizes the fixed complete engine bundle recovery path")
        let optionalShader = inspection([.init(severity:.missing,path:"shaders/common_blending.h",message:"missing")])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for:optionalShader) == nil,
                  "optional inspection-only shader metadata cannot authorize an engine download")
        let unsupported = inspection([.init(severity: .unsupported, path: halo, message: "missing-looking message")])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for: unsupported) == nil,
                  "unsupported Scene capability cannot trigger engine resource download even when its text looks missing")
        let outside = inspection([.init(severity: .missing, path: "materials/author/private.tex", message: "missing")])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for: outside) == nil,
                  "author or unknown missing paths cannot expand the engine resource allowlist")
        let mixed = inspection([
            .init(severity: .missing, path: halo, message: "missing"),
            .init(severity: .invalid, path: "scene.json", message: "invalid graph")
        ])
        try check(WorkshopCoordinator.requiredSceneEngineResources(for: mixed) == nil,
                  "mixed invalid diagnostics fail closed instead of hiding a broken Scene behind asset recovery")

        let directWeb = root.appendingPathComponent("direct-web")
        try fm.createDirectory(at: directWeb, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: directWeb.appendingPathComponent("project.json"))
        try Data("<!doctype html><title>complete</title>".utf8).write(to: directWeb.appendingPathComponent("index.html"))
        let webItem = WorkshopDownloadItem(publishedFileID: "101", title: "Web", kind: .web,
            declaredTags: ["Web"], previewImageURLString: nil, fileSizeBytes: nil)
        try check(try await WorkshopCoordinator.sceneProjectRequiringBuiltinAssets(contentURL: directWeb, item: webItem) == nil,
                  "complete Web content bypasses Scene engine recovery")

        let directScene = root.appendingPathComponent("direct-scene")
        let completeSceneFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SceneScriptWallpaper")
        try fm.copyItem(at: completeSceneFixture, to: directScene)
        let sceneItem = WorkshopDownloadItem(publishedFileID: "102", title: "Scene", kind: .scene,
            declaredTags: ["Scene"], previewImageURLString: nil, fileSizeBytes: nil)
        try check(try await WorkshopCoordinator.sceneProjectRequiringBuiltinAssets(contentURL: directScene, item: sceneItem) == nil,
                  "complete self-contained Scene content bypasses engine recovery")

        let missingScene = root.appendingPathComponent("missing-engine-scene")
        try fm.copyItem(at: completeSceneFixture, to: missingScene)
        let missingMaterial = try JSONSerialization.data(withJSONObject: [
            "passes": [["shader": "genericimage2", "blending": "translucent", "textures": ["particle/halo"]]]
        ], options: [.sortedKeys])
        try missingMaterial.write(to: missingScene.appendingPathComponent("materials/background.json"))
        let missingProject = missingScene.appendingPathComponent("project.json")
        let candidate = try await WorkshopCoordinator.sceneProjectRequiringBuiltinAssets(
            contentURL: missingScene,
            item: sceneItem,
            resolveProject: { _, _, _ in
                throw WorkshopDownloadError.validationFailed(reason: "fixture project needs an engine texture")
            },
            inspectProject: { _ in typedMissing },
            resolveAvailableAssets: { _ in .init(inspection: typedMissing, engineAssets: nil) }
        )
        try check(candidate == missingProject,
                  "project-only typed inspection selects a Scene missing an allowlisted builtin when no verified cache satisfies it")

        var meter = SteamContentTransferPresentation(now: 0)
        let initial = SteamContentProgress(logicalTotalBytes: 4096, receivedPayloadBytes: 1024,
                                          downloadedVerifiedBytes: 1024, reusedVerifiedBytes: 1024, successfulCompressedPayloadBytes: 512)
        if case .downloading(let value, let text) = meter.state(for: initial, now: 0) {
            try check(value == 0.5 && text.contains("/"), "presentation fraction includes validated reused bytes against logical total")
        } else { throw Failure(text: "missing initial measured state") }
        let retried = SteamContentProgress(logicalTotalBytes: 4096, receivedPayloadBytes: 8192,
                                          downloadedVerifiedBytes: 1024, reusedVerifiedBytes: 1024, successfulCompressedPayloadBytes: 512)
        if case .downloading(let value, let text) = meter.state(for: retried, now: 1) {
            try check(value == 0.5 && text.contains("/s"), "retry-inclusive wire speed never advances verified percentage")
        } else { throw Failure(text: "missing rate state") }
        let layout = SteamCMDLayout(root: root.appendingPathComponent("Workshop/SteamCMD"))
        try fm.createDirectory(at: layout.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let savedStore = MemorySessionStore()
        let account = SteamAccountManager(layout: layout, nativeContentExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]), sessionStore: savedStore)
        account.rememberedUsername = "fixture_user"; account.startNativeSignIn(); account.submitPassword("fixture_password")
        try await wait("native actual ACK") { account.isNativeContentReady }
        try check(!account.isReady && account.isNativeContentReady, "native ACK permits download without SteamCMD installed")
        let queueURL = root.appendingPathComponent("Workshop/download-queue.json")
        let c = WorkshopCoordinator(account: account, queuePersistence: .file(queueURL))
        await c.loadDownloadQueueIfNeeded()
        var imported: WorkshopResolvedProject?, metadata: WorkshopMetadata?
        c.onImportProject = { p, m in imported = p; metadata = m; return nil }
        var observedHalf = false, observedValidation = false
        let first = WorkshopDownloadItem(publishedFileID: "7", title: "Original fixture", kind: .web, declaredTags: [], previewImageURLString: nil, fileSizeBytes: nil)
        c.enqueueDownload(first)
        for _ in 0..<1000 {
            if case .downloading(let fraction, let text) = c.downloadProgress.items.first?.state {
                if fraction == 0.5 && !text.isEmpty { observedHalf = true }
            }
            if case .validating = c.downloadProgress.items.first?.state { observedValidation = true }
            if c.downloadProgress.items.first?.state == .completed && imported != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try check(observedHalf, "coordinator publishes measured50percent from verified bytes through real child pipe")
        try check(c.downloadProgress.items.first?.state == .completed && imported?.projectType == "web", "actual resolver and delivery precede completed native queue state")
        try check(imported?.projectRoot.resolvingSymlinksInPath().path == layout.downloadDirectory(for: WorkshopItemID("7")!).resolvingSymlinksInPath().path && metadata?.publishedFileID == "7", "normal project importer receives promoted managed path and matching metadata")
        try check(c.importedItemIDs.contains("7") && c.downloadProgress.items.first?.progressFraction == nil, "import ACK updates downloaded badge and removes completed progress")
        let broker = account.nativeContentBroker!
        let workspace = broker.workspaceURL
        try check(!fm.fileExists(atPath: workspace.appendingPathComponent("items/7/99/content/glimmer-download.json").path), "host manifest never pollutes strict helper content tree")
        var recovered = first; recovered.publishedFileID = "10"; recovered.title = "Recovered fixture"
        c.enqueueDownload(recovered)
        try await wait("auth-loss recovered download") { c.downloadProgress.items.first(where: { $0.id == "10" })?.state == .completed }
        let authMethods = try String(contentsOf: workspace.appendingPathComponent("auth-methods"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try check(authMethods == ["credentials", "refresh"], "authentication loss starts exactly one saved-refresh login after the old helper drains")
        try check(fm.fileExists(atPath: workspace.appendingPathComponent("lost-once-partial").path) && account.isNativeContentReady,
                  "same workspace partial is reused after a real authenticated ACK and queue completion")
        let reloaded = WorkshopCoordinator(account: account, queuePersistence: .file(queueURL)); await reloaded.loadDownloadQueueIfNeeded()
        try check(reloaded.downloadProgress.items.first?.state == .completed, "native download survives normal downloaded-list reload and fresh project validation")
        var second = first; second.publishedFileID = "8"; second.title = "Held fixture"
        c.enqueueDownload(second)
        try await wait("partial second") { c.downloadProgress.items.last?.progressFraction == 0.5 }
        c.pauseDownload(itemID: "8")
        try check(c.downloadProgress.activeItemID == "8" && c.downloadProgress.items.last?.state == .pausing, "pause keeps active ownership until child has drained")
        try await wait("drained pause") { c.downloadProgress.items.last?.state == .paused }
        try check(fm.fileExists(atPath: workspace.appendingPathComponent("drained").path) && !broker.isDownloading, "paused state follows actual transfer terminal and stopped writes")
        c.resumeDownload(itemID: "8")
        try await wait("resumed measured partial") { broker.isDownloading && c.downloadProgress.items.last?.progressFraction == 0.5 }
        c.setDownloadQueuePaused(true)
        await c.shutdownDownloads()
        let pid = Int32(try String(contentsOf: workspace.appendingPathComponent("pid"), encoding: .utf8))!
        try check(kill(pid, 0) == -1 && errno == ESRCH && c.downloadProgress.activeItemID == nil, "quit drains resumed transfer and reaps owned session without starting queued work")
        try check(!account.isNativeContentReady, "shutdown invalidates in-memory native auth readiness")
        let cancelRoot = root.appendingPathComponent("CancelRecovery")
        let cancelLayout = SteamCMDLayout(root: cancelRoot.appendingPathComponent("Workshop/SteamCMD"))
        try fm.createDirectory(at: cancelLayout.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cancelStore = MemorySessionStore(.init(username: "fixture_user", refreshToken: "saved_fixture", guardData: nil))
        let cancelAccount = SteamAccountManager(layout: cancelLayout,
            nativeContentExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]), sessionStore: cancelStore)
        await cancelAccount.prepareForDownloads()
        try await wait("cancel fixture initial saved ACK") { cancelAccount.isNativeContentReady }
        let cancelCoordinator = WorkshopCoordinator(account: cancelAccount, queuePersistence: .disabled)
        var cancelledRecovery = first; cancelledRecovery.publishedFileID = "11"; cancelledRecovery.title = "Cancel recovery fixture"
        cancelCoordinator.enqueueDownload(cancelledRecovery)
        try await wait("saved recovery awaiting ACK") { cancelAccount.loginState == .loggingIn }
        let cancelWorkspace = cancelRoot.appendingPathComponent("Workshop/SteamContent")
        try await wait("fixture observed recovery login command") {
            let methods = (try? String(contentsOf: cancelWorkspace.appendingPathComponent("auth-methods"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            return methods == ["refresh", "refresh"]
        }
        cancelCoordinator.cancelDownload(itemID: "11")
        try await wait("cancelled recovery drained") {
            cancelCoordinator.downloadProgress.items.first?.state == .cancelled && !cancelAccount.isNativeContentCleaningUp
        }
        let beforeWait = try String(contentsOf: cancelWorkspace.appendingPathComponent("auth-methods"), encoding: .utf8)
        try await Task.sleep(for: .milliseconds(80))
        let afterWait = try String(contentsOf: cancelWorkspace.appendingPathComponent("auth-methods"), encoding: .utf8)
        let beforeMethods = beforeWait.split(separator: "\n").map(String.init)
        let afterMethods = afterWait.split(separator: "\n").map(String.init)
        let methodsStable = beforeWait == afterWait
        let exactlyInitialAndRecovery = beforeMethods == ["refresh", "refresh"]
        let remainedNotReady = !cancelAccount.isNativeContentReady
        print("DIAG cancel-recovery stable=\(methodsStable) beforeMethods=\(beforeMethods) afterMethods=\(afterMethods) notReady=\(remainedNotReady) cleanup=\(cancelAccount.isNativeContentCleaningUp) loginActive=\(cancelAccount.loginState.isActive)")
        try check(methodsStable, "user cancellation starts no later authentication attempt")
        try check(exactlyInitialAndRecovery, "fixture observes exactly initial and recovery refresh authentication")
        try check(remainedNotReady, "cancelled recovery never republishes native readiness")
        await cancelCoordinator.shutdownDownloads()
        let actualProject = imported!
        let heldImport = WorkshopCoordinator(account: account, downloadPreflight: { nil },
            contentDownloadOperation: { _, _, _, _ in actualProject }, queuePersistence: .disabled)
        var importGate: CheckedContinuation<Void, Never>?
        var importFinished = false, shutdownFinished = false
        heldImport.onImportProject = { _, _ in
            await withCheckedContinuation { importGate = $0 }
            importFinished = true
            return nil
        }
        var third = first; third.publishedFileID = "9"
        heldImport.enqueueDownload(third)
        try await wait("import callback entered") { importGate != nil }
        let quit = Task { await heldImport.shutdownDownloads(); shutdownFinished = true }
        try await Task.sleep(for: .milliseconds(30))
        try check(!shutdownFinished && heldImport.hasDownloadLifecycleWork, "quit remains pending after transfer while actual auto-import callback is unfinished")
        importGate?.resume(); importGate = nil
        await quit.value
        try check(importFinished && shutdownFinished && !heldImport.hasDownloadLifecycleWork && heldImport.importedItemIDs.contains("9"), "quit completes only after import ACK and lifecycle task release")
        _ = observedValidation // Transient native validation is covered by delivery's dedicated real-file tests.
    }
    static func main() async {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--workspace-root" {
            do { try child(URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) } catch { exit(93) }
        }
        let root = fm.temporaryDirectory.appendingPathComponent("SteamContentQueue-\(UUID().uuidString)").resolvingSymlinksInPath()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: root) }
            try await run(root); print("RESULT \(checks) passed; actual Steam acceptance not performed")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
