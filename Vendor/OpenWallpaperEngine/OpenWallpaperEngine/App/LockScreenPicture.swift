import AppKit

/// The files and records behind each display's desktop picture (`DesktopPictureSync`): the
/// picture OWE sets, which the lock screen and the menu bar's tint show, and the user's own
/// pictures to put back.
///
/// - **Files.** A display's picture is OWE's own copy in its desktop-picture folder
///   (`DesktopSnapshotCache`) as `lock-<display>-<serial>.<heic|jpg>`, never a file of a cache that
///   trims itself (the loading snapshots, the video frames), so a picture in use can't vanish.
///   Every picture gets a new name, written in full under a hidden one and renamed into place
///   before it is set: macOS's wallpaper agent caches decoded pictures by URL and pixel size, so
///   a picture written again under a name it had read (the earlier `a`/`b` slots) showed the
///   older picture, or black, in System Settings › Wallpaper until another display was chosen
///   (its log: a cache insertion for `lock-1-b.heic` still running when OWE replaced that file).
///   The newest `kept` of each display stay while the app runs and after it quits: desktop
///   pictures are per Space, and a Space OWE can't reach now may still show an earlier one (a
///   Space change shows the current one again). `DesktopSnapshotCache.isSnapshot` never saves
///   one as the user's.
/// - **The user's pictures.** The first time a display's picture is replaced, the picture it
///   showed is recorded per display (`originalsKey`); turning the pictures off, or quitting, puts
///   them back when they still exist.
/// - **Isolation.** An isolated copy never sets, saves or restores the picture
///   (`DesktopSnapshotCache.mayChangeDesktopPicture`).
struct LockScreenPicture: @unchecked Sendable { // UserDefaults is thread-safe; the rest is immutable.
    static let prefix = "lock-"
    /// `[display id: picture URL]` of the pictures shown before OWE replaced them.
    static let originalsKey = "LockScreenOriginalPictures"

    let cache: DesktopSnapshotCache
    let defaults: UserDefaults
    /// The files' prefix: `prefix` for the pictures set as the desktop's, `saverPrefix` for the
    /// screen saver's own stills (`DesktopPictureSync.setsPictures` false).
    var namePrefix = Self.prefix

    static let saverPrefix = "saver-"

    static var current: LockScreenPicture { LockScreenPicture(cache: .current, defaults: .app) }

    // MARK: Names

    /// How many pictures of each display stay on disk: the newest, which the current Space shows,
    /// and a few earlier ones other Spaces may still show.
    static let kept = 4

    /// The picture named `serial` of `display`.
    func url(display: CGDirectDisplayID, serial: String, fileExtension: String) -> URL {
        cache.directory.appending(path: "\(namePrefix)\(display)-\(serial).\(fileExtension)", directoryHint: .notDirectory)
    }

    /// Whether `url` is a lock-screen picture OWE set.
    func isLockPicture(_ url: URL) -> Bool {
        cache.isSnapshot(url) && url.lastPathComponent.hasPrefix(namePrefix)
    }

    /// The serial of a new picture: the time in milliseconds, base 36, so names sort by age
    /// (an earlier version's `a` and `b` sort first).
    static func serial(at date: Date = Date()) -> String {
        String(UInt64(max(date.timeIntervalSince1970, 0) * 1000), radix: 36)
    }

