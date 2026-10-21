import AppKit
import WebKit
import Foundation

@main @MainActor
enum WebDesktopIntegrationTests {
    static var passed = 0
    static var failed = 0
    static func check(_ condition: Bool, _ title: String) {
        if condition { passed += 1; print("PASS \(title)") }
        else { failed += 1; print("FAIL \(title)") }
    }
    static func value(_ runtime: WebWallpaperRuntime, _ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runtime.webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: String(describing: result ?? "nil")) }
            }
        }
    }
    static func ready(_ session: DesktopPlaybackSession) async throws -> WebWallpaperRuntime {
        for _ in 0..<400 {
            if let runtime = session.webRuntime, runtime.state == .ready || runtime.state == .paused { return runtime }
            if let error = session.lastError { throw WebProjectError.invalid(error) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebProjectError.invalid("Web session readiness timed out")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebDesktopIntegration-\(UUID())", isDirectory: true)
            do {
                let store = VideoLibraryStore(storage: AppStorage(root: root))
                let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("project.json")
                let original = try Data(contentsOf: fixture)
                let item = try await WebWallpaperProjectImporter.importProject(fixture, store: store)
                check(item.isWebWallpaper, "import records Web renderer")
                check(item.id == VideoLibraryStore(storage: store.storage).items.first?.id, "Web record committed across restart")
                let displays = DisplayRegistry()
                guard let primary = displays.primary else { throw WebProjectError.invalid("No display") }
                let playback = DesktopPlaybackController(store: store, displayRegistry: displays, storage: store.storage, previewOnly: true)
                playback.setWallpaperFPS(24)
                check(playback.apply(item: item, to: [primary.id]) == nil, "explicit desktop apply accepts local Web")
                guard let session = playback.session(for: primary.id) else { throw WebProjectError.invalid("No session") }
                let runtime = try await ready(session)
                check(runtime.frameRateLimit == 24, "new desktop Web host inherits the global FPS cap")
                playback.setWallpaperFPS(75)
                check(runtime.frameRateLimit == 75, "live FPS change reaches the desktop Web host")
                check(session.player == nil && session.playerLayer == nil, "Web uses WebKit instead of AVPlayer")
                check(session.window == nil && session.webHostView === runtime.webView, "isolated session owns real WebKit view without desktop window")
                check(store.assignments[primary.id] == item.id, "explicit apply persists correct UUID")
                check(try await value(runtime, "document.getElementById('caption').textContent") == "AURORA", "project defaults reach actual page")
                check(session.isPlaying, "ready Web session reports playing")
                let project = try AuthorPropertyServices.project(for: item)!
                let overrides = AuthorPropertyServices.shared.store(storage: store.storage)
                try await overrides.set(.string("LIVE SETTINGS"), for: "caption", itemID: item.id, project: project)
                try await overrides.set(.number(80), for: "scale", itemID: item.id, project: project)
                let payload = try await AuthorPropertyServices.payload(item: item, storage: store.storage)
                try playback.updateAuthorProperties(payload, itemID: item.id)
                try await AuthorPropertyServices.shared.applyAndWait(payload, itemID: item.id)
                check(try await value(runtime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "native override ACK changes real DOM")
                check(try await value(runtime, "document.getElementById('orb').style.width") == "80vmin", "slider changes real page geometry")
                let second = DesktopPlaybackSession(display: primary, item: item, settings: .default,
                    appSettings: store.appSettings, previewOnly: true, authorStorage: store.storage)
                check(second.start() == nil, "second isolated Web host starts")
                var earlyValues = project.resolve(overrides: [:]).values
                earlyValues["caption"] = .string("EARLY UPDATE")
                let early = try AuthorPropertyServices.payload(project: project, values: earlyValues)
                try second.updateAuthorProperties(early)
                let secondRuntime = try await ready(second)
                check(try await value(secondRuntime, "document.getElementById('caption').textContent") == "EARLY UPDATE", "preload edit survives asynchronous initial-store read")
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).count == 2, "two same-item hosts registered")
                try await AuthorPropertyServices.shared.applyAndWait(payload, itemID: item.id)
                check(try await value(secondRuntime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "ACK updates every same-item host")
                second.tearDown()
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).count == 1, "closing second host preserves first")
                playback.pauseAll()
                try await Task.sleep(for: .milliseconds(120))
                check(!session.isPlaying, "pause updates native session state")
                check(try await value(runtime, "window.pauseState") == "1", "pause reaches authored callback")
                playback.resumeAll()
                try await Task.sleep(for: .milliseconds(120))
                check(session.isPlaying, "resume restores authored session")
                playback.applyPolicyState(isBlocked: true, displayShouldPlay: { _ in true })
                check(!session.isPlaying, "policy suspends Web session")
                try playback.updateAuthorProperties(payload, itemID: item.id)
                check(!session.isPlaying, "property changes cannot bypass power policy")
                playback.applyPolicyState(isBlocked: false, displayShouldPlay: { _ in true })
                try await Task.sleep(for: .milliseconds(120))
                check(session.isPlaying, "policy release resumes saved intent")
                let assignments = store.assignments
                playback.tearDownAll()
                check(runtime.state == .disposed, "teardown disposes WebKit runtime")
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).isEmpty, "teardown unregisters live host")
                check(store.assignments == assignments, "teardown preserves saved assignments")
                store.updateAppSettings { $0.autoApplyOnLaunch = true }
                store.flush()
                let restored = DesktopPlaybackController(store: store, displayRegistry: displays, storage: store.storage, previewOnly: true)
                restored.restoreAssignmentsIfNeeded()
                guard let restoredSession = restored.session(for: primary.id) else { throw WebProjectError.invalid("No restored session") }
                let restoredRuntime = try await ready(restoredSession)
                check(try await value(restoredRuntime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "restored desktop consumes saved author overrides")
                check(try Data(contentsOf: fixture) == original, "source project never modified")
                var broken = item; broken.filePath = root.appendingPathComponent("missing/project.json").path
                check(restored.apply(item: broken, to: [primary.id]) != nil, "invalid target reports failure")
                check(restored.session(for: primary.id) === restoredSession, "failed replacement retains working session")
                restored.clear()
                check(restoredRuntime.state == .disposed && store.assignments.isEmpty, "explicit clear releases renderer and assignment")
                print("RESULT \(passed) passed, \(failed) failed")
            } catch { failed += 1; print("FAIL integration: \(error)") }
            try? FileManager.default.removeItem(at: root)
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
    }
}
