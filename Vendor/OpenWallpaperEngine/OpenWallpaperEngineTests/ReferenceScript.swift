import XCTest

/// A committed reference script (`Scripts/…`, plain Python 3) run at test time. The library sweeps
/// check the items their committed fixture covers against it, and run its generator for the items
/// the library gained or changed since, so a new wallpaper is checked the same way instead of
/// failing for being new. Without a python3 those items are skipped, and the test says so.
enum ReferenceScript {
    static let directory = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Scripts", directoryHint: .isDirectory)

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// The first python3 on `PATH`, then in the usual places, that runs Python 3.8 or later.
    static let python: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appending(path: "python3")
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let process = Process()
            process.executableURL = url
            process.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continue // not runnable here: try the next one
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return url }
        }
        return nil
    }()

    /// Runs `Scripts/<name>` with `arguments`; `environment` is added to the test's own. Throws
    /// with the end of its stderr when it exits non-zero.
    static func run(_ name: String, arguments: [String], environment: [String: String] = [:]) throws {
        guard let python else { throw Failure(description: "no python3") }
        let log = FileManager.default.temporaryDirectory.appending(path: "owe-script-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw Failure(description: "can't create \(log.path)")
        }
        defer { try? FileManager.default.removeItem(at: log) } // scratch cleanup
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = python
        process.arguments = [directory.appending(path: name).path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            throw Failure(description: "Scripts/\(name) \(arguments.joined(separator: " ")) exited "
                          + "\(process.terminationStatus): \(output.suffix(2000))")
        }
    }
}
