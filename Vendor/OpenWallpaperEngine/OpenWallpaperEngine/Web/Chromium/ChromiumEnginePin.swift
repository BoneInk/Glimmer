import Foundation

/// One CEF build the app accepts: the official "minimal" binary distribution from
/// cef-builds.spotifycdn.com for one CPU architecture, pinned by SHA-256. A new app release pins a
/// new build here; the app never installs an unpinned or "latest" build.
///
/// To pin a new build: download both minimal archives, check them against the SHA-1 in the
/// CDN's index.json, compute `shasum -a 256`, update the table, and re-vendor `Vendor/cef/include`
/// from the same archive (the helper is compiled against those headers).
struct ChromiumEnginePin: Equatable, Sendable {
    /// CEF's version string, e.g. "154.0.33+ga03e714+chromium-154.0.8037.94"; also the install folder name.
    let version: String
    /// CEF's platform name: `macosarm64` or `macosx64`.
    let platform: String
    /// Lowercase hex SHA-256 of the archive.
    let sha256: String
    /// Bytes of the archive.
    let downloadSize: Int64
    /// Bytes the unpacked framework takes, for Settings before installing.
    let installedSize: Int64

    var archiveName: String { "cef_binary_\(version)_\(platform)_minimal.tar.bz2" }

    /// The archive's folder at the top of the tarball.
    var archiveRoot: String { "cef_binary_\(version)_\(platform)_minimal" }

    var downloadURL: URL {
        // `+` must be escaped in the path, as the CDN's own links do.
        let name = archiveName.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        return URL(string: "https://cef-builds.spotifycdn.com/\(name)")!
    }

    /// The builds this app release accepts, one per architecture.
    static let pinned: [ChromiumEnginePin] = [
        ChromiumEnginePin(version: "154.0.33+ga03e714+chromium-154.0.8037.94", platform: "macosarm64",
                          sha256: "6de789c942ae948596b1b0c60d72503c0e126f368abdd4fee530e8eaa3776814",
                          downloadSize: 132_191_239, installedSize: 337_801_216),
        ChromiumEnginePin(version: "154.0.33+ga03e714+chromium-154.0.8037.94", platform: "macosx64",
                          sha256: "b1cf9e159b798323ffd17b457dfc410ea3ee192868eb73061f25447865d4fe1a",
                          downloadSize: 138_695_846, installedSize: 358_756_352),
    ]

    /// The platform name of the architecture this process runs as.
    static var hostPlatform: String {
        #if arch(arm64)
        return "macosarm64"
        #else
        return "macosx64"
        #endif
    }

    /// The pin for this process's architecture.
    static func current(from pins: [ChromiumEnginePin] = pinned, platform: String = hostPlatform) -> ChromiumEnginePin? {
        pins.first { $0.platform == platform }
    }
}
