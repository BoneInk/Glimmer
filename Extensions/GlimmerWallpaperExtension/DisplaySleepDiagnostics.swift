#if GW_DIAGNOSTIC_ENTRY
import AppKit
import Foundation

@MainActor
func GWDisplaySleepProbe() async -> [String: Any] {
    struct Request {
        var presentationMode = "locked"
        var activityState = "active"
        var isPreview = false
    }
    let guarder = GWLockScreenDisplaySleepGuard(interval: { 0.7 })
    let system = GWLockScreenDisplaySleepGuard()
    let never = GWLockScreenDisplaySleepGuard(interval: { 0 })
    defer { guarder.removeAll(); system.removeAll(); never.removeAll() }
    var checks: [String: Bool] = [:]
    func update(_ key: String = "first", _ request: Request = Request()) { guarder.update(key, request: GWRequest(request)) }
    update("preview", Request(isPreview: true))
    update("desktop", Request(presentationMode: "default"))
    checks["previewAndDesktopDoNotAssert"] = !guarder.assertionIsActive
    update()
    let first = guarder.diagnosticAssertionID
    checks["lockedSurfaceAcquiresNativeAssertion"] = guarder.assertionIsActive
    update("second")
    checks["displaysShareOneAssertion"] = first != nil && first == guarder.diagnosticAssertionID
    try? await Task.sleep(for: .seconds(0.2))
    guarder.remove("first")
    checks["removingOneDisplayKeepsOtherProtected"] = guarder.assertionIsActive
    update("second")
    try? await Task.sleep(for: .seconds(0.6))
    checks["repeatedUpdatesDoNotExtendDeadline"] = !guarder.assertionIsActive
    update("second")
    checks["expiredLockSessionStaysExpired"] = !guarder.assertionIsActive
    guarder.removeAll()
    update()
    update("first", Request(presentationMode: "default"))
    checks["unlockReleasesAssertion"] = !guarder.assertionIsActive
    update()
    guarder.setSleeping(true)
    checks["explicitSleepReleasesAssertion"] = !guarder.assertionIsActive
    guarder.setSleeping(false)
    checks["wakeReacquiresForVisibleLockScreen"] = guarder.assertionIsActive
    update("first", Request(activityState: "suspended"))
    checks["suspendedSurfaceReleasesAssertion"] = !guarder.assertionIsActive
    update()
    guarder.removeAll()
    checks["connectionTeardownReleasesAssertion"] = !guarder.assertionIsActive
    never.update("never-sleep", request: GWRequest(Request()))
    checks["neverSleepProfileSupported"] = never.assertionIsActive
    never.removeAll()
    checks["neverSleepProfileStillReleasesOnUnlock"] = !never.assertionIsActive
    system.update("system-profile", request: GWRequest(Request()))
    checks["systemIdleTimeoutReadableInSandbox"] = system.diagnosticSystemInterval != nil
    checks["systemProfileAcquiresNativeAssertion"] = system.assertionIsActive
    let interval = system.diagnosticSystemInterval
    system.removeAll()
    return ["sandboxActive": GWSandboxIsActive(), "checks": checks,
            "systemIdleTimeoutSeconds": interval.map { $0 as Any } ?? NSNull(),
            "passed": checks.values.allSatisfy { $0 }, "systemWallpaperModified": false]
}
#endif
