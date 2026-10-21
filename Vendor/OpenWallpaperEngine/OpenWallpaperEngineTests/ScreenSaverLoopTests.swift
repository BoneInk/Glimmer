import XCTest
@testable import OpenWallpaperEngine

/// The loops' crossfade and frame signature the exports use, and the screen saver's folder:
/// isolation, and what earlier versions left in it.
final class ScreenSaverLoopTests: XCTestCase {
    // MARK: Seam

    func testCrossfadeWeightRisesOverTheLastFramesOnly() {
        XCTAssertEqual(ScreenSaverSeamFinder.crossfadeWeight(index: 5, loopFrames: 10, fade: 4), 0)
        XCTAssertEqual(ScreenSaverSeamFinder.crossfadeWeight(index: 6, loopFrames: 10, fade: 4), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ScreenSaverSeamFinder.crossfadeWeight(index: 9, loopFrames: 10, fade: 4), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ScreenSaverSeamFinder.crossfadeWeight(index: 9, loopFrames: 10, fade: 0), 0)
    }

    func testFrameSignatureDifference() throws {
        let black = try XCTUnwrap(ScreenSaverFrameSignature(Self.image(gray: 0)))
        let white = try XCTUnwrap(ScreenSaverFrameSignature(Self.image(gray: 255)))
        XCTAssertEqual(black.difference(black), 0)
        XCTAssertGreaterThan(black.difference(white), 0.4)
        XCTAssertEqual(black.difference(ScreenSaverFrameSignature(values: [])), 1)
    }

    private static func image(gray: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: CGFloat(gray) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        return context.makeImage()!
    }
}

final class ScreenSaverStorageTests: XCTestCase {
    func testIsolatedCopiesWriteWhereNoSaverReads() throws {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let isolated = ScreenSaverVideoStore(location: AppStorageLocation(isolationTag: "screensaver-test"), home: home)
        XCTAssertFalse(isolated.directory.path.hasPrefix(ScreenSaverManifest.sharedFolder(home: home).path))
        XCTAssertTrue(isolated.directory.path.contains("isolated screensaver-test"))
        let user = ScreenSaverVideoStore(location: AppStorageLocation(isolationTag: nil), home: home)
        XCTAssertEqual(user.directory, ScreenSaverManifest.sharedFolder(home: home))
        XCTAssertTrue(user.directory.path.hasPrefix(
            "/Users/someone/Library/Application Support/Open Wallpaper Engine/ScreenSaver"))
        // The test host itself is isolated.
        XCTAssertNotEqual(ScreenSaverVideoStore.current.directory, ScreenSaverManifest.sharedFolder(home: ScreenSaverManifest.userHome))
    }

    func testSaverReadsTheRealHomeNotItsContainer() {
        XCTAssertFalse(ScreenSaverManifest.userHome.path.contains("/Library/Containers/"))
        XCTAssertEqual(ScreenSaverManifest.userHome.standardizedFileURL,
                       URL(filePath: NSHomeDirectoryForUser(NSUserName()) ?? "", directoryHint: .isDirectory).standardizedFileURL)
    }

    func testInstallerNeverTouchesTheUsersSaversWhenIsolated() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundled = folder.appending(path: "bundled.saver", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let savers = folder.appending(path: "Screen Savers", directoryHint: .isDirectory)
        let isolated = ScreenSaverInstaller(bundledSaver: bundled, saversDirectory: savers, mayInstall: false)
        XCTAssertFalse(isolated.install())
        XCTAssertFalse(isolated.isInstalled)
        XCTAssertFalse(ScreenSaverInstaller.current.mayInstall, "the test host is isolated")
        let user = ScreenSaverInstaller(bundledSaver: bundled, saversDirectory: savers, mayInstall: true)
        XCTAssertTrue(user.install())
        XCTAssertTrue(user.isInstalled)
        user.uninstall()
        XCTAssertFalse(user.isInstalled)
    }

