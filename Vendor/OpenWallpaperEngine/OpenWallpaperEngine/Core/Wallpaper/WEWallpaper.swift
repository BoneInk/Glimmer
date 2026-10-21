import SwiftUI
import ImageIO

struct WEWallpaper: Codable, RawRepresentable, Identifiable {
    
    var id: Int { self.project.hashValue }
    var rawValue: String {
        do {
            let rawValueData = try JSONEncoder().encode(self)
            return String(data: rawValueData, encoding: .utf8)!
        } catch {
            OWELog.error(.library, "Encoding wallpaper failed: \(error)")
            return ""
        }
    }
    
    var wallpaperDirectory: URL
    var project: WEProject
    /// For a Workshop preset item (`WorkshopPresetItem`), the item's own folder; `wallpaperDirectory`
    /// is then its base wallpaper's. Nil for every other wallpaper.
    var presetDirectory: URL?

    var isWorkshopPreset: Bool { presetDirectory != nil }

    /// Which wallpaper this is, for Next, Previous and the history: its own folder by path, so
    /// `…/name` and `…/name/` match and a Workshop preset differs from its base wallpaper.
    var identityPath: String { settingsDirectory.standardizedFileURL.path }

    func isSameWallpaper(as other: WEWallpaper) -> Bool { identityPath == other.identityPath }

    /// Where the wallpaper's own project.json lives: its stored settings, its running property
    /// store (`WallpaperPropertyScope.runtimeKey`) and its preview are keyed by it.
    var settingsDirectory: URL { presetDirectory ?? wallpaperDirectory }

    /// The preview image; a preset item shows its own.
    var previewURL: URL? { project.previewURL(in: settingsDirectory) }

    /// A remote wallpaper stores an absolute URL in `project.file`; everything else stores a path
    /// relative to its folder.
    var mediaURL: URL {
        if let remote = URL(string: project.file), let scheme = remote.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return remote
        }
        return wallpaperDirectory.appending(path: project.file)
    }

    var isRemoteMedia: Bool {
        guard let scheme = URL(string: project.file)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    
    var wallpaperSize: Int {
        guard let sizeBytes = try? self.wallpaperDirectory.directoryTotalAllocatedSize(includingSubfolders: true)
        else { return 0 }
        return sizeBytes
    }
    
    /// A library entry that is a symbolic link to a wallpaper folder runs from the folder it points
    /// to (`ContainedPath.followingFolderLink`), so every listing of the wallpaper's files works.
    init(using project: WEProject, where url: URL) {
        self.wallpaperDirectory = ContainedPath.followingFolderLink(url)
        self.project = project
    }
    
    enum CodingKeys: CodingKey {
        case wallpaperDirectory
        case project
        case presetDirectory
        // <all the other elements too>
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A link saved before links were followed is followed now, as a listed wallpaper's is.
        self.wallpaperDirectory = ContainedPath.followingFolderLink(try container.decode(URL.self, forKey: .wallpaperDirectory))
        self.project = try container.decode(WEProject.self, forKey: .project)
        self.presetDirectory = try container.decodeIfPresent(URL.self, forKey: .presetDirectory).map(ContainedPath.followingFolderLink)
        // <and so on>
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperDirectory, forKey: .wallpaperDirectory)
        try container.encode(project, forKey: .project)
        try container.encodeIfPresent(presetDirectory, forKey: .presetDirectory)
        // <and so on>
    }
    
    init?(rawValue: String) {
        // Optional: a raw value that isn't a stored wallpaper is none (RawRepresentable's contract).
        if let rawValueData = rawValue.data(using: .utf8),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: rawValueData) {
            self = wallpaper
        } else {
            return nil
        }
    }

    var isMobileCompatible: Bool {
        (project.tags ?? []).contains { $0.localizedCaseInsensitiveContains("mobile") }
    }

    var isAudioResponsive: Bool {
        (project.tags ?? []).contains { $0.localizedCaseInsensitiveContains("audio") }
    }

    var hasCustomizableProperties: Bool {
        projectHasCustomizableProperties(at: wallpaperDirectory)
    }
}

/// The Installed tab's sorts, in WE's order (its `sortOptions` for the installed list in
/// `ui/dist/scripts/scripts.js`: name, rating, favorite, filesize, subscriptiondate, updatedate).
/// The raw values are what the setting stores.
enum WEWallpaperSortingMethod: String, CaseIterable, Identifiable {
    
    var id: Self { self }
    
    case name = "Name"
    case rating = "Rating"
    /// WE's Favorite: favourites first, each part by name.
    case favorite = "Favorite"
    case fileSize = "File Size"
    case dateAdded = "Date Added"
    /// WE's Last Updated: when the Workshop item last changed, newest first.
    case lastUpdated = "Last Updated"

    var displayName: LocalizedStringResource {
        switch self {
        case .name: return LocalizedStringResource("Name", comment: "Sort wallpapers by name")
        case .rating: return LocalizedStringResource("Rating", comment: "Sort wallpapers by age rating")
        case .favorite: return LocalizedStringResource("Favorite", comment: "Sort wallpapers with the favourites first")
        case .fileSize: return LocalizedStringResource("File Size", comment: "Sort wallpapers by size on disk")
        case .dateAdded: return LocalizedStringResource("Date Downloaded", comment: "Sort wallpapers by when they were added")
        case .lastUpdated: return LocalizedStringResource("Last Updated", comment: "Sort wallpapers by when their Workshop item last changed")
        }
    }
}

enum WEWallpaperSortingSequence: Int {
    case decrease = 0, increase = 1
}
