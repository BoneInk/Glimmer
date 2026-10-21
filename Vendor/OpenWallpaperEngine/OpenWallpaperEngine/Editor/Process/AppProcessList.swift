import AppKit
import Darwin

/// The other processes running the app's executable, told apart by their bundle and launch
/// arguments: Open Wallpaper Engine, the Wallpaper Editor (its own app, `AppBundleLayout`, or
/// `--wallpaper-editor`), or a helper run (`HelperRunCommand`, `CrashWatcher`). Only processes
/// isolated as this one is count (`AppStorageLocation`): every isolated copy shares the bundle ids.
enum AppProcessList {
    enum Kind: Equatable {
        case main
        case wallpaperEditor
        case helper
    }

    struct Entry: Equatable {
        let pid: pid_t
        let kind: Kind
        let isolationTag: String?
    }

    /// What a process launched with `arguments` (executable first) and `environment` is.
    /// `bundleIdentifier` is the process's bundle's.
    static func classify(arguments: [String], environment: [String: String],
                         bundleIdentifier: String?) -> (kind: Kind, isolationTag: String?) {
        let tag = AppStorageLocation.isolationTag(environment: environment, arguments: arguments, isRunningTests: false)
        if HelperRunCommand.isHelperRun(arguments: arguments) || arguments.contains(CrashWatcher.argument) {
            return (.helper, tag)
        }
        if AppLaunchMode.parse(arguments, bundleIdentifier: bundleIdentifier).isWallpaperEditor { return (.wallpaperEditor, tag) }
        return (.main, tag)
    }

    /// The running processes of `kind` of the bundle `bundleIdentifier`, besides this one, isolated
    /// under `isolationTag`.
    static func running(_ kind: Kind, isolationTag: String? = AppStorageLocation.current.isolationTag,
                        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? AppStorageLocation.realBundleIdentifier)
        -> [Entry] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).compactMap { app in
            let pid = app.processIdentifier
            guard pid != own, !app.isTerminated, let launch = launchArguments(of: pid) else { return nil }
            let (found, tag) = classify(arguments: launch.arguments, environment: launch.environment,
                                        bundleIdentifier: app.bundleIdentifier)
            guard found == kind, tag == isolationTag else { return nil }
            return Entry(pid: pid, kind: found, isolationTag: tag)
        }
    }

    /// A process's arguments and environment (`KERN_PROCARGS2`); nil when the kernel won't say
    /// (another user's process, or one that is gone).
    static func launchArguments(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argmax = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmax, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        size = buffer.count
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`'s layout: `argc` (an `Int32`), the executable's path, NUL padding, then
    /// `argc` NUL-terminated arguments and the NUL-terminated `KEY=value` environment.
    static func parseProcessArguments(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let argc = bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var index = countSize
        // The executable path, then its padding.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }
}