    func testTurningOffKeepsTheStills() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScreenSaverVideoStore(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: store.url(fileName: name).path(percentEncoded: false)) }
        let stills = [ScreenSaverStills.fileName, "still-A.heic", "still-pick.jpg", ".1F2E-still-B.heic"]
        for name in [ScreenSaverLiveManifest.fileName] + stills {
            try Data().write(to: store.url(fileName: name))
        }
        store.removeAll()
        XCTAssertFalse(exists(ScreenSaverLiveManifest.fileName))
        for still in stills { XCTAssertTrue(exists(still), "\(still): turning the plugin off keeps the stills") }
        for still in stills { try FileManager.default.removeItem(at: store.url(fileName: still)) }
        try Data().write(to: store.url(fileName: "again.json"))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "an emptied folder goes")
    }

    func testHelperRunArgumentsAreReadOnlyHelperRuns() {
        XCTAssertTrue(HelperRunCommand.isHelperRun(arguments: ["app", HelperRunCommand.prepareArgument]))
        XCTAssertFalse(HelperRunCommand.isHelperRun(arguments: ["app", "--render-screensaver-loop"]), "the loop render is gone")
        XCTAssertEqual(HelperRunCommand.size("3840x2160"), SIMD2(3840, 2160))
        XCTAssertNil(HelperRunCommand.size("3840"))
        XCTAssertNil(HelperRunCommand.size("0x10"))
    }

    // MARK: Earlier versions' recordings

    func testOnlyOWEsOwnRecordingNamesAreOldRecordings() {
        XCTAssertTrue(ScreenSaverVideoStore.isOldRecording("ab12_cd34-0a1b2c3d4e5f-3840x2160-r3.mov"))
        XCTAssertTrue(ScreenSaverVideoStore.isOldRecording("ab12_cd34-0a1b2c3d4e5f-1920x1080-r2-rec1790000000.mov"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldRecording("ab12_cd34-video-r3.mp4"), "a video wallpaper's own file")
        XCTAssertFalse(ScreenSaverVideoStore.isOldRecording("ab12_cd34-video-r3-rec1790000000.mov"), "a video set as the screen saver")
        XCTAssertFalse(ScreenSaverVideoStore.isOldRecording("holiday.mov"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldRecording("still-A.heic"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldRecording(ScreenSaverVideoStore.oldVideoManifest))
    }

    func testOldRecordingsAndVideoFilesAreDeletedAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shared = folder.appending(path: "ScreenSaver", directoryHint: .isDirectory)
        let caches = folder.appending(path: "Caches", directoryHint: .isDirectory)
        let staging = caches.appending(path: "ScreenSaverRecordings", directoryHint: .isDirectory)
        let elsewhere = folder.appending(path: "Library", directoryHint: .isDirectory)
        let folderNamedLikeAVideo = "sub_c-video-r3.mp4"
        for dir in [shared, staging, elsewhere, shared.appending(path: "sub-0a1b2c3d4e5f-1x1-r1.mov"),
                    shared.appending(path: folderNamedLikeAVideo)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let loop = "w_c-0a1b2c3d4e5f-3840x2160-r3.mov", recording = "w_c-0a1b2c3d4e5f-3840x2160-r3-rec42.mov"
        let copy = "v_c-video-r3.mp4", selected = "s_c-video-r3-rec1790000000.mov"
        let stagingCopy = ".staging-1B4E28BA-2FA1-11D2-883F-0016D3CCA427.m4v"
        let others = ["still-A.heic", ScreenSaverStills.fileName, ScreenSaverLiveManifest.fileName, "holiday.mov", "notes-video-r3.txt"]
        for name in [loop, recording, copy, selected, stagingCopy, ScreenSaverVideoStore.oldVideoManifest] + others {
            try Data("x".utf8).write(to: shared.appending(path: name))
        }
        try Data("x".utf8).write(to: staging.appending(path: recording))
        // The library's files: one hard-linked in, one linked symbolically under a recording's
        // name, one under a video file's. Links go; what they point to stays.
        let libraryFile = elsewhere.appending(path: "clip.mov"), libraryVideo = elsewhere.appending(path: "video.mp4")
        try Data("library".utf8).write(to: libraryFile)
        try Data("video".utf8).write(to: libraryVideo)
        let hardLink = "h_c-video-r3.mp4"
        try FileManager.default.linkItem(at: libraryVideo, to: shared.appending(path: hardLink))
        let recordingLink = "l_c-0a1b2c3d4e5f-640x480-r3.mov", videoLink = "y_c-video-r2.mov"
        try FileManager.default.createSymbolicLink(at: shared.appending(path: recordingLink), withDestinationURL: libraryFile)
        try FileManager.default.createSymbolicLink(at: shared.appending(path: videoLink), withDestinationURL: libraryVideo)

        ScreenSaverVideoStore(directory: shared).removeOldFiles(cachesDirectory: caches)

        let left = try Set(FileManager.default.contentsOfDirectory(atPath: shared.path(percentEncoded: false)))
        XCTAssertEqual(left, Set(others + [recordingLink, "sub-0a1b2c3d4e5f-1x1-r1.mov", folderNamedLikeAVideo]))
        XCTAssertEqual(try String(contentsOf: libraryFile, encoding: .utf8), "library")
        XCTAssertEqual(try String(contentsOf: libraryVideo, encoding: .utf8), "video", "the library's video stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)), "the emptied staging folder goes")
    }

    func testOnlyOWEsOwnVideoFileNamesAreOldVideoFiles() {
        XCTAssertTrue(ScreenSaverVideoStore.isOldVideoFile("ab12_cd34-video-r3.mp4"))
        XCTAssertTrue(ScreenSaverVideoStore.isOldVideoFile("ab12_cd34-video-r3-rec1790000000.mov"))
        XCTAssertTrue(ScreenSaverVideoStore.isOldVideoFile(".staging-1B4E28BA-2FA1-11D2-883F-0016D3CCA427.mp4"))
        XCTAssertTrue(ScreenSaverVideoStore.isOldVideoFile("current.json"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldVideoFile("holiday.mov"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldVideoFile("ab12_cd34-video-r3.webm"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldVideoFile("ab12-video-r3.mp4.partial"))
        XCTAssertFalse(ScreenSaverVideoStore.isOldVideoFile(ScreenSaverLiveManifest.fileName))
        XCTAssertFalse(ScreenSaverVideoStore.isOldVideoFile("still-A.heic"))
    }

    func testRetiredSettingsAreRemovedAndOldSelectionsStillDecode() throws {
        let suite = "owe-screensaver-retired-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"isEnabled":true,"hour":6,"minute":30}"#.utf8), forKey: "ScreenSaverSchedule")
        // A selection as earlier versions saved it, recording fields and all.
        defaults.set(Data(#"{"wallpaperDirectory":"/w/1","fileName":"a-rec1.mov","width":1920,"height":1080,"recorded":0}"#.utf8),
                     forKey: ScreenSaverSettingsStore.selectionKey)
        let store = ScreenSaverSettingsStore(defaults: defaults)
        store.removeRetiredKeys()
        XCTAssertNil(defaults.object(forKey: "ScreenSaverSchedule"))
        XCTAssertEqual(store.selection?.wallpaperDirectory, "/w/1")
        XCTAssertNil(store.livePick)
        store.removeRetiredKeys()
        // It becomes the live pick of its wallpaper (a video's too: drawn live now).
        XCTAssertTrue(store.migrateSelection())
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.livePick?.wallpaperDirectory, "/w/1")
        XCTAssertFalse(store.migrateSelection(), "once")
    }

    func testAnUnreadableOldSelectionIsDroppedAndAPickIsKept() throws {
        let suite = "owe-screensaver-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScreenSaverSettingsStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: ScreenSaverSettingsStore.selectionKey)
        XCTAssertFalse(store.migrateSelection())
        XCTAssertNil(defaults.object(forKey: ScreenSaverSettingsStore.selectionKey), "dropped harmlessly")
        XCTAssertNil(store.livePick)

        let pick = ScreenSaverSettingsStore.LivePick(wallpaperDirectory: "/w/scene", picked: Date(timeIntervalSince1970: 1))
        store.livePick = pick
        store.selection = .init(wallpaperDirectory: "/w/video", fileName: "v-video-r3-rec1.mp4", width: 1, height: 1, recorded: Date())
        XCTAssertFalse(store.migrateSelection(), "a pick made since stays the screen saver")
        XCTAssertEqual(store.livePick, pick)
        XCTAssertNil(store.selection)
    }
}
