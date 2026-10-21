import Foundation

/// Steam 配置文件（profile）操作串行闸门。
///
/// 背景（R12）：登录、下载、能力探测、退出清理都会读写同一个应用管理目录下的
/// SteamCMD profile（`home/` 内的 loginusers.vdf、ssfn*、config/、steamcmd.log 等）。
/// 若两个 SteamCMD 进程并发访问同一 profile，会出现会话互相失效、缓存被覆盖、
/// 输出互相干扰等问题。因此本模块所有会触碰 profile 的操作都必须先取得该闸门。
///
/// 设计：
/// - 按 profile 根目录（规范化路径）分组，同一 profile 独占，不同 profile 互不影响。
/// - 先到先服务（FIFO），支持「尝试获取」（`tryAcquire`）以便 UI 做非阻塞判断。
/// - `owner` 仅用于状态展示（例如「登录」「下载 3818965540」），不含账号数据。

/// 单个 profile 的串行闸门。
actor SteamProfileGate {
    private var currentOwner: String?
    private var waiters: [Waiter] = []

    private struct Waiter {
        var owner: String
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// 当前持有者（nil 表示空闲）。
    var owner: String? { currentOwner }

    var isBusy: Bool { currentOwner != nil }

    /// 取得独占权。若已被占用则排队等待。
    ///
    /// - Returns: true 表示取得（需要调用 `release`）；false 表示等待被取消（调用方应放弃操作）。
    func acquire(owner: String) async -> Bool {
        if currentOwner == nil {
            currentOwner = owner
            return true
        }
        if Task.isCancelled { return false }
        let granted = await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: false)
                return
            }
            waiters.append(Waiter(owner: owner, continuation: continuation))
        }
        // 在队列中等待期间被取消：立刻归还闸门，避免让已取消的操作占用 profile。
        if granted, Task.isCancelled {
            release()
            return false
        }
        return granted
    }

    /// 非阻塞尝试获取（用于「另一项操作进行中」的即时提示）。
    func tryAcquire(owner: String) -> Bool {
        guard currentOwner == nil else { return false }
        currentOwner = owner
        return true
    }

    /// 释放独占权并唤醒下一个等待者（FIFO）。
    func release() {
        guard !waiters.isEmpty else {
            currentOwner = nil
            return
        }
        let next = waiters.removeFirst()
        currentOwner = next.owner
        next.continuation.resume(returning: true)
    }

    /// 以独占方式执行一段操作（自动获取/释放）。
    func withExclusiveAccess<T>(owner: String, operation: () async throws -> T) async rethrows -> T? {
        guard await acquire(owner: owner) else { return nil }
        defer { release() }
        return try await operation()
    }
}

/// 按 profile 根目录分配闸门（全局注册表）。
enum SteamProfileGateRegistry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var gates: [String: SteamProfileGate] = [:]
    }

    private static let storage = Storage()

    /// 取得某个 profile 的闸门（同一路径始终返回同一个 actor 实例）。
    static func gate(forProfileRoot root: URL) -> SteamProfileGate {
        let key = WorkshopProjectResolver.canonicalPath(root)
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let existing = storage.gates[key] { return existing }
        let gate = SteamProfileGate()
        storage.gates[key] = gate
        return gate
    }

    /// 与某个 SteamCMDLayout 关联的闸门。
    static func gate(for layout: SteamCMDLayout) -> SteamProfileGate {
        gate(forProfileRoot: layout.root)
    }
}
