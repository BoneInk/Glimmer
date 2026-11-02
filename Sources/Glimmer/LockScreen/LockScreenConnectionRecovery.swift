import AppKit
import CoreGraphics
import Darwin
import Foundation
import os

/// WallpaperAgent can retain dead remote contexts after LaunchServices replaces
/// an extension record (including App Store's daily maintenance). Watch the
/// actual owned process and recover that connection without polling or changing
/// the user's wallpaper choice. Sleeping displays defer recovery until wake.
@MainActor
final class LockScreenConnectionRecovery {
    static let startedNotification = Notification.Name("com.boneinkzhong.glimmer.wallpaper-extension.started")
    private static let logger = Logger(subsystem: "com.boneinkzhong.glimmer", category: "LockScreenRecovery")
    private let executable: URL
    private let storeURL: URL
    private let provider: String
    private let canRecover: () -> Bool
    private let reloadHost: () async throws -> Void
    private let discover: (() -> [pid_t])?
    private let recoveryDelay: Duration
    private let settleDelay: Duration
    private let cooldown: TimeInterval
    private var processes: [pid_t: any DispatchSourceProcess] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?
    private var generation = UUID()
    private var lastRestart = -TimeInterval.infinity
    private var connectionWasLost = false
    private(set) var isStarted = false
    private(set) var recoveryCount = 0
    private(set) var lastError: String?
    var watchedPIDs: Set<pid_t> { Set(processes.keys) }

    init(executable: URL, storeURL: URL, provider: String,
         canRecover: @escaping () -> Bool,
         reloadHost: @escaping () async throws -> Void,
         discover: (() -> [pid_t])? = nil,
         recoveryDelay: Duration = .seconds(1), settleDelay: Duration = .seconds(2),
         cooldown: TimeInterval = 20) {
        self.executable = executable.standardizedFileURL
        self.storeURL = storeURL; self.provider = provider
        self.canRecover = canRecover; self.reloadHost = reloadHost; self.discover = discover
        self.recoveryDelay = recoveryDelay; self.settleDelay = settleDelay; self.cooldown = cooldown
    }

    func start(observeSystemEvents: Bool = true) {
        guard !isStarted else { return }
        isStarted = true
        if observeSystemEvents {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            let distributed = DistributedNotificationCenter.default()
            for name in [Self.startedNotification, Notification.Name("com.apple.screenIsLocked"),
                         Notification.Name("com.apple.screenIsUnlocked")] {
                distributedTokens.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
        refresh()
    }

    func stop() {
        isStarted = false; generation = UUID()
        connectionWasLost = false
        recovery?.cancel(); recovery = nil
        clearProcesses()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceTokens.removeAll(); distributedTokens.removeAll()
    }

    func refresh() {
        guard isStarted else { return }
        guard providerIsSelected else {
            generation = UUID(); recovery?.cancel(); recovery = nil
            connectionWasLost = false
            clearProcesses()
            return
        }
        let pids = currentProcesses()
        bind(pids)
        guard (pids.isEmpty || connectionWasLost), canRecover(), recovery == nil else { return }
        let ticket = generation
        recovery = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket { self.recovery = nil } }
            do {
                try await Task.sleep(for: self.recoveryDelay)
                guard !Task.isCancelled, self.isStarted, self.generation == ticket,
                      self.providerIsSelected, self.canRecover() else { return }
                let remaining = self.cooldown - (ProcessInfo.processInfo.systemUptime - self.lastRestart)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled, self.isStarted, self.generation == ticket,
                      self.providerIsSelected, self.canRecover() else { return }
                let pids = self.currentProcesses()
                if !pids.isEmpty, !self.connectionWasLost { self.bind(pids); return }
                self.lastRestart = ProcessInfo.processInfo.systemUptime
                self.clearProcesses()
                self.connectionWasLost = false
                Self.logger.notice("native wallpaper connection lost; reloading system host")
                try await self.reloadHost()
                self.recoveryCount += 1
                try await Task.sleep(for: self.settleDelay)
                guard !Task.isCancelled, self.isStarted, self.generation == ticket else { return }
                let resumed = self.currentProcesses()
                self.bind(resumed)
                self.lastError = resumed.isEmpty ? "系统尚未重新启动锁屏扩展" : nil
                if !resumed.isEmpty { Self.logger.notice("native wallpaper connection restored") }
            } catch is CancellationError { }
            catch {
                self.lastError = error.localizedDescription
                Self.logger.error("native wallpaper connection recovery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var providerIsSelected: Bool {
        guard let data = try? Data(contentsOf: storeURL), data.count <= 8 * 1024 * 1024,
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        // SystemDefault is a template; a stale template must not re-enable a
        // provider the user has since replaced on the actual displays/spaces.
        let active = ["AllSpacesAndDisplays", "Displays", "Spaces"].compactMap { store[$0] }
        return active.contains(where: containsProvider)
    }

    private func containsProvider(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String == provider { return true }
            return dictionary.values.contains(where: containsProvider)
        }
        if let array = value as? [Any] { return array.contains(where: containsProvider) }
        return false
    }

    private func currentProcesses() -> [pid_t] {
        if let discover { return discover() }
        let capacity = max(128, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        return pids.prefix(max(0, min(Int(count), capacity))).filter { pid in
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL == executable
        }
    }

    private func bind(_ pids: [pid_t]) {
        let current = Set(pids)
        for pid in Set(processes.keys).subtracting(current) { processes.removeValue(forKey: pid)?.cancel() }
        for pid in current where processes[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.processes[pid] != nil else { return }
                    self.processes.removeValue(forKey: pid)?.cancel()
                    self.connectionWasLost = true
                    Self.logger.notice("native wallpaper process exited pid=\(pid)")
                    self.refresh()
                }
            }
            processes[pid] = source
            source.activate()
        }
    }

    private func clearProcesses() {
        processes.values.forEach { $0.cancel() }
        processes.removeAll()
    }

    static var displaysAreAwake: Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }
}
