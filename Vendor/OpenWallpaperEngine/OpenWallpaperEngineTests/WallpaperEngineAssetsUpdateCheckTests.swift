import XCTest
@testable import OpenWallpaperEngine

/// "Update from Steam" looks up the current Wallpaper Engine build first and downloads only when
/// it differs from the installed one; "Re-download" always downloads; a failed lookup downloads
/// nothing. SteamCMD itself never runs here.
final class WallpaperEngineAssetsUpdateCheckTests: XCTestCase {
    private typealias Check = WallpaperEngineAssetsUpdateCheck
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-assets-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // scratch cleanup
    }

    // MARK: Parsing app_info_print

    func testThePublicBuildIDComesFromTheLastAppInfoBlock() {
        XCTAssertEqual(Check.publicBuildID(appInfo: appInfoOutput(build: "20112233")), "20112233")
        // A stale block printed before the refreshed one: the last one wins.
        let twice = appInfoOutput(build: "100") + "\n" + appInfoOutput(build: "200")
        XCTAssertEqual(Check.publicBuildID(appInfo: twice), "200")
        XCTAssertNil(Check.publicBuildID(appInfo: "Loading Steam API...OK\nNo app info for AppID 431960 found"))
        XCTAssertNil(Check.publicBuildID(appInfo: #""431960" { "depots" { "branches" { "public" { "buildid" "#))
    }

    func testTheLookupTellsTheBuildTheLoginAndFailuresApart() {
        XCTAssertEqual(Check.lookup(output: appInfoOutput(build: "7"), exitCode: 0), .build("7"))
        XCTAssertEqual(Check.lookup(output: steamCmdNoCachedLoginOutput, exitCode: 0), .loginRequired)
        XCTAssertEqual(Check.lookup(output: "Loading Steam API...OK\nERROR! Timed out waiting for AppInfo update.", exitCode: 0),
                       .failed("ERROR! Timed out waiting for AppInfo update."))
        guard case .failed = Check.lookup(output: "", exitCode: 1) else { return XCTFail("empty output is a failure") }
    }

    func testTheScriptOnlyReadsAppInfo() throws {
        let script = try Check.script(username: "someone")
        XCTAssertEqual(script.lines, ["@NoPromptForPassword 1", #"login "someone""#, #"app_info_update "1""#,
                                      #"app_info_print "431960""#])
        XCTAssertFalse(script.lines.contains { $0.hasPrefix("app_update") })
    }

    // MARK: Skip or update

    func testTheDecisionSkipsOnlyACompleteCopyOfTheCurrentBuild() {
        let steam = WallpaperEngineAssetsCache.Info(origin: .steam, installedAt: .now, steamBuildID: "100")
        let folder = WallpaperEngineAssetsCache.Info(origin: .folder, installedAt: .now)
        XCTAssertEqual(Check.decision(installed: steam, assetsComplete: true, currentBuild: "100"), .upToDate(build: "100"))
        XCTAssertEqual(Check.decision(installed: steam, assetsComplete: true, currentBuild: "101"), .download)
        XCTAssertEqual(Check.decision(installed: steam, assetsComplete: false, currentBuild: "100"), .download)
        XCTAssertEqual(Check.decision(installed: folder, assetsComplete: true, currentBuild: "100"), .download)
        XCTAssertEqual(Check.decision(installed: nil, assetsComplete: false, currentBuild: "100"), .download)

        XCTAssertTrue(Check.needsLookup(force: false, installed: steam, assetsComplete: true))
        XCTAssertFalse(Check.needsLookup(force: true, installed: steam, assetsComplete: true), "Re-download")
        XCTAssertFalse(Check.needsLookup(force: false, installed: steam, assetsComplete: false), "damaged copy")
        XCTAssertFalse(Check.needsLookup(force: false, installed: folder, assetsComplete: true))
        XCTAssertFalse(Check.needsLookup(force: false, installed: nil, assetsComplete: false))
    }

    // MARK: Service

    @MainActor
    func testTheCurrentBuildIsNotDownloadedAgain() throws {
        try installCache(build: "100")
        let runner = AppInfoRunner(appInfo: appInfoOutput(build: "100"))
        let service = makeService(runner: runner)
        service.installFromSteam()
        waitUntilSettled(service)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(service.notice?.contains("100") == true, String(describing: service.notice))
        XCTAssertEqual(runner.commands, ["app_info_print"])
    }

    @MainActor
    func testANewerBuildDownloadsAndIsRecorded() throws {
        try installCache(build: "100")
        let runner = AppInfoRunner(appInfo: appInfoOutput(build: "101"))
        let service = makeService(runner: runner)
        service.installFromSteam()
        waitUntilSettled(service)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(service.notice)
        XCTAssertEqual(runner.commands, ["app_info_print", "app_update"])
        XCTAssertEqual(WallpaperEngineAssetsCache.readInfo(cache: cache)?.steamBuildID, "101")
    }

    @MainActor
    func testReDownloadSkipsTheCheck() throws {
        try installCache(build: "100")
        let runner = AppInfoRunner(appInfo: appInfoOutput(build: "100"))
        let service = makeService(runner: runner)
        service.installFromSteam(force: true)
        waitUntilSettled(service)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(runner.commands, ["app_update"])
    }

    @MainActor
    func testAFailedCheckDownloadsNothing() throws {
        try installCache(build: "100")
        let runner = AppInfoRunner(appInfo: "Loading Steam API...OK\nERROR! Timed out waiting for AppInfo update.")
        let service = makeService(runner: runner)
        service.installFromSteam()
        waitUntilSettled(service)
        guard case .updateCheckFailed = service.lastFailure else { return XCTFail("\(String(describing: service.lastFailure))") }
        XCTAssertEqual(runner.commands, ["app_info_print"])
        XCTAssertEqual(WallpaperEngineAssetsCache.readInfo(cache: cache)?.steamBuildID, "100")

        let noLogin = AppInfoRunner(appInfo: steamCmdNoCachedLoginOutput)
        let loggedOut = makeService(runner: noLogin)
        loggedOut.installFromSteam()
        waitUntilSettled(loggedOut)
        XCTAssertEqual(loggedOut.lastFailure, .notLoggedIn(account: "someone"))
        XCTAssertEqual(noLogin.commands, ["app_info_print"])
    }

    // MARK: Helpers

    private var cache: URL { WallpaperEngineAssets.cacheDirectory(in: scratch) }

    private func installCache(build: String) throws {
        for folder in ["shaders", "effects"] {
            try FileManager.default.createDirectory(at: cache.appending(path: folder), withIntermediateDirectories: true)
        }
        try WallpaperEngineAssetsCache.writeInfo(.init(origin: .steam, installedAt: .now, steamBuildID: build), cache: cache)
    }

    @MainActor
    private func makeService(runner: SteamCmdRunning) -> WallpaperEngineAssetsService {
        let storage: URL = scratch
        let defaults = UserDefaults(suiteName: "owe-tests-\(UUID().uuidString)")!
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { storage }),
                                       runner: runner, storageDirectory: { storage },
                                       previewCacheRoot: storage.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: defaults, libraryDirectory: { storage }),
                                       presentPreview: { _ in }, account: .inMemory(), restoresSession: false)
        steamCmd.steamCmdPath = "/usr/bin/false"
        steamCmd.isLoggedIn = true
        steamCmd.steamUsername = "someone"
        return WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { storage },
                                            defaults: defaults)
    }

    @MainActor
    private func waitUntilSettled(_ service: WallpaperEngineAssetsService) {
        let settled = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                switch service.phase {
                case .idle, .failed: return true
                case .downloading, .copying: return false
                }
            }
        }, evaluatedWith: nil)
        wait(for: [settled], timeout: 10)
    }
}

