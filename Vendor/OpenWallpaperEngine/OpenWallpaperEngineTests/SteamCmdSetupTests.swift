import XCTest
@testable import OpenWallpaperEngine

/// Finding steamcmd, installing Valve's package (with a fake download, never the network), the
/// automatic install's conditions, and logging in through Terminal.
final class SteamCmdSetupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-steamcmd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func makeFile(_ path: String, executable: Bool = true) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func locator(customPath: String? = nil) -> SteamCmdLocator {
        SteamCmdLocator(customPath: customPath, ownInstallDirectory: root.appending(path: "support/steamcmd"),
                        homeDirectory: root.appending(path: "home"), systemRoot: root)
    }

    /// A gzipped tar of `files` (path → executable), made with the system's tar.
    private func makeArchive(_ files: [String: Bool], quarantined: Bool = false) throws -> URL {
        let source = root.appending(path: "archive-source-\(UUID().uuidString)")
        for (path, executable) in files {
            let url = source.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            if quarantined {
                let value = "0081;00000000;Test;"
                XCTAssertEqual(setxattr(url.path, SteamCmdPackage.quarantineAttribute, value, value.utf8.count, 0, 0), 0)
            }
        }
        let archive = root.appending(path: "steamcmd-\(UUID().uuidString).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", source.path] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    @MainActor
    private func makeInstaller(downloader: SteamCmdPackageDownloading, firstRunner: SteamCmdFirstRunning = FakeFirstRunner(),
                               defaults: UserDefaults? = nil, isRunningTests: Bool = false,
                               onInstalled: @escaping @MainActor () -> Void = {}) throws -> SteamCmdInstaller {
        let suite = "owe-steamcmd-installer-\(UUID().uuidString)"
        let store = try defaults ?? XCTUnwrap(UserDefaults(suiteName: suite))
        return SteamCmdInstaller(installDirectory: root.appending(path: "support/steamcmd"), downloader: downloader,
                                 firstRunner: firstRunner, defaults: store, isRunningTests: isRunningTests,
                                 trash: { try FileManager.default.removeItem(at: $0) }, onInstalled: onInstalled)
    }

    // MARK: Detection

    func testSearchOrderIsCustomOwnHomebrewSteamThenManual() throws {
        let custom = try makeFile("custom/steamcmd")
        let own = try makeFile("support/steamcmd/steamcmd.sh")
        let armBrew = try makeFile("opt/homebrew/bin/steamcmd")
        let intelBrew = try makeFile("usr/local/bin/steamcmd")
        let steam = try makeFile("home/Library/Application Support/Steam/steamcmd/steamcmd.sh")
        let manual = try makeFile("home/steamcmd/steamcmd.sh")

        XCTAssertEqual(locator(customPath: custom.path).locate(), custom.path)
        XCTAssertEqual(locator().locate(), own.path)
        try FileManager.default.removeItem(at: own)
        XCTAssertEqual(locator().locate(), armBrew.path)
        try FileManager.default.removeItem(at: armBrew)
        XCTAssertEqual(locator().locate(), intelBrew.path)
        try FileManager.default.removeItem(at: intelBrew)
        XCTAssertEqual(locator().locate(), steam.path)
        try FileManager.default.removeItem(at: steam)
        XCTAssertEqual(locator().locate(), manual.path)
        try FileManager.default.removeItem(at: manual)
        XCTAssertNil(locator().locate())
    }

    func testOnlyExecutableFilesCount() throws {
        let plain = try makeFile("opt/homebrew/bin/steamcmd", executable: false)
        try FileManager.default.createDirectory(at: root.appending(path: "usr/local/bin/steamcmd"), withIntermediateDirectories: true)
        let manual = try makeFile("home/steamcmd/steamcmd.sh")

        XCTAssertFalse(SteamCmdLocator.isExecutableFile(plain.path))
        XCTAssertFalse(SteamCmdLocator.isExecutableFile(root.appending(path: "usr/local/bin/steamcmd").path))
        XCTAssertTrue(SteamCmdLocator.isExecutableFile(manual.path))
        XCTAssertEqual(locator(customPath: plain.path).locate(), manual.path)
    }

    func testSearchRootComesFromTheEnvironment() {
        XCTAssertNil(SteamCmdLocator.searchRoot(environment: [:]))
        XCTAssertEqual(SteamCmdLocator.searchRoot(environment: ["OWE_STEAMCMD_SEARCH_ROOT": "/tmp/x"])?.path, "/tmp/x")
    }

    /// What activating the app does: a steamcmd installed meanwhile is found, one removed is dropped.
    func testRedetectPicksUpANewInstall() throws {
        let locator: SteamCmdLocator = locator()
        let service = SteamCmdService(runner: FakeLoginRunner(output: "", exitCode: 0), locator: { locator },
                                      asksLoginShell: false, restoresSession: false)
        service.detectSteamCmd()
        XCTAssertNil(service.steamCmdPath)

        let brew = try makeFile("opt/homebrew/bin/steamcmd")
        let found = expectation(description: "found")
        service.detectSteamCmd { isFound in
            XCTAssertTrue(isFound)
            found.fulfill()
        }
        wait(for: [found], timeout: 1)
        XCTAssertEqual(service.steamCmdPath, brew.path)

        try FileManager.default.removeItem(at: brew)
        service.detectSteamCmd()
        XCTAssertNil(service.steamCmdPath)
    }

    // MARK: Package

    func testExtractsTheArchiveAndClearsQuarantine() throws {
        let archive = try makeArchive(["steamcmd.sh": true, "steamcmd": true], quarantined: true)
        let target = root.appending(path: "extracted")
        let executable = try SteamCmdPackage.extract(archive, into: target)

        XCTAssertEqual(executable.path, target.appending(path: "steamcmd.sh").path)
        XCTAssertTrue(SteamCmdLocator.isExecutableFile(executable.path))
        XCTAssertFalse(SteamCmdPackage.hasQuarantine(executable.path))
        XCTAssertFalse(SteamCmdPackage.hasQuarantine(target.appending(path: "steamcmd").path))
        XCTAssertGreaterThan(SteamCmdPackage.size(of: target), 0)
    }

    func testRejectsANonGzipDownload() throws {
        let html = root.appending(path: "error.html")
        try Data("<html>Not found</html>".utf8).write(to: html)
        XCTAssertThrowsError(try SteamCmdPackage.extract(html, into: root.appending(path: "out"))) { error in
            XCTAssertEqual(error as? SteamCmdPackage.Failure, .notGzip)
        }
    }

    func testRejectsAnArchiveWithoutARunnableScript() throws {
        let archive = try makeArchive(["steamcmd.sh": false])
        XCTAssertThrowsError(try SteamCmdPackage.extract(archive, into: root.appending(path: "out"))) { error in
            XCTAssertEqual(error as? SteamCmdPackage.Failure, .missingExecutable)
        }
    }

    func testDownloadsFromValveOverHTTPS() {
        XCTAssertEqual(SteamCmdPackage.downloadURL.scheme, "https")
        XCTAssertEqual(SteamCmdPackage.downloadURL.lastPathComponent, "steamcmd_osx.tar.gz")
    }

    // MARK: Install

    @MainActor
    func testInstallDownloadsExtractsAndUpdates() async throws {
        let archive = try makeArchive(["steamcmd.sh": true])
        let firstRunner = FakeFirstRunner()
        var installedCount = 0
        let installer = try makeInstaller(downloader: FakeDownloader(result: .success(archive)), firstRunner: firstRunner,
                                          onInstalled: { installedCount += 1 })
        installer.install()
        XCTAssertTrue(installer.isBusy)
        await installer.wait()

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertFalse(installer.isAutomatic)
        XCTAssertTrue(installer.hasOwnCopy)
        XCTAssertEqual(firstRunner.executables, [installer.executable])
        XCTAssertEqual(installedCount, 1)
        XCTAssertNotNil(installer.installedSize)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "support").path)
        XCTAssertEqual(leftovers, ["steamcmd"], "the staging folder is removed")

        // What steamcmd's first run leaves beside its folder.
        let link = root.appending(path: "support/Frameworks")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "MacOS/Frameworks")
        try installer.remove()
        XCTAssertFalse(installer.hasOwnCopy)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(installedCount, 2, "removing re-detects too")
    }

    @MainActor
    func testOfflineInstallFailsWithAClearMessage() async throws {
        let installer = try makeInstaller(downloader: FakeDownloader(result: .failure(URLError(.notConnectedToInternet))))
        installer.install()
        await installer.wait()
        guard case .failed(let message) = installer.phase else { return XCTFail("\(installer.phase)") }
        XCTAssertEqual(message, SteamCmdInstaller.message(for: URLError(.notConnectedToInternet)))
        XCTAssertNotEqual(message, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertFalse(installer.hasOwnCopy)
    }

    func testFullDiskGetsItsOwnMessage() {
        let full = SteamCmdInstaller.message(for: CocoaError(.fileWriteOutOfSpace))
        XCTAssertEqual(full, SteamCmdInstaller.message(for: POSIXError(.ENOSPC)))
        XCTAssertNotEqual(full, CocoaError(.fileWriteOutOfSpace).localizedDescription)
    }

    @MainActor
    func testAFailedSelfUpdateLeavesNoCopy() async throws {
        let archive = try makeArchive(["steamcmd.sh": true])
        let installer = try makeInstaller(downloader: FakeDownloader(result: .success(archive)),
                                          firstRunner: FakeFirstRunner(error: ProcessSteamCmdFirstRunner.Failure.exited(1, "boom")))
        installer.install()
        await installer.wait()
        guard case .failed = installer.phase else { return XCTFail("\(installer.phase)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installDirectory.path))
    }

    @MainActor
    func testCancelReturnsToIdle() async throws {
        let installer = try makeInstaller(downloader: HangingDownloader())
        installer.install()
        installer.cancel()
        await installer.wait()
        XCTAssertEqual(installer.phase, .idle)
        XCTAssertFalse(installer.hasOwnCopy)
    }

    // MARK: Automatic install

    func testAutoInstallConditions() {
        XCTAssertTrue(SteamCmdInstaller.shouldAutoInstall(isRunningTests: false, isEnabled: true, steamCmdFound: false, phase: .idle))
        XCTAssertFalse(SteamCmdInstaller.shouldAutoInstall(isRunningTests: true, isEnabled: true, steamCmdFound: false, phase: .idle))
        XCTAssertFalse(SteamCmdInstaller.shouldAutoInstall(isRunningTests: false, isEnabled: false, steamCmdFound: false, phase: .idle))
        XCTAssertFalse(SteamCmdInstaller.shouldAutoInstall(isRunningTests: false, isEnabled: true, steamCmdFound: true, phase: .idle))
        XCTAssertTrue(SteamCmdInstaller.shouldAutoInstall(isRunningTests: false, isEnabled: true, steamCmdFound: false, phase: .failed("x")))
        XCTAssertFalse(SteamCmdInstaller.shouldAutoInstall(isRunningTests: false, isEnabled: true, steamCmdFound: false, phase: .extracting))
    }

    @MainActor
    func testAutoInstallRunsOnlyWhenNothingWasFound() async throws {
        let archive = try makeArchive(["steamcmd.sh": true])
        let installer = try makeInstaller(downloader: FakeDownloader(result: .success(archive)))
        XCTAssertFalse(installer.autoInstallIfNeeded(steamCmdFound: true))
        XCTAssertTrue(installer.autoInstallIfNeeded(steamCmdFound: false))
        XCTAssertTrue(installer.isAutomatic)
        XCTAssertFalse(installer.autoInstallIfNeeded(steamCmdFound: false), "one install at a time")
        await installer.wait()
        XCTAssertEqual(installer.phase, .installed)
    }

    @MainActor
    func testAutoInstallSkipsUnderTestsAndWhenTurnedOff() throws {
        let archive = try makeArchive(["steamcmd.sh": true])
        let underTests = try makeInstaller(downloader: FakeDownloader(result: .success(archive)), isRunningTests: true)
        XCTAssertFalse(underTests.autoInstallIfNeeded(steamCmdFound: false))

        let suite = "owe-steamcmd-auto-off-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SteamCmdInstaller.autoInstallKey)
        let turnedOff = try makeInstaller(downloader: FakeDownloader(result: .success(archive)), defaults: defaults)
        XCTAssertFalse(turnedOff.isAutoInstallEnabled)
        XCTAssertFalse(turnedOff.autoInstallIfNeeded(steamCmdFound: false))
        XCTAssertEqual(turnedOff.phase, .idle)
    }

    @MainActor
    func testAutoInstallRetriesAfterAFailure() async throws {
        let archive = try makeArchive(["steamcmd.sh": true])
        let downloader = FlakyDownloader(archive: archive)
        let installer = try makeInstaller(downloader: downloader)
        XCTAssertTrue(installer.autoInstallIfNeeded(steamCmdFound: false))
        await installer.wait()
        guard case .failed = installer.phase else { return XCTFail("\(installer.phase)") }

        XCTAssertTrue(installer.autoInstallIfNeeded(steamCmdFound: false))
        await installer.wait()
        XCTAssertEqual(installer.phase, .installed)
    }

    // MARK: Terminal login

    func testTerminalCommandQuotesThePathAndAccount() {
        XCTAssertEqual(SteamCmdTerminalLogin.command(steamCmdPath: "/opt/homebrew/bin/steamcmd", account: "gaben"),
                       "'/opt/homebrew/bin/steamcmd' +login 'gaben' +quit")
        XCTAssertEqual(SteamCmdTerminalLogin.command(
            steamCmdPath: "/Users/me/Library/Application Support/Open Wallpaper Engine/steamcmd/steamcmd.sh", account: "o'neil"),
            #"'/Users/me/Library/Application Support/Open Wallpaper Engine/steamcmd/steamcmd.sh' +login 'o'\''neil' +quit"#)
    }

    func testTerminalCommandRunsInZsh() throws {
        let file = try SteamCmdTerminalLogin.writeCommandFile("echo hi", in: root)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: file.path))
        XCTAssertEqual(file.pathExtension, "command")

        // The quoting survives a real shell: `printf` gets the path and account as two arguments.
        let command = SteamCmdTerminalLogin.command(steamCmdPath: "printf", account: "a b'c")
            .replacingOccurrences(of: "+login", with: "'%s|%s\\n'")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", command]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "a b'c|+quit\n")
    }

    func testSignedInInTerminalReusesTheCachedLogin() throws {
        let steamcmd = try makeFile("opt/homebrew/bin/steamcmd")
        let locator: SteamCmdLocator = locator()
        let runner = FakeLoginRunner(output: "Logging in user 'gaben' to Steam Public...OK\nLogged in OK\n", exitCode: 0)
        let service = SteamCmdService(runner: runner, locator: { locator }, asksLoginShell: false, restoresSession: false)
        service.detectSteamCmd()
        XCTAssertEqual(service.steamCmdPath, steamcmd.path)

        service.loginWithCachedSession(username: "gaben", failureMessage: "no session")
        let loggedIn = expectation(for: NSPredicate { _, _ in service.isLoggedIn }, evaluatedWith: nil)
        wait(for: [loggedIn], timeout: 5)
        XCTAssertNil(service.loginError)
        XCTAssertEqual(runner.scripts.last?.lines.last, #"login "gaben""#, "only the account name, no password")
    }

    func testSignedInInTerminalWithoutASessionShowsTheError() throws {
        try makeFile("opt/homebrew/bin/steamcmd")
        let locator: SteamCmdLocator = locator()
        let runner = FakeLoginRunner(output: "Logging in user 'gaben' to Steam Public...FAILED (No cached credentials)\n", exitCode: 5)
        let service = SteamCmdService(runner: runner, locator: { locator }, asksLoginShell: false, restoresSession: false)
        service.detectSteamCmd()

        service.loginWithCachedSession(username: "gaben", failureMessage: "no session")
        let failed = expectation(for: NSPredicate { _, _ in service.loginError != nil }, evaluatedWith: nil)
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(service.loginError, "no session")
        XCTAssertFalse(service.isLoggedIn)
    }
}

// MARK: - Fakes

/// Copies a local archive to the destination, or fails.
private struct FakeDownloader: SteamCmdPackageDownloading {
    let result: Result<URL, Error>

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        progress(0.5)
        try FileManager.default.copyItem(at: result.get(), to: destination)
        progress(1)
    }
}

/// Fails the first download as if offline, then works.
private final class FlakyDownloader: SteamCmdPackageDownloading, @unchecked Sendable {
    private let archive: URL
    private let lock = NSLock()
    private var calls = 0 // Owned by `lock`.

    init(archive: URL) { self.archive = archive }

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let call: Int = lock.withLock { calls += 1; return calls }
        if call == 1 { throw URLError(.notConnectedToInternet) }
        try FileManager.default.copyItem(at: archive, to: destination)
    }
}

/// Waits until cancelled.
private struct HangingDownloader: SteamCmdPackageDownloading {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        while true {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeFirstRunner: SteamCmdFirstRunning, @unchecked Sendable {
    private let error: Error?
    private let lock = NSLock()
    private var ran: [URL] = [] // Owned by `lock`.

    init(error: Error? = nil) { self.error = error }

    var executables: [URL] { lock.withLock { ran } }

    func firstRun(_ executable: URL) async throws {
        lock.withLock { ran.append(executable) }
        XCTAssertTrue(SteamCmdLocator.isExecutableFile(executable.path))
        if let error { throw error }
    }
}

/// Answers every steamcmd run with the same output, recording the scripts.
private final class FakeLoginRunner: SteamCmdRunning, @unchecked Sendable {
    private let output: String
    private let exitCode: Int32
    private let lock = NSLock()
    private var recorded: [SteamCmdScript] = [] // Owned by `lock`.

    init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }

    var scripts: [SteamCmdScript] { lock.withLock { recorded } }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        lock.withLock { recorded.append(script) }
        return SteamCmdRun(output: output, exitCode: exitCode)
    }
}
