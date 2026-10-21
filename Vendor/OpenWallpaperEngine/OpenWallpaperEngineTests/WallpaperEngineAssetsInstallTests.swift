import XCTest
@testable import OpenWallpaperEngine

/// Installing the assets from the user's Steam copy: the SteamCMD script, reading its output, the
/// subset kept in the cache, and the service's states. SteamCMD itself never runs here.
final class WallpaperEngineAssetsInstallTests: XCTestCase {
    private var scratch: URL!
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "owe-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-assets-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // scratch cleanup
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: SteamCMD script and output

    /// The Windows depot of app 431960, into our own folder, with the cached login only.
    func testTheScriptDownloadsTheWindowsAppWithTheCachedLogin() throws {
        let folder = URL(fileURLWithPath: "/Volumes/Storage/.owe-assets-download", isDirectory: true)
        let script = try WallpaperEngineAssetsDownload.script(installDirectory: folder, username: "someone")
        XCTAssertEqual(script.lines, [
            "@NoPromptForPassword 1",
            "@sSteamCmdForcePlatformType \"windows\"",
            "force_install_dir \"/Volumes/Storage/.owe-assets-download\"",
            "login \"someone\"",
            "app_update \"431960\" \"validate\"",
        ])
        XCTAssertTrue(String(decoding: script.standardInput, as: UTF8.self).hasSuffix("quit\n"))
        XCTAssertThrowsError(try WallpaperEngineAssetsDownload.script(installDirectory: folder, username: "a\"b"))
    }

    func testTheOutcomeTellsOwnershipLoginAndErrorsApart() {
        typealias Download = WallpaperEngineAssetsDownload
        XCTAssertEqual(Download.outcome(output: "ERROR! Failed to install app '431960' (No subscription)", exitCode: 8,
                                        assetsPresent: false), .notOwned)
        XCTAssertEqual(Download.outcome(output: "Cached credentials not found.\nFAILED (Login Failure)", exitCode: 5,
                                        assetsPresent: false), .loginRequired)
        XCTAssertEqual(Download.outcome(output: "Success! App '431960' fully installed.", exitCode: 0, assetsPresent: true),
                       .installed)
        XCTAssertEqual(Download.outcome(output: "ok\nERROR! Failed to install app '431960' (Disk write failure)\n", exitCode: 8,
                                        assetsPresent: false),
                       .failed("ERROR! Failed to install app '431960' (Disk write failure)"))
    }

    func testProgressAndBuildIDParse() throws {
        let progress = try XCTUnwrap(WallpaperEngineAssetsDownload.progress(
            in: " Update state (0x61) downloading, progress: 45.50 (455 / 1000)\n"))
        XCTAssertEqual(progress.fraction, 0.455, accuracy: 0.0001)
        XCTAssertEqual(progress.downloadedBytes, 455)
        XCTAssertEqual(progress.totalBytes, 1000)
        XCTAssertNil(WallpaperEngineAssetsDownload.progress(in: "Logging in user 'x' to Steam Public..."))
        let manifest = "\"AppState\"\n{\n\t\"appid\"\t\t\"431960\"\n\t\"buildid\"\t\t\"20112233\"\n}\n"
        XCTAssertEqual(WallpaperEngineAssetsDownload.buildID(manifest: manifest), "20112233")
    }

    // MARK: Cache layout

