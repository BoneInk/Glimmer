import CryptoKit
import Foundation

/// The web and application wallpapers the user trusted ("Don't ask again for this wallpaper"),
/// each bound to a fingerprint of its folder's content when trust was given: a Workshop update,
/// or another item downloaded to the same folder, asks again.
///
/// Stored in the defaults as the trusted folders' paths (`TrustedWallpapers`, as before) and a
/// fingerprint per path (`TrustedWallpaperFingerprints`). A path trusted before fingerprints
/// existed has none: it is bound to the content found the first time it is checked, so updating
/// the app asks no one again.
struct WallpaperTrustStore {
    static let pathsKey = "TrustedWallpapers"
    static let fingerprintsKey = "TrustedWallpaperFingerprints"

    enum Verdict: Equatable {
        /// Trusted, and the folder holds what was trusted.
        case trusted
        /// Never trusted.
        case untrusted
        /// Trusted, but the folder's content changed since.
        case changed
    }

    var defaults: UserDefaults = .app

    /// Whether the wallpaper's folder is on the trust list, whatever it holds now. Cheap: for
    /// filters that only need to leave out wallpapers that would certainly ask.
    func isListed(_ wallpaper: WEWallpaper) -> Bool {
        paths.contains(Self.key(of: wallpaper))
    }

    /// Whether `fingerprint`, the folder's content now, is what was trusted. A listed folder
    /// without a fingerprint (trusted before fingerprints existed) is bound to `fingerprint` here.
    func verdict(for wallpaper: WEWallpaper, fingerprint: String) -> Verdict {
        let path = Self.key(of: wallpaper)
        guard paths.contains(path) else { return .untrusted }
        var fingerprints = self.fingerprints
        guard let recorded = fingerprints[path] else {
            fingerprints[path] = fingerprint
            defaults.set(fingerprints, forKey: Self.fingerprintsKey)
            OWELog.info(.library, "Bound the trust given to \(wallpaper.wallpaperDirectory.lastPathComponent) to its content")
            return .trusted
        }
        return recorded == fingerprint ? .trusted : .changed
    }

    /// Reads the folder (`fingerprint(of:)`): call it where waiting on the disk is fine.
    func verdict(for wallpaper: WEWallpaper) -> Verdict {
        verdict(for: wallpaper, fingerprint: Self.fingerprint(of: wallpaper))
    }

    /// Trusts the wallpaper's folder as it is now (`fingerprint`).
    func trust(_ wallpaper: WEWallpaper, fingerprint: String) {
        let path = Self.key(of: wallpaper)
        defaults.set(Self.trustList(paths, adding: path), forKey: Self.pathsKey)
        var fingerprints = self.fingerprints
        fingerprints[path] = fingerprint
        defaults.set(fingerprints, forKey: Self.fingerprintsKey)
    }

    /// Forgets every trusted wallpaper.
    func reset() {
        defaults.set([String](), forKey: Self.pathsKey)
        defaults.removeObject(forKey: Self.fingerprintsKey)
    }

    /// `trusted` with `path` added once, earlier duplicates dropped, in the order trust was given.
    static func trustList(_ trusted: [String], adding path: String) -> [String] {
        var seen = Set<String>()
        return (trusted + [path]).filter { seen.insert($0).inserted }
    }

    private var paths: [String] {
        defaults.array(forKey: Self.pathsKey) as? [String] ?? []
    }

    private var fingerprints: [String: String] {
        defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String] ?? [:]
    }

    private static func key(of wallpaper: WEWallpaper) -> String {
        wallpaper.wallpaperDirectory.path(percentEncoded: false)
    }

    // MARK: - Fingerprint

    static func fingerprint(of wallpaper: WEWallpaper) -> String {
        fingerprint(directory: wallpaper.wallpaperDirectory, type: wallpaper.project.type, entry: wallpaper.project.file)
    }

    /// A SHA-256 over the wallpaper's type and entry file and, for every file in its folder, the
    /// relative path, size and modification date. Only metadata is read, so it stays cheap for a
    /// folder of many files, but it walks the whole folder: call it off the main thread where it
    /// can wait. Left out: project.json, whose title and tags the app itself edits (the type and
    /// entry it decides on are hashed instead), and hidden files such as Finder's `.DS_Store`.
    static func fingerprint(directory: URL, type: String, entry: String) -> String {
        var lines: [String] = []
        let root = directory.path(percentEncoded: false)
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            while let relative = enumerator.nextObject() as? String {
                let attributes = enumerator.fileAttributes ?? [:]
                let kind = attributes[.type] as? FileAttributeType
                if (relative as NSString).lastPathComponent.hasPrefix(".") {
                    if kind == .typeDirectory { enumerator.skipDescendants() }
                    continue
                }
                guard relative != "project.json", kind != .typeDirectory else { continue }
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                lines.append("\(relative)\t\(kind?.rawValue ?? "?")\t\(size)\t\(modified)")
            }
        } else {
            OWELog.error(.library, "Can't list \(root) to fingerprint it for trust")
        }
        var hash = SHA256()
        hash.update(data: Data("\(type.lowercased())\n\(entry)\n".utf8))
        for line in lines.sorted() {
            hash.update(data: Data(line.utf8))
            hash.update(data: Data([0x0A]))
        }
        return Digest.hex(hash.finalize())
    }
}