/// SteamCMD's output for `app_info_print 431960`, trimmed to what matters, around its other lines.
private func appInfoOutput(build: String) -> String {
    """
    Loading Steam API...OK
    Logging in user 'someone' [U:1:12345] to Steam Public...OK
    Waiting for user info...OK
    Steam>AppID : 431960, change number : 31234567/0, last change : Mon Sep 28 10:00:00 2026
    "431960"
    {
    \t"common"
    \t{
    \t\t"name"\t\t"Wallpaper Engine"
    \t\t"type"\t\t"Tool"
    \t}
    \t"depots"
    \t{
    \t\t"431961"
    \t\t{
    \t\t\t"config" { "oslist" "windows" }
    \t\t\t"manifests" { "public" { "gid" "123" "size" "456" } }
    \t\t}
    \t\t"branches"
    \t\t{
    \t\t\t"public"
    \t\t\t{
    \t\t\t\t"buildid"\t\t"\(build)"
    \t\t\t\t"timeupdated"\t\t"1790000000"
    \t\t\t}
    \t\t\t"beta"
    \t\t\t{
    \t\t\t\t"buildid"\t\t"999999"
    \t\t\t\t"description"\t\t"Beta {testing}"
    \t\t\t}
    \t\t}
    \t}
    }
    Steam>
    """
}

/// A fake SteamCMD: `app_info_print` prints `appInfo`; `app_update` installs a tiny asset tree
/// where the script's `force_install_dir` says, with no app manifest.
private final class AppInfoRunner: SteamCmdRunning, @unchecked Sendable {
    private let appInfo: String
    private let lock = NSLock()
    private var recorded: [String] = [] // Owned by `lock`.
    /// The download-relevant command of each run, in order.
    var commands: [String] { lock.withLock { recorded } }

    init(appInfo: String) { self.appInfo = appInfo }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        if script.lines.contains(where: { $0.hasPrefix("app_info_print") }) {
            lock.withLock { recorded.append("app_info_print") }
            return SteamCmdRun(output: appInfo, exitCode: 0)
        }
        lock.withLock { recorded.append(script.lines.contains { $0.hasPrefix("app_update") } ? "app_update" : "other") }
        guard let line = script.lines.first(where: { $0.hasPrefix("force_install_dir ") }) else {
            return SteamCmdRun(output: "no install dir", exitCode: 1)
        }
        let path = String(line.dropFirst("force_install_dir ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let install = URL(fileURLWithPath: path, isDirectory: true)
        do {
            for (relative, text) in [("assets/shaders/common.h", "x"), ("assets/effects/tint/effect.json", "{}")] {
                let url = install.appending(path: relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        } catch {
            return SteamCmdRun(output: "write failed: \(error)", exitCode: 1)
        }
        return SteamCmdRun(output: "Success! App '431960' fully installed.", exitCode: 0)
    }
}
