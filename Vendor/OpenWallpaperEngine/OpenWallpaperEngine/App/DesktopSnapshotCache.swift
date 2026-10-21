import AppKit

/// OWE's desktop-picture folder (`<Caches>/Open Wallpaper Engine/DesktopSnapshots`), where each
/// display's picture is kept (`LockScreenPicture`, set by `DesktopPictureSync`), and whether this
/// process may change the desktop picture at all. Full-screen TIFFs (20–60 MB each) written under
/// a per-launch name (`staticWP_<hash>.tiff`) by earlier versions are moved to the Trash.
struct DesktopSnapshotCache {
    static let legacyPrefix = "staticWP_"
    /// Set to `1` to let an isolated copy change the desktop picture anyway (a test of that path).
    static let allowInIsolationKey = "OWE_ALLOW_DESKTOP_PICTURE"

    /// Whether this process may change the system desktop picture. The picture belongs to the
    /// user's session, not to OWE's state, so an isolated copy (`AppStorageLocation`) never sets,
    /// saves or restores it unless `allowInIsolationKey` asks for it: otherwise a test run leaves
    /// its snapshots as the desktop picture, and the user's own copy saves them as "the user's".
    static func allowsDesktopPicture(isIsolated: Bool, environment: [String: String]) -> Bool {
        !isIsolated || environment[allowInIsolationKey] == "1"
    }

    static let mayChangeDesktopPicture = allowsDesktopPicture(
        isIsolated: AppStorageLocation.current.isIsolated, environment: ProcessInfo.processInfo.environment)

    /// Where the pictures are written.
    let directory: URL
    /// The folder earlier versions wrote `staticWP_*.tiff` into.
    let legacyDirectory: URL

    static var current: DesktopSnapshotCache {
        DesktopSnapshotCache(cachesDirectory: AppStorageLocation.current.cachesDirectory)
    }

    init(cachesDirectory: URL) {
        directory = cachesDirectory.appending(path: "Open Wallpaper Engine/DesktopSnapshots", directoryHint: .isDirectory)
        legacyDirectory = cachesDirectory
    }

    // MARK: Names

    /// Whether `url` is a picture OWE set, not the user's own (current or legacy name).
    /// Any copy's snapshot counts, an isolated copy's included, so one is never saved as the
    /// user's picture.
    func isSnapshot(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.path == directory.standardizedFileURL.path
            || Self.isAnySnapshotFolder(parent)
            || url.lastPathComponent.hasPrefix(Self.legacyPrefix)
    }

    /// `<Caches>[/Open Wallpaper Engine (isolated <tag>)]/Open Wallpaper Engine/DesktopSnapshots`.
    private static func isAnySnapshotFolder(_ folder: URL) -> Bool {
        let components = folder.pathComponents
        return components.count >= 2 && components.suffix(2) == ["Open Wallpaper Engine", "DesktopSnapshots"]
    }

    // MARK: Cleanup

    /// The `staticWP_*.tiff` files earlier versions left in the Caches folder.
    func legacySnapshots() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(Self.legacyPrefix) && $0.pathExtension == "tiff" }
    }

    /// Moves the legacy snapshots to the Trash (they sit in the shared Caches folder, so they are
    /// never deleted outright). `dispose` is the move (tests pass their own).
    func trashLegacySnapshots(dispose: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        for url in legacySnapshots() {
            do { try dispose(url) } catch {
                OWELog.error(.app, "Moving an old desktop snapshot to the Trash failed: \(error)")
            }
        }
    }

    // MARK: Displays

    /// The display id of `screen`.
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
