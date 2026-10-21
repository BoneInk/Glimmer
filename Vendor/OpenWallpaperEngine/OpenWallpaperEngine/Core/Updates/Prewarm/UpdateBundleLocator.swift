import Foundation

/// Finds the app bundle Sparkle extracted for an update. Sparkle doesn't expose it: its installer
/// unpacks the archive into `<Caches>/<bundle id>/org.sparkle-project.Sparkle/Installation/<unique>/<unique>/`
/// (`SPULocalCacheDirectory`, `AppInstaller`), and the bundle is the `.app` there whose identifier
/// is this app's and whose `CFBundleVersion` is the appcast item's version.
struct UpdateBundleLocator {
    static let sparkleBundleIdentifier = "org.sparkle-project.Sparkle"
    /// `Installation/<unique>/<unique>/<name>.app`, and one more level for safety.
    private static let maximumDepth = 4

    var installationDirectory: URL
    var bundleIdentifier: String

    /// Sparkle's installation cache for `bundleIdentifier`, as its installer (which is not
    /// sandboxed, like this app) computes it.
    init(bundleIdentifier: String, cachesDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        self.bundleIdentifier = bundleIdentifier
        // Sparkle appends ".sparkle" to identifiers that end like a bundle extension; ours doesn't.
        installationDirectory = cachesDirectory
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: Self.sparkleBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Installation", directoryHint: .isDirectory)
    }

    init(installationDirectory: URL, bundleIdentifier: String) {
        self.installationDirectory = installationDirectory
        self.bundleIdentifier = bundleIdentifier
    }

    /// The newest matching bundle, nil when there is none.
    func bundle(version: String) -> URL? {
        var matches: [(url: URL, modified: Date)] = []
        collect(in: installationDirectory, depth: 0, version: version, into: &matches)
        return matches.max { $0.modified < $1.modified }?.url
    }

    private func collect(in directory: URL, depth: Int, version: String, into matches: inout [(url: URL, modified: Date)]) {
        guard depth < Self.maximumDepth else { return }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        } catch {
            // The cache or one of its unique folders is gone (Sparkle cleans it up): no bundle there.
            return
        }
        for entry in entries {
            // Optional: an entry that vanished or isn't a folder is skipped.
            let values: URLResourceValues? = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            if entry.pathExtension == "app" {
                if matchesUpdate(entry, version: version) {
                    matches.append((entry, values?.contentModificationDate ?? .distantPast))
                }
            } else {
                collect(in: entry, depth: depth + 1, version: version, into: &matches)
            }
        }
    }

    private func matchesUpdate(_ bundleURL: URL, version: String) -> Bool {
        let infoURL: URL = bundleURL.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
            && info["CFBundleVersion"] as? String == version
    }

    /// The bundle's main executable.
    static func executable(of bundleURL: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: bundleURL.appending(path: "Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String else { return nil }
        let url: URL = bundleURL.appending(path: "Contents/MacOS").appending(path: name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
