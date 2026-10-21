import Foundation
import CryptoKit

/// Names a wallpaper's stored settings (its user property values) by what the wallpaper is, not
/// where it is, so moving or renaming the library keeps them.
///
/// The identity is the Workshop id when there is one (`project.json`'s `workshopid`, or a
/// numeric folder name, which is how Steam names Workshop downloads), else an id the app keeps
/// for the local wallpaper's folder (`LocalWallpaperIdentities`), so editing its project.json
/// doesn't orphan its settings.
struct WallpaperSettingsIdentity: Hashable {
    let rawValue: String

    /// The stored settings families, each `<prefix><identity>`.
    enum Family: String, CaseIterable {
        case userProperties = "SceneUserProperties."
        /// Whether the user ever set a value (else project defaults are re-derived on load).
        case explicitUserProperties = "SceneUserPropertiesExplicit."
    }

    init(rawValue: String) { self.rawValue = rawValue }

    /// The identity derived from the wallpaper's `project.json` alone (nil when unreadable: the
    /// folder name alone then): its Workshop id, else a hash of the file's bytes plus the folder
    /// name. For a local wallpaper this changes when the file is edited; `resolve` gives the stable
    /// identity, and uses this one only to keep settings stored before local ids were kept.
    init(directory: URL, projectData: Data?) {
        let folder = directory.standardizedFileURL.lastPathComponent
        if let id = Self.workshopID(projectData: projectData, folder: folder) {
            rawValue = "workshop-\(id)"
        } else if let projectData {
            let digest = Digest.hex(SHA256.hash(data: projectData).prefix(8))
            rawValue = "local-\(digest)-\(folder)"
        } else {
            rawValue = "local-\(folder)"
        }
    }

    func key(_ family: Family) -> String { family.rawValue + rawValue }

    var isWorkshop: Bool { rawValue.hasPrefix("workshop-") }

    /// The identity of the wallpaper in `directory`.
    static func resolve(directory: URL, defaults: UserDefaults = .app) -> WallpaperSettingsIdentity {
        resolve(directory: directory, defaults: defaults, index: nil)
    }

    /// `resolve`, with the stored-settings names already read when many wallpapers are resolved.
    static func resolve(directory: URL, defaults: UserDefaults, index: LegacySettingsIndex?) -> WallpaperSettingsIdentity {
        let projectURL = WEProject.url(in: directory)
        let projectData: Data?
        do {
            projectData = try Data(contentsOf: projectURL)
        } catch {
            OWELog.error(.library, "Could not read \(projectURL.path) to identify its settings: \(error)")
            projectData = nil
        }
        let derived = WallpaperSettingsIdentity(directory: directory, projectData: projectData)
        if SceneBackendRuntimeContext.isActive { return derived }
        // Only a wallpaper folder is registered (not, say, the bundled placeholder video).
        var isFolder: ObjCBool = false
        guard !derived.isWorkshop, FileManager.default.fileExists(atPath: directory.path, isDirectory: &isFolder),
              isFolder.boolValue else { return derived }
        let local = LocalWallpaperIdentities.identity(
            directory: directory, derived: derived.rawValue, contentKnown: projectData != nil, defaults: defaults,
            index: { index ?? LegacySettingsIndex(defaults: defaults, supportDirectory: AppStorageLocation.current.supportDirectory) })
        return WallpaperSettingsIdentity(rawValue: local)
    }

    static func resolve(_ wallpaper: WEWallpaper, defaults: UserDefaults = .app) -> WallpaperSettingsIdentity {
        resolve(directory: wallpaper.settingsDirectory, defaults: defaults)
    }

    private static func workshopID(projectData: Data?, folder: String) -> String? {
        if let projectData,
           let root = (try? JSONSerialization.jsonObject(with: projectData)) as? [String: Any] { // unreadable: no id
            let raw = root["workshopid"].map { "\($0)" } ?? ""
            if !raw.isEmpty, raw.allSatisfy(\.isNumber) { return raw }
        }
        if !folder.isEmpty, folder.allSatisfy(\.isNumber) { return folder }
        return nil
    }
}
