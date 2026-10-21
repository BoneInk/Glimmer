import Foundation

/// Checking and unpacking a downloaded CEF archive. Nothing here trusts the archive before its
/// SHA-256 matches the pin (`VersionedInstallStore.fetch`).
enum ChromiumEnginePackage {
    static let frameworkName = "Chromium Embedded Framework.framework"
    static let frameworkBinary = "Chromium Embedded Framework"
    /// Written last into an install folder; a folder without it is not an install.
    static let manifestName = ".owe-chromium-engine.json"

    struct Manifest: Codable, Equatable {
        let version: String
        let platform: String
        let sha256: String
    }

    enum Failure: LocalizedError, Equatable {
        case checksumMismatch(expected: String, actual: String)
        case notBzip2
        case extractionFailed(String)
        case missingFramework

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return String(localized: "The Chromium download doesn't match the version this app expects, so it wasn't installed. Try again later.",
                              comment: "Chromium engine install error: the downloaded file's checksum is wrong")
            case .notBzip2:
                return String(localized: "The Chromium download isn't a valid archive. Try again later.",
                              comment: "Chromium engine install error")
            case .extractionFailed(let reason):
                return String(localized: "Can't unpack the Chromium engine: \(reason)",
                              comment: "Chromium engine install error; %@ is the system's reason")
            case .missingFramework:
                return String(localized: "The Chromium download has no Chromium Embedded Framework.",
                              comment: "Chromium engine install error; Chromium Embedded Framework is a product name")
            }
        }
    }

    /// Throws unless `archive` starts with bzip2's "BZh" magic.
    static func checkBzip2(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() } // Closing a read handle has nothing to report.
        guard try handle.read(upToCount: 3) == Data("BZh".utf8) else { throw Failure.notBzip2 }
    }

    /// Where an install folder keeps the framework and helpers: CEF's macOS app layout,
    /// `<version>/OWE Chromium.app/Contents/Frameworks`. CEF's sandbox allows reading its main
    /// bundle, so everything CEF loads has to be inside this one bundle.
    static func frameworksFolder(in folder: URL) -> URL {
        folder.appending(path: "\(ChromiumHelperIPC.engineBundleName)/Contents/Frameworks", directoryHint: .isDirectory)
    }

    /// Unpacks the framework and license of the verified `archive` into `destination` (which must
    /// not exist yet), assembles the engine bundle around the framework with the helpers from
    /// `helpers` (the app's `Contents/Helpers`; nil copies none) and writes the manifest last.
    /// `scratch` is an empty folder for tar's output.
    static func unpack(_ archive: URL, pin: ChromiumEnginePin, scratch: URL, into destination: URL,
                       helpers: URL? = nil) throws {
        try checkBzip2(archive)
        let root = pin.archiveRoot
        let framework = "\(root)/Release/\(frameworkName)"
        let license = "\(root)/LICENSE.txt"
        try runTar(["-xjof", archive.path, "-C", scratch.path, framework, license])

        let fileManager = FileManager.default
        let unpackedFramework = scratch.appending(path: framework, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: unpackedFramework.appending(path: frameworkBinary).path) else {
            throw Failure.missingFramework
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        let frameworks = frameworksFolder(in: destination)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try writeBundleInfo(in: destination)
        try fileManager.moveItem(at: unpackedFramework, to: frameworks.appending(path: frameworkName))
        try fileManager.moveItem(at: scratch.appending(path: license), to: destination.appending(path: "LICENSE.txt"))
        if let helpers {
            try ChromiumEngineHelpers.install(from: helpers, into: frameworks)
        }
        let manifest = Manifest(version: pin.version, platform: pin.platform, sha256: pin.sha256)
        try JSONEncoder().encode(manifest).write(to: destination.appending(path: manifestName), options: .atomic)
    }

    private static func runTar(_ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -o: don't restore the archive's owner. Without -P, bsdtar refuses absolute paths, `..`
        // and writes through symlinks, so nothing leaves the scratch folder.
        process.arguments = arguments
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Clears Gatekeeper's quarantine flag from the verified archive only, before unpacking, so
    /// tar has no flag to copy onto the files. URLSession downloads are normally not flagged, so
    /// this is usually a no-op; nothing else is ever touched.
    static func removeQuarantine(fromVerified archive: URL) {
        let attribute = SteamCmdPackage.quarantineAttribute
        guard SteamCmdPackage.hasQuarantine(archive.path) else { return }
        if removexattr(archive.path, attribute, XATTR_NOFOLLOW) != 0 {
            OWELog.error(.web, "Can't clear the quarantine flag of \(archive.path): errno \(errno)")
        } else {
            OWELog.info(.web, "Cleared the quarantine flag of the verified Chromium archive")
        }
    }

    /// The engine bundle's Info.plist. The bundle has no executable of its own: the XPC helper is
    /// CEF's browser process and only names this bundle as CEF's main bundle.
    private static func writeBundleInfo(in folder: URL) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.openwallpaperengine.chromium",
            "CFBundleName": "OWE Chromium",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSUIElement": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: folder.appending(path: "\(ChromiumHelperIPC.engineBundleName)/Contents/Info.plist"))
    }

    /// The manifest of the install in `folder`, nil when it isn't a complete install.
    static func manifest(in folder: URL) -> Manifest? {
        // No manifest: not installed. One that can't be read or decoded logs and counts as none.
        guard let manifest = OWELog.attempt(.web, "Chromium engine manifest", quietIfMissing: true, {
                  try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appending(path: manifestName)))
              }),
              FileManager.default.fileExists(atPath: frameworksFolder(in: folder).appending(path: "\(frameworkName)/\(frameworkBinary)").path)
        else { return nil }
        return manifest
    }
}

/// CEF's helper apps, built and signed with the app (`Contents/Helpers/OWE Chromium Helper*.app`)
/// and copied whole into the engine bundle, so their team signatures stay intact.
enum ChromiumEngineHelpers {
    /// The app's own copies, nil when the app has none (unit tests' fake installs).
    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: appName("")).path) ? url : nil
    }

    static func appName(_ variant: String) -> String { "\(ChromiumHelperIPC.helperName)\(variant).app" }

    /// Replaces every helper app in `frameworks` with the one in `source`.
    static func install(from source: URL, into frameworks: URL) throws {
        let fileManager = FileManager.default
        for variant in ChromiumHelperIPC.helperVariants {
            let target = frameworks.appending(path: appName(variant), directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: source.appending(path: appName(variant), directoryHint: .isDirectory), to: target)
        }
    }

    /// Brings the helpers of the install in `folder` up to this app's, after an app update.
    static func sync(_ folder: URL) throws {
        let frameworks = ChromiumEnginePackage.frameworksFolder(in: folder)
        guard let source = bundled, FileManager.default.fileExists(atPath: frameworks.path) else { return }
        let executable = "\(appName(""))/Contents/MacOS/\(ChromiumHelperIPC.helperName)"
        let current = try? Data(contentsOf: frameworks.appending(path: executable))
        guard current != (try Data(contentsOf: source.appending(path: executable))) else { return }
        OWELog.info(.web, "Updating the Chromium engine's helpers")
        try install(from: source, into: frameworks)
    }
}
