import Foundation

/// The UI's names for values that are stored or sent in English: a wallpaper's type and age
/// rating from `project.json`, and the filter options, which are WE's Workshop tags. The stored
/// value stays English; only the label is translated.
enum LocalizedLabels {
    /// The label of a filter option or Workshop tag (`FilterOption.key`, `WorkshopTags`,
    /// `WEResolutionTags`). An unknown value (a resolution, a tag from a newer WE) shows as is.
    static func filterOption(_ option: String) -> LocalizedStringResource {
        switch option {
        // Show Only
        case "Approved": return LocalizedStringResource("Approved", comment: "Filter: Workshop items the Wallpaper Engine team approved")
        case "My Favourites": return LocalizedStringResource("My Favourites", comment: "Filter: wallpapers the user marked as favourite")
        case "Mobile Compatible": return LocalizedStringResource("Mobile Compatible", comment: "Filter: wallpapers that also run in the Wallpaper Engine mobile app")
        case "Audio Responsive", "Audio responsive": return LocalizedStringResource("Audio Responsive", comment: "Filter and Workshop tag: wallpapers that react to sound")
        case "Customizable": return LocalizedStringResource("Customizable", comment: "Filter and Workshop tag: wallpapers with user-adjustable properties")
        // Type
        case "Scene": return LocalizedStringResource("Scene", comment: "Wallpaper type: a Wallpaper Engine scene")
        case "Video": return LocalizedStringResource("Video", comment: "Wallpaper type: a video file")
        case "Web": return LocalizedStringResource("Web", comment: "Wallpaper type: a web page")
        case "Application": return LocalizedStringResource("Application", comment: "Wallpaper type: a program (not supported on macOS)")
        // Category
        case "Wallpaper": return LocalizedStringResource("Wallpaper", comment: "Filter category: an ordinary wallpaper, as opposed to a Workshop preset")
        case "Preset": return LocalizedStringResource("Preset", comment: "Filter category: a Workshop preset, another wallpaper's settings published as its own item")
        // Age rating
        case "Everyone": return LocalizedStringResource("Everyone", comment: "Age rating: suitable for everyone")
        case "Questionable", "Partial Nudity": return LocalizedStringResource("Questionable", comment: "Age rating between Everyone and Mature (partial nudity, mild violence)")
        case "Mature": return LocalizedStringResource("Mature", comment: "Age rating: adults only")
        // Source
        case "Official": return LocalizedStringResource("Official", comment: "Filter: wallpapers made by the Wallpaper Engine team")
        case "Workshop": return LocalizedStringResource("Workshop", comment: "Filter: wallpapers from the Steam Workshop")
        case "MyWallpapers": return LocalizedStringResource("My Wallpapers", comment: "Filter: wallpapers the user made or imported")
        // Genre
        case "Abstract": return LocalizedStringResource("Abstract", comment: "Workshop genre tag")
        case "Animal": return LocalizedStringResource("Animal", comment: "Workshop genre tag")
        case "Anime": return LocalizedStringResource("Anime", comment: "Workshop genre tag")
        case "Cartoon": return LocalizedStringResource("Cartoon", comment: "Workshop genre tag")
        case "CGI": return LocalizedStringResource("CGI", comment: "Workshop genre tag: computer-generated imagery")
        case "Cyberpunk": return LocalizedStringResource("Cyberpunk", comment: "Workshop genre tag")
        case "Fantasy": return LocalizedStringResource("Fantasy", comment: "Workshop genre tag")
        case "Game": return LocalizedStringResource("Game", comment: "Workshop genre tag: video games")
        case "Girls": return LocalizedStringResource("Girls", comment: "Workshop genre tag")
        case "Guys": return LocalizedStringResource("Guys", comment: "Workshop genre tag")
        case "Landscape": return LocalizedStringResource("Landscape", comment: "Workshop genre tag: scenery")
        case "Medieval": return LocalizedStringResource("Medieval", comment: "Workshop genre tag")
        case "Memes": return LocalizedStringResource("Memes", comment: "Workshop genre tag")
        case "MMD": return LocalizedStringResource("MMD (Miku-Miku Dance)", comment: "Workshop genre tag; MikuMikuDance is a 3D animation program")
        case "Music": return LocalizedStringResource("Music", comment: "Workshop genre tag")
        case "Nature": return LocalizedStringResource("Nature", comment: "Workshop genre tag")
        case "PixelArt", "Pixel art": return LocalizedStringResource("Pixel Art", comment: "Workshop genre tag")
        case "Relaxing": return LocalizedStringResource("Relaxing", comment: "Workshop genre tag")
        case "Retro": return LocalizedStringResource("Retro", comment: "Workshop genre tag")
        case "Sci-Fi": return LocalizedStringResource("Sci-Fi", comment: "Workshop genre tag: science fiction")
        case "Sports": return LocalizedStringResource("Sports", comment: "Workshop genre tag")
        case "Technology": return LocalizedStringResource("Technology", comment: "Workshop genre tag")
        case "Television": return LocalizedStringResource("Television", comment: "Workshop genre tag: TV series")
        case "Vehicle": return LocalizedStringResource("Vehicle", comment: "Workshop genre tag")
        case "UnspecifiedGenre", "Unspecified": return LocalizedStringResource("Unspecified Genre", comment: "Workshop genre tag for items without a genre")
        // Resolution
        case "Widescreen": return LocalizedStringResource("Widescreen", comment: "Resolution filter group: 16:9 displays")
        case "Ultra Widescreen": return LocalizedStringResource("Ultra Widescreen", comment: "Resolution filter group: 21:9 displays")
        case "Dual Monitor": return LocalizedStringResource("Dual Monitor", comment: "Resolution filter group: wallpapers spanning two displays")
        case "Triple Monitor": return LocalizedStringResource("Triple Monitor", comment: "Resolution filter group: wallpapers spanning three displays")
        case "Portrait Monitor / Phone": return LocalizedStringResource("Portrait Monitor / Phone", comment: "Resolution filter group: portrait displays and phones")
        case "Other": return LocalizedStringResource("Other", comment: "Resolution filter group for the remaining resolutions")
        case "Standard Definition", "Ultrawide Standard Definition", "Dual Standard Definition",
             "Triple Standard Definition", "Portrait Standard Definition":
            return LocalizedStringResource("Standard Definition", comment: "Resolution filter: resolutions below HD")
        case "1920 x 1080": return LocalizedStringResource("1920 x 1080 – Full HD", comment: "Resolution filter")
        case "3840 x 2160": return LocalizedStringResource("3840 x 2160 – 4K", comment: "Resolution filter")
        case "Other resolution": return LocalizedStringResource("Other Resolution", comment: "Resolution filter")
        case "Dynamic resolution": return LocalizedStringResource("Dynamic Resolution", comment: "Resolution filter: wallpapers that adapt to any resolution")
        default:
            for prefix in ["Ultrawide ", "Dual ", "Triple ", "Portrait "] where option.hasPrefix(prefix) {
                return "\(String(option.dropFirst(prefix.count)))"
            }
            return "\(option)"
        }
    }

    /// A wallpaper type from `project.json` (`scene`, `video`, `web`, …); an unknown one shows as is.
    static func wallpaperType(_ type: String) -> String {
        switch type.lowercased() {
        case "scene": return String(localized: filterOption("Scene"))
        case "video", "remote-video": return String(localized: filterOption("Video"))
        case "web": return String(localized: filterOption("Web"))
        case "application": return String(localized: filterOption("Application"))
        case "remote-image": return String(localized: "Image", comment: "Wallpaper type: an image added by URL")
        default: return type.capitalized
        }
    }
}

extension WEProject {
    /// The title shown in the UI, which names a wallpaper without one.
    var displayTitle: String {
        title.isEmpty ? String(localized: "Untitled", comment: "Shown for a wallpaper that has no title") : title
    }
}