    /// `display`'s pictures in the folder, oldest first.
    func pictures(of display: CGDirectDisplayID) -> [URL] {
        let prefix = "\(namePrefix)\(display)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)) ?? [] // Optional: no folder yet.
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && SceneLoadingSnapshotStore.extensions.contains($0.pathExtension.lowercased()) }
            .map { (url: $0, serial: serialValue(of: $0, display: display)) }
            .sorted { ($0.serial, $0.url.lastPathComponent) < ($1.serial, $1.url.lastPathComponent) }
            // Named in the folder's own form (the listing resolves `/var` to `/private/var`).
            .map { cache.directory.appending(path: $0.url.lastPathComponent, directoryHint: .notDirectory) }
    }

    /// The serial of `display`'s picture `url` as a number; 0 when it has none.
    private func serialValue(of url: URL, display: CGDirectDisplayID) -> UInt64 {
        UInt64(url.deletingPathExtension().lastPathComponent.dropFirst("\(namePrefix)\(display)-".count), radix: 36) ?? 0
    }

    // MARK: The user's pictures

    func originals() -> [CGDirectDisplayID: URL] {
        let stored = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        var result: [CGDirectDisplayID: URL] = [:]
        for (key, value) in stored {
            guard let id = CGDirectDisplayID(key), let url = URL(string: value) else { continue }
            result[id] = url
        }
        return result
    }

    /// Records what `display` shows as the user's picture, unless it is one of OWE's own or one is
    /// already recorded (the first replaced picture is the user's).
    func recordOriginal(_ showing: URL?, display: CGDirectDisplayID) {
        guard let showing, !cache.isSnapshot(showing) else { return }
        var stored = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        guard stored[String(display)] == nil else { return }
        stored[String(display)] = showing.absoluteString
        defaults.set(stored, forKey: Self.originalsKey)
    }

    /// Forgets the recorded pictures of `displays`, all of them for nil.
    func forgetOriginals(of displays: [CGDirectDisplayID]? = nil) {
        guard let displays else { return defaults.removeObject(forKey: Self.originalsKey) }
        var stored = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        for display in displays { stored[String(display)] = nil }
        defaults.set(stored, forKey: Self.originalsKey)
    }

    /// The picture to put back on each display that shows one of OWE's pictures now: its recorded
    /// original, else `fallback` (the main display's picture at launch, `OSWallpaper`), whichever
    /// still exists and isn't OWE's. A display with neither keeps OWE's picture, which stays on
    /// disk: never a missing file.
    func restorePlan(showing: [CGDirectDisplayID: URL?], fallback: URL?,
                     exists: (URL) -> Bool = LockScreenPicture.fileExists) -> [CGDirectDisplayID: URL] {
        let originals = originals()
        func usable(_ url: URL?) -> URL? {
            guard let url, !cache.isSnapshot(url), exists(url) else { return nil }
            return url
        }
        var plan: [CGDirectDisplayID: URL] = [:]
        for (display, url) in showing {
            guard let url, cache.isSnapshot(url), let original = usable(originals[display]) ?? usable(fallback) else { continue }
            plan[display] = original
        }
        return plan
    }

    /// The picture to save as the user's (`OSWallpaper`): the saved one while it still exists and
    /// isn't OWE's, else the one shown now if that is the user's; nil keeps nothing (an earlier
    /// run left OWE's picture showing).
    func userPicture(saved: URL?, showing: URL?, exists: (URL) -> Bool = LockScreenPicture.fileExists) -> URL? {
        for url in [saved, showing].compactMap({ $0 }) where !cache.isSnapshot(url) && exists(url) { return url }
        return nil
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: Writing

    /// Copies `snapshot` as the display's new picture and returns its URL.
    func write(snapshot: URL, display: CGDirectDisplayID, showing: URL?) throws -> URL {
        try place(display: display, showing: showing, fileExtension: snapshot.pathExtension.lowercased()) { staging in
            try FileManager.default.copyItem(at: snapshot, to: staging)
        }
    }

    /// Writes an encoded picture as the display's new picture and returns its URL.
    func write(_ data: Data, fileExtension: String, display: CGDirectDisplayID, showing: URL?) throws -> URL {
        try place(display: display, showing: showing, fileExtension: fileExtension) { staging in
            try data.write(to: staging)
        }
    }

    /// Writes the new picture under a hidden name (`write`), renames it to a name no earlier
    /// picture had, so it is complete whenever it is seen, and removes the display's pictures
    /// beyond the newest `kept`, the new one included (never `showing`).
    private func place(display: CGDirectDisplayID, showing: URL?, fileExtension: String,
                       write: (URL) throws -> Void) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let existing = pictures(of: display)
        // Never an earlier name: later than the newest, even within a millisecond or with the
        // clock set back.
        let newest = existing.last.map { serialValue(of: $0, display: display) } ?? 0
        let now = UInt64(Self.serial(), radix: 36) ?? 0
        let target = url(display: display, serial: String(max(now, newest + 1), radix: 36), fileExtension: fileExtension)
        let staging = cache.directory.appending(path: ".\(UUID().uuidString).\(fileExtension)", directoryHint: .notDirectory)
        do {
            try write(staging)
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging) // Optional: the failed attempt's leftover.
            throw error
        }
        // Compared with symbolic links resolved: the picture shown may be named another way.
        let shown = showing?.resolvingSymlinksInPath().path(percentEncoded: false)
        for old in existing.dropLast(max(Self.kept - 1, 0)) where old.resolvingSymlinksInPath().path(percentEncoded: false) != shown {
            try? fileManager.removeItem(at: old) // Optional: another Space's older picture.
        }
        return target
    }
}
