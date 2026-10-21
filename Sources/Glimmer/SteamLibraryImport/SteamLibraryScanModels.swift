import Foundation

struct SteamLibraryScanLimits: Sendable {
    var maximumItems = 2_000
    var maximumDirectoryEntries = 10_000
    var maximumProjectBytes = 2 * 1024 * 1024
    var maximumTitleCharacters = 1_024
    static let `default` = SteamLibraryScanLimits()
}

enum SteamLibraryWallpaperKind: String, Codable, Sendable {
    case video, web, scene, application, unknown
}

enum SteamLibraryItemAvailability: String, Codable, Sendable {
    /// Safe local entry exists; media/HTML compatibility is still unverified.
    case readyForValidation
    case missingEntry, invalidProject, unsupportedType, rejectedSymlink, limitExceeded
}

struct SteamLibraryScanDiagnostic: Codable, Hashable, Sendable {
    enum Severity: String, Codable, Sendable { case information, warning, error }
    enum Code: String, Codable, Sendable {
        case invalidSelectedRoot, contentNotFound, unreadable, rejectedSymlink, missingProject
        case invalidProject, missingEntry, invalidEntry, unsupportedType, limitExceeded, ignoredEntries, sourceChanged, validationRequired
    }
    let code: Code
    let severity: Severity
    let path: String
    let message: String
}

struct SteamLibraryScannedItem: Identifiable, Codable, Hashable, Sendable {
    /// Includes source location: equal Workshop IDs in different libraries remain distinct candidates.
    var id: String { projectURL.path }
    let workshopID: String
    let itemRoot: URL
    let projectURL: URL
    let title: String
    let kind: SteamLibraryWallpaperKind
    let entryURL: URL?
    let availability: SteamLibraryItemAvailability
    let diagnostics: [SteamLibraryScanDiagnostic]
    var isImportCandidate: Bool {
        availability == .readyForValidation && (kind == .video || kind == .web || kind == .scene)
    }
}

struct SteamLibraryScanReport: Sendable {
    let selectedRoot: URL
    let contentRoots: [URL]
    let items: [SteamLibraryScannedItem]
    let diagnostics: [SteamLibraryScanDiagnostic]
    let wasTruncated: Bool
}