    /// The same subset `Scripts/fill-assets-cache.sh` takes: no preview projects (of effects and
    /// presets), no HLSL or editor shaders, the presets the editor offers, the locale's `ui_*.json`
    /// from beside `assets`, and nothing else of the install.
    func testTheCacheKeepsOnlyTheAssetsSubset() throws {
        let install = scratch.appending(path: "download")
        let assets = install.appending(path: "assets")
        for path in ["effects/tint/effect.json", "effects/tint/preview/preview.jpg", "shaders/common.h",
                     "shaders/HLSL/common.hlsl", "shaders/editor/grid.frag", "materials/util/white.json",
                     "models/util/sphere.mdl", "particles/fire.json", "scripts/jsclasses/baseclasses.js",
                     "zcompat/web/1.json", "fonts/Roboto.ttf", "fonts/SIL Open Font License.txt",
                     "presets/rain/preset.json", "presets/rain/particles/presets/rain.json",
                     "presets/rain/previewdownpour/scene.json", "scenes/particleeditor/scene.json",
                     "effects/tint/.DS_Store"] {
            try write(path, to: path, in: assets)
        }
        try write("{}", to: "locale/ui_en-us.json", in: install)
        try write("{}", to: "locale/other.json", in: install)
        try write("exe", to: "wallpaper64.exe", in: install)

        let cache = WallpaperEngineAssets.cacheDirectory(in: scratch.appending(path: "storage"))
        let info = WallpaperEngineAssetsCache.Info(origin: .steam, installedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                   steamBuildID: "7")
        let copied = try WallpaperEngineAssetsCache.fill(cache, from: install, info: info)

        let files = try Set(FileManager.default.subpathsOfDirectory(atPath: cache.path).filter {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: cache.appending(path: $0).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        })
        XCTAssertEqual(files, ["effects/tint/effect.json", "shaders/common.h", "materials/util/white.json",
                               "models/util/sphere.mdl", "particles/fire.json", "scripts/jsclasses/baseclasses.js",
                               "zcompat/web/1.json", "fonts/Roboto.ttf", "fonts/SIL Open Font License.txt",
                               "presets/rain/preset.json", "presets/rain/particles/presets/rain.json",
                               "locale/ui_en-us.json", ".owe-assets-info.json"])
        XCTAssertEqual(copied, 12)
        XCTAssertEqual(WallpaperEngineAssetsCache.readInfo(cache: cache), info)
        XCTAssertTrue(WallpaperEngineAssets.isAssetTree(cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path + ".partial"))
    }

