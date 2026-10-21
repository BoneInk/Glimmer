import Darwin
import Foundation
import JavaScriptCore

/// Stops script code that runs too long, like WE's "dead lock" watchdog (docs/scenescript-plan.md
/// §4.5). Uses JavaScriptCore's `JSContextGroupSetExecutionTimeLimit`, which is not in the public
/// headers, so it is resolved at runtime; when it is missing there is no watchdog and a hung script
/// stalls its wallpaper's render thread, as before.
///
/// The limit counts CPU time per native→JS entry. When it is exceeded the callback returns true and
/// JavaScriptCore throws an uncatchable termination exception out of the entry; the context stays
/// usable afterwards. Confined to the owning runtime's thread, except `fired`, which the callback
/// sets from inside the VM and which `lock` guards.
final class SceneScriptWatchdog {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

    private struct Symbols {
        let setLimit: SetLimit
        let clearLimit: ClearLimit
    }

    /// Resolved once; immutable afterwards.
    private static let symbols: Symbols? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let set = dlsym(defaultHandle, "JSContextGroupSetExecutionTimeLimit"),
              let clear = dlsym(defaultHandle, "JSContextGroupClearExecutionTimeLimit") else { return nil }
        return Symbols(setLimit: unsafeBitCast(set, to: SetLimit.self),
                       clearLimit: unsafeBitCast(clear, to: ClearLimit.self))
    }()

    /// Whether this system's JavaScriptCore has the execution time limit.
    static var isAvailable: Bool { symbols != nil }

    private let group: JSContextGroupRef
    private let lock = NSLock()
    private var firedFlag = false
    private var currentLimit: TimeInterval?

    /// nil when the private symbol is unavailable.
    init?(context: JSContext) {
        guard Self.symbols != nil, let globalContext = context.jsGlobalContextRef else { return nil }
        // Retained so clearing the limit in `deinit` never touches a freed group.
        group = JSContextGroupRetain(JSContextGetGroup(globalContext))
    }

    deinit {
        // The VM must not call back into a freed watchdog.
        if currentLimit != nil { Self.symbols?.clearLimit(group) }
        JSContextGroupRelease(group)
    }

    /// Arms the limit for the next entries. Cheap when the limit is unchanged.
    func arm(limit: TimeInterval) {
        lock.lock()
        firedFlag = false
        lock.unlock()
        guard currentLimit != limit, let symbols = Self.symbols else { return }
        currentLimit = limit
        let callback: ShouldTerminate = { _, info in
            guard let info else { return true }
            let watchdog = Unmanaged<SceneScriptWatchdog>.fromOpaque(info).takeUnretainedValue()
            watchdog.markFired()
            return true
        }
        symbols.setLimit(group, limit, callback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Whether the limit terminated script code since the last `arm`.
    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firedFlag
    }

    private func markFired() {
        lock.lock()
        firedFlag = true
        lock.unlock()
    }
}
