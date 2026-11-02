import AppKit
import Foundation

@main
struct LockScreenConnectionRecoveryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glimmer-connection-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Index.plist")
        let provider = "test.glimmer.provider"
        var children: [Process] = []
        var reloads = 0
        var awake = true
        var passed = 0
        func select(_ active: String) throws {
            let value: [String: Any] = [
                "AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [["Provider": active]]]]],
                "SystemDefault": ["Desktop": ["Content": ["Choices": [["Provider": provider]]]]]]
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: store)
        }
        func spawn() throws -> Process {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
            try child.run(); children.append(child); return child
        }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: " + message) }
            passed += 1; print("PASS: " + message)
        }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<80 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { children.filter(\.isRunning).forEach { $0.terminate() } }
        try select(provider)
        let first = try spawn()
        let recovery = LockScreenConnectionRecovery(
            executable: URL(fileURLWithPath: "/bin/sleep"), storeURL: store, provider: provider,
            canRecover: { awake }, reloadHost: { reloads += 1; _ = try spawn() },
            discover: { children.filter(\.isRunning).map(\.processIdentifier) },
            recoveryDelay: .milliseconds(50), settleDelay: .milliseconds(50), cooldown: 0)
        defer { recovery.stop() }
        recovery.start(observeSystemEvents: false)
        recovery.start(observeSystemEvents: false)
        check(recovery.watchedPIDs == [first.processIdentifier], "start watches existing process once")
        let unrelatedReplacement = try spawn()
        recovery.refresh()
        first.terminate()
        await wait { reloads == 1 && !recovery.watchedPIDs.isEmpty }
        check(reloads == 1 && !recovery.watchedPIDs.contains(first.processIdentifier), "real process exit automatically restores and watches replacement")
        check(reloads == 1 && recovery.watchedPIDs.contains(unrelatedReplacement.processIdentifier), "an existing replacement process does not hide the old dead connection")
        recovery.refresh(); recovery.refresh()
        try await Task.sleep(for: .milliseconds(120))
        check(reloads == 1, "healthy lock and wake events do not reload host")
        awake = false
        children.last!.terminate()
        try await Task.sleep(for: .milliseconds(200))
        check(reloads == 1, "sleep defers recovery without timers or reloads")
        awake = true; recovery.refresh()
        await wait { reloads == 2 && !recovery.watchedPIDs.isEmpty }
        check(reloads == 2 && !recovery.watchedPIDs.isEmpty, "wake recovers a connection lost during sleep")
        try select("other.provider")
        children.last!.terminate(); recovery.refresh()
        try await Task.sleep(for: .milliseconds(150))
        check(reloads == 2 && recovery.watchedPIDs.isEmpty, "stale SystemDefault does not override a new wallpaper selection")
        try select(provider)
        recovery.refresh(); recovery.stop()
        try await Task.sleep(for: .milliseconds(150))
        check(reloads == 2 && recovery.watchedPIDs.isEmpty, "shutdown cancels pending recovery and releases process watches")

        let existing = try spawn()
        let discovery = LockScreenConnectionRecovery(
            executable: URL(fileURLWithPath: "/bin/sleep"), storeURL: store, provider: provider,
            canRecover: { false }, reloadHost: { fatalError("discovery must not reload") })
        discovery.start(observeSystemEvents: false)
        check(discovery.watchedPIDs.contains(existing.processIdentifier), "production libproc discovery finds exact owned executable")
        discovery.stop()
        var cooledChildren: [Process] = []
        var cooledReloads = 0
        let cooled = LockScreenConnectionRecovery(
            executable: URL(fileURLWithPath: "/bin/sleep"), storeURL: store, provider: provider,
            canRecover: { true }, reloadHost: {
                cooledReloads += 1
                cooledChildren.append(try spawn())
            }, discover: { cooledChildren.filter(\.isRunning).map(\.processIdentifier) },
            recoveryDelay: .milliseconds(10), settleDelay: .milliseconds(10), cooldown: 0.3)
        cooled.start(observeSystemEvents: false)
        await wait { cooledReloads == 1 && !cooled.watchedPIDs.isEmpty }
        cooledChildren.last?.terminate()
        await wait { cooledReloads == 2 && !cooled.watchedPIDs.isEmpty }
        check(cooledReloads == 2, "exit during cooldown is recovered by one deferred attempt without another event")
        cooled.stop()
        print("\(passed) checks passed; only fixture store and child processes used; no system wallpaper changes")
    }
}