    /// A folder that isn't an install is refused, and a cancelled copy keeps the previous cache.
    func testAFailedOrCancelledFillKeepsThePreviousCache() throws {
        let cache = WallpaperEngineAssets.cacheDirectory(in: scratch)
        try write("old", to: "shaders/common.h", in: cache)
        try write("{}", to: "effects/old/effect.json", in: cache)
        let info = WallpaperEngineAssetsCache.Info(origin: .folder, installedAt: .now, steamBuildID: nil)
        XCTAssertThrowsError(try WallpaperEngineAssetsCache.fill(cache, from: scratch.appending(path: "nothing"), info: info))

        let install = scratch.appending(path: "install")
        try write("new", to: "assets/shaders/common.h", in: install)
        try write("{}", to: "assets/effects/new/effect.json", in: install)
        XCTAssertThrowsError(try WallpaperEngineAssetsCache.fill(cache, from: install, info: info, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try String(contentsOf: cache.appending(path: "shaders/common.h"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path + ".partial"))
    }

    // MARK: Default wallpapers

    /// Only `projects/defaultprojects` comes in, scene, video and web only (application skipped,
    /// declared or implied by an `.exe`), names kept, and an existing folder never replaced.
    func testDefaultWallpapersComeInWithoutApplicationsOrOverwrites() throws {
        let install = scratch.appending(path: "download"), storage = scratch.appending(path: "storage")
        let projects: [(String, String)] = [
            ("aurora", #"{"title":"A","file":"scene.json","type":"scene"}"#),
            ("untyped", #"{"title":"U","file":"untyped.json"}"#),
            ("clip", #"{"title":"C","file":"clip.mp4","type":"Video"}"#),
            ("page", #"{"title":"P","file":"index.html","type":"web"}"#),
            ("game", #"{"title":"G","file":"game.exe","type":"application"}"#),
            ("sheep", #"{"title":"S","file":"sheep.exe"}"#),
            ("taken", #"{"title":"T","file":"scene.json","type":"scene"}"#),
        ]
        for (name, json) in projects {
            try write(json, to: "projects/defaultprojects/\(name)/project.json", in: install)
            try write("x", to: "projects/defaultprojects/\(name)/content.bin", in: install)
        }
        try write("x", to: "projects/defaultprojects/no-project/readme.txt", in: install)
        try write(#"{"title":"M","file":"scene.json","type":"scene"}"#, to: "projects/myprojects/mine/project.json", in: install)
        try write("mine", to: "taken/project.json", in: storage)

        let result = try WallpaperEngineDefaultProjects.importProjects(from: install, into: storage, move: true)
        XCTAssertEqual(result.imported, ["aurora", "clip", "page", "untyped"])
        XCTAssertEqual(result.existing, ["taken"])
        XCTAssertEqual(result.unsupported, ["game", "sheep"])
        XCTAssertEqual(try String(contentsOf: storage.appending(path: "taken/project.json"), encoding: .utf8), "mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appending(path: "aurora/content.bin").path))
        for absent in ["game", "sheep", "mine", "no-project"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(path: absent).path), absent)
        }
        let none = try WallpaperEngineDefaultProjects.importProjects(from: scratch.appending(path: "empty"), into: storage, move: false)
        XCTAssertEqual(none, .init())
    }

    /// WE's default projects may leave out `type`; the library then reads the one `file` implies.
    func testAProjectWithoutATypeTakesTheOneItsFileImplies() throws {
        let scene = try JSONDecoder().decode(WEProject.self, from: Data(#"{"title":"A","file":"audiophile.json"}"#.utf8))
        XCTAssertEqual(scene.type, "scene")
        let typed = try JSONDecoder().decode(WEProject.self, from: Data(#"{"title":"A","file":"a.json","type":"video"}"#.utf8))
        XCTAssertEqual(typed.type, "video")
        XCTAssertEqual(WEProject.impliedType(file: "sheep.exe"), "application")
        XCTAssertEqual(WEProject.impliedType(file: "index.html"), "web")
        XCTAssertEqual(WEProject.impliedType(file: "assets.json", category: "Asset"), "")
    }

    /// WE marks its own default projects `"official": true`; the Details panel names their
    /// author Wallpaper Engine. Workshop items leave it out.
    func testAnOfficialProjectIsMarked() throws {
        let official = try JSONDecoder().decode(WEProject.self, from: Data(#"{"title":"Dino Run","file":"scene.json","official":true}"#.utf8))
        XCTAssertEqual(official.official, true)
        let workshop = try JSONDecoder().decode(WEProject.self, from: Data(#"{"title":"A","file":"scene.json"}"#.utf8))
        XCTAssertNil(workshop.official)
    }

    // MARK: Service

    @MainActor
    func testTheServiceReportsMissingAssetsAndWhatInstallingNeeds() throws {
        try XCTSkipIf(WallpaperEngineAssets.directory != nil, "OWE_ASSETS is set for this run")
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { self.scratch }),
                                       runner: UnusedRunner(), storageDirectory: { self.scratch },
                                       previewCacheRoot: scratch.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: makeDefaults(),
                                                                                 libraryDirectory: { self.scratch }),
                                       presentPreview: { _ in }, account: .inMemory(), restoresSession: false)
        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: UnusedRunner(), storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        XCTAssertTrue(service.isMissing)
        service.installFromSteam()
        XCTAssertEqual(service.phase, .failed(WallpaperEngineAssetsService.Failure.steamCmdMissing.errorDescription ?? ""))
        steamCmd.steamCmdPath = "/usr/bin/false"
        service.installFromSteam()
        XCTAssertEqual(service.phase, .failed(WallpaperEngineAssetsService.Failure.notLoggedIn(account: nil).errorDescription ?? ""))
        XCTAssertFalse(service.isBusy)
    }

    /// A fake SteamCMD that reports the account doesn't own the app: the user is told so, and the
    /// download folder is gone afterwards.
    @MainActor
    func testANotOwnedAppIsReportedAndTheDownloadRemoved() throws {
        let runner = ScriptedRunner(output: "ERROR! Failed to install app '431960' (No subscription)", exitCode: 8)
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { self.scratch }),
                                       runner: runner, storageDirectory: { self.scratch },
                                       previewCacheRoot: scratch.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: makeDefaults(),
                                                                                 libraryDirectory: { self.scratch }),
                                       presentPreview: { _ in }, restoresSession: false)
        steamCmd.steamCmdPath = "/usr/bin/false"
        steamCmd.isLoggedIn = true
        steamCmd.steamUsername = "someone"
        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        service.installFromSteam()
        XCTAssertTrue(service.isBusy)
        let failed = expectation(description: "install finished")
        let cancellable = service.$phase.sink { if case .failed = $0 { failed.fulfill() } }
        wait(for: [failed], timeout: 10)
        cancellable.cancel()
        XCTAssertEqual(service.phase, .failed(WallpaperEngineAssetsService.Failure.notOwned.errorDescription ?? ""))
        XCTAssertEqual(runner.scripts.first?.lines.last, "app_update \"431960\" \"validate\"")
        XCTAssertFalse(FileManager.default.fileExists(atPath: WallpaperEngineAssetsDownload.downloadDirectory(in: scratch).path))
    }
}


extension WallpaperEngineAssetsInstallTests {
    /// The install with and without the default wallpapers: the assets land in the cache either
    /// way; the default wallpapers only when asked, and never an application one.
    @MainActor
    func testDefaultWallpapersComeInOnlyWhenAsked() throws {
        for includes in [true, false] {
            let storage = scratch.appending(path: "storage-\(includes)")
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let runner = InstallingRunner()
            let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { storage }),
                                           runner: runner, storageDirectory: { storage },
                                           previewCacheRoot: scratch.appending(path: "previews"),
                                           downloadedIndex: DownloadedWallpaperIndex(defaults: makeTestDefaults(),
                                                                                     libraryDirectory: { storage }),
                                           presentPreview: { _ in }, restoresSession: false)
            steamCmd.steamCmdPath = "/usr/bin/false"
            steamCmd.isLoggedIn = true
            steamCmd.steamUsername = "someone"
            let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { storage },
                                                       defaults: makeTestDefaults())
            service.installFromSteam(includingDefaultWallpapers: includes)
            let finished = expectation(description: "install finished")
            let cancellable = service.$phase.sink { phase in
                switch phase {
                case .idle, .failed: finished.fulfill()
                case .downloading, .copying: break
                }
            }
            wait(for: [finished], timeout: 10)
            cancellable.cancel()
            XCTAssertEqual(service.phase, .idle)
            XCTAssertTrue(WallpaperEngineAssets.isAssetTree(WallpaperEngineAssets.cacheDirectory(in: storage)))
            XCTAssertEqual(FileManager.default.fileExists(atPath: storage.appending(path: "aurora/project.json").path), includes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(path: "game").path))
            XCTAssertEqual(WallpaperEngineAssetsCache.readInfo(cache: WallpaperEngineAssets.cacheDirectory(in: storage))?.defaultProjects ?? [],
                           includes ? ["aurora"] : [])
        }
    }

    private func makeTestDefaults() -> UserDefaults {
        UserDefaults(suiteName: "owe-tests-\(UUID().uuidString)")!
    }
}

// MARK: - Steam session (the setup assistant's cached login, then Settings › Assets)

/// SteamCMD's real output when `login <account>` finds no cached login under `@NoPromptForPassword`:
/// "Loading Steam API...OK" is there, and steamcmd still exits 0 after `quit`.
let steamCmdNoCachedLoginOutput = """
Redirecting stderr to '/Users/me/Library/Application Support/Steam/logs/stderr.txt'
Steam Console Client (c) Valve Corporation - version 1726176498
-- type 'quit' to exit --
Loading Steam API...OK
Logging in user 'someone' to Steam Public...
Cached credentials not found.
password prompt disabled
"""

let steamCmdCachedLoginOutput = """
Loading Steam API...OK
Logging in using cached credentials.
Logging in user 'someone' [U:1:12345] to Steam Public...OK
Waiting for client config...OK
Waiting for user info...OK
"""

extension WallpaperEngineAssetsInstallTests {
    @MainActor
    private func makeSteamCmd(runner: SteamCmdRunning, account: SteamCmdAccountMemory) -> SteamCmdService {
        let storage: URL = scratch
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { storage }),
                                       runner: runner, storageDirectory: { storage },
                                       previewCacheRoot: storage.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: makeDefaults(),
                                                                                 libraryDirectory: { storage }),
                                       presentPreview: { _ in }, account: account, restoresSession: false)
        steamCmd.steamCmdPath = "/usr/bin/false"
        return steamCmd
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

    /// The reported bug: "I've Signed In" with no cached login used to count as a login, because
    /// "Loading Steam API...OK" and exit 0 passed for success; the install then failed with
    /// "Log in to Steam". The login now fails where the user made it.
    @MainActor
    func testACachedLoginWithoutASavedSessionIsNotALogin() {
        XCTAssertEqual(SteamCmdService.loginOutcome(output: steamCmdNoCachedLoginOutput), .noCachedLogin)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: "Loading Steam API...OK\n"), .failed)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: steamCmdCachedLoginOutput), .loggedIn)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: "Logged in OK\r\n"), .loggedIn)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: "Logging in user 'a' to Steam Public...FAILED (Rate Limit Exceeded)"), .failed)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: "This account is protected by a Steam Guard mobile authenticator."),
                       .guardCodeRequired)

        // Real SteamCMD output of logins that succeeded with Steam Guard: its success lines name
        // Steam Guard, which used to read as "code required".
        let withCode: String = """
            Steam>Logging in using username/password.
            Steam Guard code provided.
            Logging in user 'someone' [U:1:1] to Steam Public...OK
            Waiting for client config...OK
            Waiting for user info...OK
            """
        XCTAssertEqual(SteamCmdService.loginOutcome(output: withCode), .loggedIn)
        let withMobileConfirmation: String = """
            Logging in user 'someone' [U:1:1] to Steam Public...This account is protected by a Steam Guard mobile authenticator.
            Please confirm the login in the Steam Mobile app on your phone.

            Waiting for confirmation...
            Waiting for confirmation...OK
            Waiting for client config...OK
            Waiting for user info...OK
            """
        XCTAssertEqual(SteamCmdService.loginOutcome(output: withMobileConfirmation), .loggedIn)
        let unconfirmed: String = """
            Logging in user 'someone' [U:1:1] to Steam Public...This account is protected by a Steam Guard mobile authenticator.
            Please confirm the login in the Steam Mobile app on your phone.
            Waiting for confirmation...
            """
        XCTAssertEqual(SteamCmdService.loginOutcome(output: unconfirmed), .guardCodeRequired)

        let memory = SteamCmdAccountMemory.inMemory()
        let steamCmd = makeSteamCmd(runner: SteamSessionRunner(loginOutput: steamCmdNoCachedLoginOutput), account: memory)
        steamCmd.loginWithCachedSession(username: "someone", failureMessage: "no session")
        let failed = expectation(for: NSPredicate { _, _ in MainActor.assumeIsolated { steamCmd.loginError != nil } },
                                 evaluatedWith: nil)
        wait(for: [failed], timeout: 5)
        XCTAssertFalse(steamCmd.isLoggedIn)
        XCTAssertNil(memory.load(), "a failed login isn't remembered")
    }

    /// The exact sequence: cached login succeeds → the app is activated again (re-detection) →
    /// Settings › Assets › Install from Steam. The install runs with the account.
    @MainActor
    func testCachedLoginThenActivationThenInstallRuns() throws {
        let runner = SteamSessionRunner(loginOutput: steamCmdCachedLoginOutput)
        let steamcmd = scratch.appending(path: "bin/steamcmd")
        try FileManager.default.createDirectory(at: steamcmd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: steamcmd)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamcmd.path)
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { self.scratch }),
                                       runner: runner, storageDirectory: { self.scratch },
                                       previewCacheRoot: scratch.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: makeDefaults(),
                                                                                 libraryDirectory: { self.scratch }),
                                       presentPreview: { _ in },
                                       locator: { SteamCmdLocator(customPath: steamcmd.path, ownInstallDirectory: self.scratch,
                                                                  homeDirectory: self.scratch, systemRoot: self.scratch) },
                                       asksLoginShell: false, account: .inMemory(), restoresSession: false)
        steamCmd.detectSteamCmd()
        steamCmd.loginWithCachedSession(username: "someone")
        let loggedIn = expectation(for: NSPredicate { _, _ in MainActor.assumeIsolated { steamCmd.isLoggedIn } }, evaluatedWith: nil)
        wait(for: [loggedIn], timeout: 5)

        steamCmd.detectSteamCmd() // applicationDidBecomeActive, opening Settings
        XCTAssertTrue(steamCmd.isLoggedIn)
        XCTAssertEqual(steamCmd.steamUsername, "someone")

        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        service.installFromSteam(includingDefaultWallpapers: false)
        waitUntilSettled(service)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(WallpaperEngineAssets.isAssetTree(WallpaperEngineAssets.cacheDirectory(in: scratch)))
    }

    /// Not logged in this session, but an account is remembered: the install restores SteamCMD's
    /// cached session first instead of failing.
    @MainActor
    func testInstallRestoresTheRememberedSessionFirst() throws {
        let runner = SteamSessionRunner(loginOutput: steamCmdCachedLoginOutput)
        let memory = SteamCmdAccountMemory.inMemory("someone")
        let steamCmd = makeSteamCmd(runner: runner, account: memory)
        XCTAssertFalse(steamCmd.isLoggedIn)
        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        service.installFromSteam(includingDefaultWallpapers: false)
        XCTAssertTrue(service.isBusy)
        waitUntilSettled(service)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(steamCmd.isLoggedIn)
        XCTAssertEqual(runner.scripts.map { $0.lines.last ?? "" }, [#"login "someone""#, #"app_update "431960" "validate""#])
    }

    /// No session to restore: the error names the account and offers "Log In".
    @MainActor
    func testWithoutASessionTheErrorNamesTheAccount() {
        let runner = SteamSessionRunner(loginOutput: steamCmdNoCachedLoginOutput)
        let steamCmd = makeSteamCmd(runner: runner, account: .inMemory("someone"))
        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        service.installFromSteam()
        waitUntilSettled(service)
        XCTAssertEqual(service.lastFailure, .notLoggedIn(account: "someone"))
        guard case .failed(let message) = service.phase else { return XCTFail("\(service.phase)") }
        XCTAssertTrue(message.contains("someone"), message)
    }

    /// The session was there at login but SteamCMD lost it by the install: the app shows the
    /// account as logged out again, and the error names it.
    @MainActor
    func testAnInstallThatFindsNoSessionLogsOut() {
        let runner = SteamSessionRunner(loginOutput: steamCmdCachedLoginOutput, installOutput: steamCmdNoCachedLoginOutput)
        let steamCmd = makeSteamCmd(runner: runner, account: .inMemory())
        steamCmd.isLoggedIn = true
        steamCmd.steamUsername = "someone"
        let service = WallpaperEngineAssetsService(steamCmd: steamCmd, runner: runner, storageDirectory: { self.scratch },
                                                   defaults: makeDefaults())
        service.installFromSteam()
        waitUntilSettled(service)
        XCTAssertEqual(service.lastFailure, .notLoggedIn(account: "someone"))
        XCTAssertFalse(steamCmd.isLoggedIn)
    }
}

extension SteamCmdAccountMemory {
    /// Keeps the account in memory: tests never touch the Keychain.
    static func inMemory(_ initial: String? = nil) -> SteamCmdAccountMemory {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        box.value = initial
        return SteamCmdAccountMemory(load: { box.value }, save: { box.value = $0 })
    }
}

/// A fake SteamCMD: a `login`-only script prints `loginOutput`; an `app_update` one prints
/// `installOutput`, or installs like `InstallingRunner` when there is none.
private final class SteamSessionRunner: SteamCmdRunning, @unchecked Sendable {
    private let loginOutput: String
    private let installOutput: String?
    private let lock = NSLock()
    private var recorded: [SteamCmdScript] = [] // Owned by `lock`.
    var scripts: [SteamCmdScript] { lock.withLock { recorded } }

    init(loginOutput: String, installOutput: String? = nil) {
        self.loginOutput = loginOutput
        self.installOutput = installOutput
    }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        lock.withLock { recorded.append(script) }
        guard script.lines.contains(where: { $0.hasPrefix("app_update") }) else {
            return SteamCmdRun(output: loginOutput, exitCode: 0)
        }
        if let installOutput { return SteamCmdRun(output: installOutput, exitCode: 0) }
        return InstallingRunner().run(executable: executable, script: script, timeout: timeout, onOutput: onOutput)
    }
}

