import Foundation
import Security

/// Whether JavaScriptCore can compile scripts in this process. On current macOS it JIT-compiles
/// only in a process signed with `com.apple.security.cs.allow-jit` (hardened runtime or not);
/// without it every script runs in its interpreter, about ten times slower (measured: a 2·10⁷
/// iteration loop takes 1.3 s interpreted, 0.11–0.14 s with the entitlement). The app's
/// entitlements grant it; unsigned test hosts (CI builds with `CODE_SIGNING_ALLOWED=NO`) don't.
enum SceneScriptJIT {
    static let entitlement = "com.apple.security.cs.allow-jit"

    /// Makes JIT-compiled loops check for the watchdog's stop. JavaScriptCore stops a script at the
    /// execution time limit by trapping it, and without polling traps a JIT-compiled empty loop
    /// (`while (true) {}`) never reaches a trap: measured with a 0.3 s limit, it ran on past 15 s;
    /// with `usePollingTraps` it stopped at 0.31 s, and a tight loop costs about 10 % more.
    /// JavaScriptCore reads its options from the environment once, when its first VM starts, so the
    /// app calls this first thing at launch (`AppMain`). An option set from outside wins.
    static func configurePollingTraps() {
        setenv("JSC_usePollingTraps", "true", SceneBackendRuntimeContext.isActive ? 1 : 0)
    }

    /// Whether this process carries the entitlement.
    static var isEnabled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }
}
