import Darwin
import Foundation

/// What hosts this process, read once at launch: the test runner, an Xcode preview, a debugger,
/// and the isolated-state tag (`AppStorageLocation`).
///
/// It decides what may open another copy of the app. A test host may crash at any time, and a
/// copy opened through LaunchServices doesn't inherit its environment: before this, the crash
/// watcher reopened a test host that crashed as a plain, non-isolated app, which then ran on the
/// user's real Application Support and defaults.
///
/// - The crash watcher (`CrashWatcher`) runs only in the user's own launch: never under XCTest,
///   in a preview or under a debugger, and never for an isolated copy.
/// - Nothing relaunches a test or preview host (`mayRelaunch`).
/// - Every relaunch carries the isolated-state tag (`relaunchEnvironment`), so an isolated copy
///   can only open an isolated copy, under the same tag.
struct AppHostContext: Equatable, Sendable {
    /// The environment keys the test runner sets in the process it hosts tests in.
    static let testEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier",
                                      "XCTestBundlePath", "XCInjectBundleInto"]
    static let previewEnvironmentKey = "XCODE_RUNNING_FOR_PREVIEWS"

    var isTestHost: Bool
    var isPreviewHost: Bool
    var isDebugged: Bool
    /// `nil` for the user's real state.
    var isolationTag: String?

    var isIsolated: Bool { isolationTag != nil }

    /// This process, with the isolated state `AppStorageLocation.current` chose.
    static let current: AppHostContext = {
        var context = detect(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments,
                             xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                             loadedBundlePaths: Bundle.allBundles.map(\.bundlePath), isDebugged: isBeingDebugged())
        context.isolationTag = AppStorageLocation.current.isolationTag
        return context
    }()

    /// The context a process with this environment and these launch arguments runs in.
    static func detect(environment: [String: String], arguments: [String], xcTestLoaded: Bool,
                       loadedBundlePaths: [String], isDebugged: Bool) -> AppHostContext {
        let isTestHost = isTestHost(environment: environment, xcTestLoaded: xcTestLoaded, loadedBundlePaths: loadedBundlePaths)
        return AppHostContext(
            isTestHost: isTestHost, isPreviewHost: isPreviewHost(environment: environment), isDebugged: isDebugged,
            isolationTag: AppStorageLocation.isolationTag(environment: environment, arguments: arguments,
                                                          isRunningTests: isTestHost))
    }

    /// Whether Settings › Restart after crashing may start its watcher.
    func shouldWatchForCrashes(enabled: Bool) -> Bool {
        enabled && !isTestHost && !isPreviewHost && !isDebugged && !isIsolated
    }

    /// Whether this process may open a new copy of the app (a language change, a crash).
    var mayRelaunch: Bool { !isTestHost && !isPreviewHost }

    /// The environment a copy this process opens through LaunchServices gets: its own isolated
    /// state, or none.
    var relaunchEnvironment: [String: String] {
        isolationTag.map { [AppStorageLocation.environmentKey: $0] } ?? [:]
    }

    /// The test runner's process: its environment, XCTest loaded, or a test bundle injected.
    static func isTestHost(environment: [String: String], xcTestLoaded: Bool, loadedBundlePaths: [String]) -> Bool {
        if xcTestLoaded { return true }
        if testEnvironmentKeys.contains(where: { environment[$0] != nil }) { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("XCTest") == true { return true }
        return loadedBundlePaths.contains { $0.hasSuffix(".xctest") || $0.hasSuffix(".xctest/") }
    }

    static func isPreviewHost(environment: [String: String]) -> Bool {
        environment[previewEnvironmentKey] == "1"
    }

    /// Whether a debugger is attached (`P_TRACED`), e.g. a run from Xcode.
    static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}