/// A fake SteamCMD that "downloads" a tiny Wallpaper Engine install where the script's
/// `force_install_dir` says: an asset tree and two default projects, one of them an application.
private final class InstallingRunner: SteamCmdRunning, @unchecked Sendable {
    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        guard let line = script.lines.first(where: { $0.hasPrefix("force_install_dir ") }) else {
            return SteamCmdRun(output: "no install dir", exitCode: 1)
        }
        let path = String(line.dropFirst("force_install_dir ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let install = URL(fileURLWithPath: path, isDirectory: true)
        let files: [(String, String)] = [
            ("assets/shaders/common.h", "x"), ("assets/effects/tint/effect.json", "{}"),
            ("projects/defaultprojects/aurora/project.json", #"{"title":"A","file":"scene.json","type":"scene"}"#),
            ("projects/defaultprojects/game/project.json", #"{"title":"G","file":"game.exe","type":"application"}"#),
        ]
        do {
            for (relative, text) in files {
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

private struct UnusedRunner: SteamCmdRunning {
    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        XCTFail("steamcmd must not run")
        return SteamCmdRun(output: "", exitCode: -1)
    }
}

private final class ScriptedRunner: SteamCmdRunning, @unchecked Sendable {
    let output: String
    let exitCode: Int32
    private let lock = NSLock()
    private var recorded: [SteamCmdScript] = []
    var scripts: [SteamCmdScript] { lock.withLock { recorded } }

    init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        lock.withLock { recorded.append(script) }
        onOutput(output)
        return SteamCmdRun(output: output, exitCode: exitCode)
    }
}
