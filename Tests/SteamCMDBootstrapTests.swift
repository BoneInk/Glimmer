import Foundation

// Isolated logging/text dependencies for the real WorkshopProcessRunner under test.
enum WorkshopLog {
    static func sanitize(_ text: String) -> String { text }
    static func info(_ text: String) {}
    static func notice(_ text: String) {}
}
enum SteamHTML {
    static func collapseWhitespace(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}

@main
struct SteamCMDBootstrapTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gw-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ truth: Bool, _ message: String) {
            precondition(truth, message)
            checks += 1
        }
        func fixture(_ body: String) throws -> (URL, URL) {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("steamcmd")
            let source = "#!/bin/sh\nn=0\n[ ! -f count ] || n=$(/bin/cat count)\nn=$((n+1))\necho $n > count\n" + body
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return (script, directory)
        }
        func count(_ directory: URL) -> Int {
            Int((try? String(contentsOf: directory.appendingPathComponent("count"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        }
        func run(_ script: URL, _ directory: URL, timeout: Double = 2) async throws -> SteamCMDBootstrap.Result {
            let runner = WorkshopProcessRunner()
            return try await SteamCMDBootstrap.run(totalTimeout: timeout) { remaining in
                try await runner.run(executable: script, arguments: ["+quit"], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: directory, timeout: remaining)
            }
        }
        let (updated, updatedRoot) = try fixture("if [ $n -eq 1 ]; then echo 'Update complete, launching...'; exit 42; fi\necho 'Steam Console Client - version 123'; exit 0\n")
        print("CASE update then success")
        let result = try await run(updated, updatedRoot)
        check(result.updateRestarts == 1, "update completion must restart once")
        check(result.output.contains("version 123"), "readiness must use actual successful second output")
        check(count(updatedRoot) == 2, "exit42 then0 must run exactly twice")

        for (body, expectedCode, expectedRuns) in [
            ("echo 'Update complete, launching...'; exit 42\n", Int32(42), 3),
            ("echo 'Unrelated error'; exit 42\n", Int32(42), 1),
            ("echo 'Update complete, launching...'; exit 9\n", Int32(9), 1)
        ] {
            let (script, directory) = try fixture(body)
            print("CASE failure expected \(expectedCode) / \(expectedRuns) runs")
            do { _ = try await run(script, directory); preconditionFailure("must not swallow nonzero") }
            catch WorkshopProcessError.nonZeroExit(let code, _) {
                check(code == expectedCode, "preserve original error code")
                check(count(directory) == expectedRuns, "bounded and selective retries")
            }
        }
        let (normal, normalRoot) = try fixture("echo 'normal'; exit 0\n")
        let normalResult = try await run(normal, normalRoot)
        check(normalResult.updateRestarts == 0 && count(normalRoot) == 1, "normal run must not restart")

        let (slow, slowRoot) = try fixture("/bin/sleep 0.10\necho 'Update complete, launching...'; exit 42\n")
        print("CASE deadline")
        do { _ = try await run(slow, slowRoot, timeout: 0.15); preconditionFailure("shared deadline must expire") }
        catch WorkshopProcessError.timedOut {
            check(count(slowRoot) <= 2, "restart cannot reset timeout budget")
        }
        print("PASS SteamCMD bootstrap: \(checks) assertions with real isolated fixture processes")
    }
}
