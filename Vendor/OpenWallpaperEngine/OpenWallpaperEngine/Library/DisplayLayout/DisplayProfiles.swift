import Foundation

/// The user's display profiles (WE's "Save Profile" / "Load Profile"), saved as JSON in the app's
/// support folder, and applied to the displays of the view model they belong to.
@MainActor
final class DisplayProfiles: ObservableObject {
    /// `<support folder>/DisplayProfiles.json`.
    static var defaultURL: URL {
        AppStorageLocation.current.supportDirectory.appending(path: "DisplayProfiles.json")
    }

    /// The name of the profile a Wallpaper Engine config is imported as.
    static let wallpaperEngineProfileName = "Wallpaper Engine"

    /// Sorted by name, ignoring case.
    @Published private(set) var profiles: [DisplayProfile] = []

    private weak var model: WallpaperViewModel?
    private let fileURL: URL

    init(model: WallpaperViewModel, fileURL: URL) {
        self.model = model
        self.fileURL = fileURL
        profiles = Self.read(fileURL)
    }

    var names: [String] { profiles.map(\.name) }

    func profile(named name: String) -> DisplayProfile? {
        profiles.first { $0.name == name }
    }

    /// Saves the current layout and the connected displays' wallpapers as `name` (trimmed),
    /// overwriting a profile of that name, as WE does. False for an empty name.
    @discardableResult
    func save(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let model else { return false }
        let selections = DisplayProfile.selections(of: model.wallpapers, connected: model.connectedDisplays())
        store(DisplayProfile(name: name, layout: model.displayLayout, selections: selections))
        return true
    }

    /// Loads the profile `name`: its layout replaces the current one, and each connected display
    /// it has a wallpaper for (or regions of) shows that; the other displays keep theirs, and the
    /// profile's displays that aren't connected are skipped. This is what a "Load profile" app
    /// rule or hotkey calls. False, and nothing changes, when there is no such profile.
    @discardableResult
    func load(name: String) -> Bool {
        guard let model, let profile = profile(named: name) else {
            OWELog.info(.app, "Display profile \"\(name)\" not found")
            return false
        }
        let loaded = profile.wallpapers(on: model.connectedDisplays())
        model.displayLayout = profile.layout
        // A display the profile names gets all its selections from it, regions included.
        let displays = Set(loaded.keys.map(DisplayLayoutResolution.screen(of:)))
        var wallpapers = model.wallpapers.filter { !displays.contains(DisplayLayoutResolution.screen(of: $0.key)) }
        wallpapers.merge(loaded) { _, new in new }
        model.wallpapers = wallpapers
        reselect(in: model)
        OWELog.info(.app, "Display profile \"\(name)\" loaded")
        return true
    }

    func delete(name: String) {
        guard profiles.contains(where: { $0.name == name }) else { return }
        profiles.removeAll { $0.name == name }
        write()
    }

    /// Imports the display layout of a Wallpaper Engine `config.json` as the profile
    /// "Wallpaper Engine" (overwriting an earlier import) for the user to load, and takes its
    /// screen saver layout (a setting of its own, not part of a profile).
    @discardableResult
    func importWallpaperEngineConfig(at url: URL) throws -> DisplayProfile {
        let config = try WallpaperEngineDisplayConfig(contentsOf: url)
        let connected = model?.connectedDisplays() ?? DisplayIdentity.connected()
        let profile = DisplayProfile(name: Self.wallpaperEngineProfileName, layout: config.layout(on: connected))
        store(profile)
        if let screenSaver = config.screenSaverLayout { model?.screenSaverLayout = screenSaver }
        return profile
    }

    // MARK: Storage

    private func store(_ profile: DisplayProfile) {
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        write()
    }

    /// Selected displays that the loaded layout no longer shows become the nearest shown one: a
    /// gone region its display or remaining region, a display split now its first region.
    private func reselect(in model: WallpaperViewModel) {
        let connected = model.connectedDisplays().map(\.screenId)
        guard !connected.isEmpty else { return }
        let shown = model.layoutResolution.shownDisplays(connected)
        func nearest(_ id: String) -> String {
            var candidate = id
            while !shown.contains(candidate), candidate.contains("/") { candidate = String(candidate.dropLast(2)) }
            if shown.contains(candidate) { return candidate }
            return shown.first { $0.hasPrefix(candidate + "/") } ?? id
        }
        model.selectedScreenIds = Set(model.selectedScreenIds.map(nearest))
        model.selectedScreenId = nearest(model.selectedScreenId)
    }

    private struct File: Codable {
        var profiles: [DisplayProfile]

        init(profiles: [DisplayProfile]) { self.profiles = profiles }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Profile by profile, so one that can't be read doesn't drop the others.
            profiles = container.decodeElements(DisplayProfile.self, forKey: .profiles, userInfo: decoder.userInfo) ?? []
        }
    }

    private static func read(_ url: URL) -> [DisplayProfile] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            return file.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            OWELog.error(.app, "Display profiles unreadable at \(url.path(percentEncoded: false)): \(error)")
            return []
        }
    }

    private func write() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(profiles: profiles))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            OWELog.error(.app, "Display profiles not saved to \(fileURL.path(percentEncoded: false)): \(error)")
        }
    }
}
