import Foundation

@main enum WorkshopDownloadProgressTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS \(label)") }
        var frame = SteamConsoleOutputFramer()
        check(frame.append(Data("progress: 1\rprogress: 2\r\n".utf8)) == ["progress: 1", "progress: 2", ""], "CR overwrites become separate progress lines, CRLF stays harmless")
        let utf8 = Array("中".utf8)
        check(frame.append(Data([utf8[0]])).isEmpty && frame.flushPartial() == nil, "incomplete UTF8 remains pending across idle flush")
        check(frame.append(Data([utf8[1], utf8[2], 10])) == ["中"], "split UTF8 survives actual byte framing")
        _ = frame.append(Data([65, utf8[0]]))
        check(frame.flushPartial() == "A", "idle prompt emits complete prefix only")
        check(frame.append(Data([utf8[1], utf8[2], 13])) == ["中"], "idle prompt retains incomplete suffix")
        check(frame.append(Data([0xff, 10])) == ["�"], "invalid byte cannot drop the rest of a console chunk")
        var assembler = SteamConsoleLineAssembler()
        check(assembler.consume(.partial("Waiting for user info...")) == "Waiting for user info...", "partial prompt is still delivered")
        check(assembler.consume(.line("FAILED")) == "Waiting for user info...FAILED", "auth suffix retains logical-line semantics")
        let s = WorkshopDownloadService.self
        check(s.extractFraction(from: "\u{1b}[32mDOWNLOADING, PROGRESS: 25.5 (255 / 1000)\u{1b}[0m") == 0.255, "ANSI uppercase percentage parses")
        check(s.extractFraction(from: "Downloading (300 / 1000)") == 0.3, "reported byte counters supply percentage")
        check(s.extractFraction(from: "progress: 1\rprogress: 80") == 0.8, "legacy overwrite string uses latest report")
        check(s.extractFraction(from: "progress: 120") == nil, "out of range percentage is rejected rather than clamped")
        check(s.extractByteCount(from: "Downloading (110 / 100)") == nil, "received greater than total rejected")
        check(s.extractByteCount(from: "Downloading (0 / 0)") == nil, "zero total rejected")
        check(s.extractByteCount(from: "Downloading (999999999999999999999 / 1000)") == nil, "overflow counters rejected")
        check(s.lineMatchesDownload("AppID 431960 downloading item 123", appID: "431960", itemID: "123"), "matching app and item accepted")
        check(!s.lineMatchesDownload("AppID 480 downloading progress: 90", appID: "431960", itemID: "123"), "other app rejected")
        check(!s.lineMatchesDownload("Success. Downloaded item 456", appID: "431960", itemID: "123"), "other item success rejected")
        var metrics = WorkshopDownloadMetrics()
        metrics.consume(fraction: 0.9, bytes: .init(received: 900, total: 1000), now: 1)
        check(metrics.presentation(now: 2) == nil, "bootstrap numbers cannot create download measurement before own command")
        metrics.start(now: 10)
        let unknown = metrics.presentation(now: 12)!
        check(unknown.0 == nil && unknown.1.contains("未提供具体进度") && unknown.1.contains("2 秒"), "silent source shows unknown and real monotonic elapsed")
        metrics.consume(fraction: nil, bytes: .init(received: 100, total: 1000), now: 12)
        check(metrics.bytesPerSecond == nil && metrics.fraction == 0.1, "first counter has bytes but no invented speed")
        metrics.consume(fraction: nil, bytes: .init(received: 300, total: 1000), now: 14)
        check(metrics.bytesPerSecond == 100, "speed derives from real counter delta and monotonic seconds")
        check(metrics.presentation(now: 18, force: true)!.1.contains("/s") == false, "silent stale rate expires")
        metrics.consume(fraction: nil, bytes: .init(received: 50, total: 1000), now: 19)
        check(metrics.bytesPerSecond == nil && metrics.fraction == 0.05, "counter rollback resets speed baseline")
        metrics.consume(fraction: nil, bytes: .init(received: 50, total: 2000), now: 20)
        check(metrics.bytesPerSecond == nil && metrics.fraction == 0.025, "total change resets speed baseline")
        metrics.consume(fraction: nil, bytes: .init(received: 60, total: 2000), now: 20.01)
        check(metrics.bytesPerSecond == nil, "coalesced counters do not invent a sub-millisecond speed")
        metrics.consume(fraction: nil, bytes: .init(received: 150, total: 2000), now: 21)
        check(metrics.bytesPerSecond == 100, "baseline still measures subsequent meaningful interval")
        metrics.consume(fraction: 0.01, bytes: nil, now: 22)
        check(metrics.bytesPerSecond == nil, "percentage rollback also invalidates speed")

        // Real child process emits CR and byte-split Unicode; no account or network.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GWProgress-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fixture")
        try Data(#"""
        #!/bin/sh
        printf 'Downloading, progress: 1 (10 / 1000)\r'
        printf '\344'; /bin/sleep 0.4; printf '\270\255\n'
        printf 'DOWNLOADING, PROGRESS: 75 (750 / 1000)\r'
        printf 'Password: '; /bin/sleep 0.5
        read -r value
        printf '\nSuccess. Downloaded item 123\n'
        /bin/sleep 0.3
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = try WorkshopInteractiveSession(executable: executable, arguments: [], environment: [:], currentDirectory: dir)
        var lines: [String] = []
        var actualAssembler = SteamConsoleLineAssembler()
        for await event in session.events {
            if let line = actualAssembler.consume(event) {
                lines.append(line)
                if line.contains("Password:") { session.send(line: "fixture") }
            }
        }
        check(lines.contains("中"), "real pipe preserves split Unicode over idle timer")
        check(lines.contains { s.extractFraction(from: $0) == 0.75 }, "real CR uppercase counter delivered as current progress")
        check(lines.contains { $0.contains("Password:") }, "real no-newline auth prompt still arrives")
        check(lines.contains { $0.contains("Success. Downloaded item 123") }, "real process final success survives framing")
        for silent in [true, false] {
            let layout = SteamCMDLayout(root: dir.appendingPathComponent(silent ? "silent" : "numeric"))
            try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
            let script = #"""
            #!/bin/sh
            printf 'Update state downloading, progress: 99 (990 / 1000)\r'
            printf 'Steam>\n'
            while IFS= read -r line; do
              case "$line" in
                login*) printf 'Waiting for user info...OK\n';;
                workshop_download_item*)
                  printf 'AppID 480 downloading progress: 88 (880 / 1000)\r'
                  printf 'Downloading item 456 progress: 77 (770 / 1000)\r'
            """# + "\n" + (silent ? "" : #"""
                  printf 'AppID 431960 Downloading item 123 PROGRESS: 10 (100 / 1000)\r'
                  /bin/sleep 0.6
                  printf 'AppID 431960 Downloading item 123 PROGRESS: 40 (400 / 1000)\r'
                  printf 'AppID 431960 validating item 123\r'
            """#) + "\n" + #"""
                  /bin/sleep 1.4
                  printf 'Success. Downloaded item 456\n'
                  printf 'ERROR! fixture intentionally stops before validation\n'
                  /bin/sleep 0.3
                  exit 1;;
                quit) exit 0;;
              esac
            done
            """#
            try Data(script.utf8).write(to: layout.executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.executableURL.path)
            let states = LockedBox<[WorkshopDownloadState]>([])
            let service = WorkshopDownloadService(layout: layout, executable: layout.executableURL)
            let item = WorkshopDownloadItem(publishedFileID: "123", title: "fixture", kind: .video,
                declaredTags: [], previewImageURLString: nil, fileSizeBytes: 999_999)
            do {
                _ = try await service.download(item: item, username: "fixture_account", progress: { state in states.with { $0.append(state) } }, logLine: { _ in })
                preconditionFailure("wrong-item success must never complete own download")
            } catch { check(true, "real service rejects wrong-item success (\(silent ? "silent" : "numeric"))") }
            let emitted = states.with { $0 }
            let downloading = emitted.compactMap { state -> (Double?, String)? in
                if case .downloading(let fraction, let text) = state { return (fraction, text) }; return nil
            }
            check(!downloading.contains { $0.0 == 0.99 || $0.0 == 0.88 || $0.0 == 0.77 }, "real service rejects bootstrap/other-app/other-item counters")
            if silent {
                check(downloading.allSatisfy { $0.0 == nil }, "silent actual service never derives percentage from metadata or time")
                check(downloading.contains { $0.1.contains("未提供具体进度") && $0.1.contains("已用时 1 秒") }, "silent actual service emits unknown elapsed heartbeat")
            } else {
                check(downloading.contains { $0.0 == 0.4 && $0.1.contains("/s") }, "real service publishes own counter percentage bytes and measured rate")
                let validation = emitted.firstIndex { if case .validating = $0 { return true }; return false }
                check(validation != nil && !emitted.dropFirst(validation! + 1).contains { if case .downloading = $0 { return true }; return false }, "Steam validation suppresses stale percentage heartbeat")
            }
        }
        print("RESULT \(checks) download progress checks passed; no Steam process, credentials, user logs, or network")
    }
}
