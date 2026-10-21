import AppKit
import Foundation
import OWEControlProtocol

/// Starts Open Wallpaper Engine when a tool call finds it not running.
public protocol AppLaunching {
    func isRunning() -> Bool
    func launch() throws
}

/// Open Wallpaper Engine as `owe-mcp` finds it: the app `owe-mcp` is inside
/// (`<app>/Contents/Helpers/owe-mcp`), the app that installed the plugin, else the app
/// LaunchServices knows by its bundle id. It is opened in the background, isolated under
/// `isolationTag` for an isolated copy, so a development copy never starts on the user's real state.
public struct OWEAppLauncher: AppLaunching {
    public static let bundleIdentifier = "app.openwallpaperengine"

    public let appURL: URL?
    public let isolationTag: String?

    public init(appURL: URL?, isolationTag: String?) {
        self.appURL = appURL
        self.isolationTag = isolationTag
    }

    /// The launcher for `owe-mcp` at `executable`: the app it is inside, or the app that installed
    /// it as the MCP Server plugin (`MCPPluginLayout.Manifest`), isolated as `environment` or the
    /// manifest says.
    public static func forCurrentProcess(executable: URL = OWEMCPCommand.executableURL,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> OWEAppLauncher {
        let manifest = MCPPluginLayout.supportDirectory(ofInstalledExecutable: executable)
            .flatMap { MCPPluginLayout.manifest(supportDirectory: $0) }
        let tag = environment[ControlSocketLocation.isolationEnvironmentKey].flatMap(ControlSocketLocation.sanitizedTag)
            ?? manifest?.isolationTag.flatMap(ControlSocketLocation.sanitizedTag)
        let app = containingApp(of: executable) ?? manifest.map { URL(fileURLWithPath: $0.app, isDirectory: true) }
        return OWEAppLauncher(appURL: app, isolationTag: tag)
    }

    /// The app bundle `executable` sits in (`<app>/Contents/Helpers/…` or `<app>/Contents/MacOS/…`).
    public static func containingApp(of executable: URL) -> URL? {
        let folder = executable.standardizedFileURL.deletingLastPathComponent()
        let contents = folder.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard ["Helpers", "MacOS"].contains(folder.lastPathComponent), contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    /// Whether this copy of the app runs: one with the app's bundle id and the same isolation
    /// (every copy shares the bundle id, so the user's own app doesn't count for an isolated one).
    public func isRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).contains { app in
            Self.isolationTag(arguments: Self.arguments(of: app.processIdentifier)) == isolationTag
        }
    }

    /// The isolation a process of the app runs under, read from its arguments and environment
    /// (`-OWEIsolatedState <tag>` first, as the app reads them).
    static func isolationTag(arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "-OWEIsolatedState"), arguments.indices.contains(index + 1),
           let tag = ControlSocketLocation.sanitizedTag(arguments[index + 1]) {
            return tag
        }
        let prefix = ControlSocketLocation.isolationEnvironmentKey + "="
        return arguments.last { $0.hasPrefix(prefix) }.flatMap { ControlSocketLocation.sanitizedTag(String($0.dropFirst(prefix.count))) }
    }

    /// A process's arguments followed by its environment (`KERN_PROCARGS2`, readable for the
    /// user's own processes); empty when they can't be read.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // argc, then the executable's path, padding, argv and the environment, each NUL-terminated.
        return buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).dropFirst()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// `open`'s arguments: in the background (`-g`); a new instance for an isolated copy (`-n`),
    /// which shares the bundle id with the user's app.
    public var openArguments: [String] {
        var arguments = ["-g"]
        if isolationTag != nil { arguments.append("-n") }
        if let appURL {
            arguments += ["-a", appURL.path]
        } else {
            arguments += ["-b", Self.bundleIdentifier]
        }
        if let isolationTag { arguments += ["--args", "-OWEIsolatedState", isolationTag] }
        return arguments
    }

    public func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = openArguments
        // The client reads only owe-mcp's own stdout: `open` must not write to it.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppConnectionError(message: "`open \(openArguments.joined(separator: " "))` failed with status \(process.terminationStatus)")
        }
    }
}
