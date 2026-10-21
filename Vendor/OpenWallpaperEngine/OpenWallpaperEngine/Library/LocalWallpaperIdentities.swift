import Foundation

/// The settings identities of local (non-Workshop) wallpapers, kept by the app: a generated id per
/// wallpaper folder, so editing the wallpaper's project.json (title, tags, content rating) keeps
/// its user properties, presets, editor overlay, display and screen saver options.
///
/// Stored in the app's defaults (`defaultsKey`) as `[folder path: entry]`, not in the wallpaper's
/// folder: library folders are read only (`LibraryFolders`). An entry remembers the folder's file
/// node (volume and inode), so a folder moved or renamed on its volume keeps its id, and the
/// identity its project derives (`WallpaperSettingsIdentity(directory:projectData:)`), so an
/// unedited wallpaper moved to another volume keeps it too. A copy of a folder (Save as Local
/// Wallpaper, a Finder copy) is a new node at a new path while the original is still there: it
/// gets an id of its own.
///
/// Migration: a wallpaper seen for the first time whose derived identity (the hash of its
/// project.json bytes, the identity before this store) still names stored settings keeps that
/// string as its id, so nothing has to be re-keyed and running it again changes nothing.
enum LocalWallpaperIdentities {
    static let defaultsKey = "LocalWallpaperIdentities"
    /// Set once the launch sweep (`registerLibrary`) has run.
    static let sweepDoneKey = "LocalWallpaperIdentitiesSwept"

    private static let lock = NSLock()

    /// The id of the local wallpaper in `directory`, registered on first sight. `derived` is its
    /// project's derived identity; `index` says whether settings are stored under a string.
    static func identity(directory: URL, derived: String, contentKnown: Bool, defaults: UserDefaults,
                         index: () -> LegacySettingsIndex) -> String {
        lock.lock()
        defer { lock.unlock() }
        var entries = defaults.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
        let path = directory.standardizedFileURL.path
        let content = contentKnown ? derived : nil
        if var entry = entries[path], let id = entry["id"] {
            if let content, entry["content"] != content {
                entry["content"] = content
                entries[path] = entry
                defaults.set(entries, forKey: defaultsKey)
            }
            return id
        }
        let node = fileNode(directory)
        let missing = entries.filter { $0.key != path && !FileManager.default.fileExists(atPath: $0.key) }
        // The same folder at a new path (moved or renamed on its volume), else an unedited
        // wallpaper whose old folder is gone (moved to another volume); only a single candidate.
        var moved = node.map { node in missing.filter { $0.value["node"] == node } } ?? [:]
        if moved.isEmpty, let content { moved = missing.filter { $0.value["content"] == content } }
        if moved.count == 1, case let (oldPath, old)? = moved.first, let id = old["id"] {
            entries[oldPath] = nil
            entries[path] = entry(id: id, node: node, content: content)
            defaults.set(entries, forKey: defaultsKey)
            OWELog.info(.library, "Settings identity \(id) follows its wallpaper from \(oldPath) to \(path)")
            return id
        }
        let live = Set(entries.compactMap { $0.key != path && !missing.keys.contains($0.key) ? $0.value["id"] : nil })
        let id: String
        if !live.contains(derived), index().hasSettings(for: derived) {
            id = derived
            OWELog.info(.library, "Kept the stored settings of \(path) under \(id)")
        } else {
            id = "local-" + UUID().uuidString.lowercased()
        }
        entries[path] = entry(id: id, node: node, content: content)
        defaults.set(entries, forKey: defaultsKey)
        return id
    }

    /// Registers every local wallpaper in `libraries` (folders of wallpaper folders) once, before
    /// any of them is edited, and logs how many old identities that hold settings no wallpaper
    /// claims (settings orphaned by an edit before this store existed; they are left as they are).
    /// Returns those identities' `local-<hash>-` prefixes. Runs once per defaults unless `force`.
    @discardableResult
    static func registerLibrary(_ libraries: [URL], defaults: UserDefaults = .app,
                                supportDirectory: URL = AppStorageLocation.current.supportDirectory,
                                force: Bool = false) -> Set<String> {
        guard force || !defaults.bool(forKey: sweepDoneKey) else { return [] }
        let index = LegacySettingsIndex(defaults: defaults, supportDirectory: supportDirectory)
        for library in libraries {
            let folders = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? [] // missing library: none
            for folder in folders where WEProject.exists(in: folder) {
                _ = WallpaperSettingsIdentity.resolve(directory: folder, defaults: defaults, index: index)
            }
        }
        let ids = Set((defaults.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]).values.compactMap { $0["id"] })
        let unmatched = index.legacyIdentities(excluding: ids)
        if !unmatched.isEmpty {
            OWELog.info(.library, "\(unmatched.count) stored settings identities from before stable local ids match no wallpaper; left as they are")
        }
        defaults.set(true, forKey: sweepDoneKey)
        return unmatched
    }

    private static func entry(id: String, node: String?, content: String?) -> [String: String] {
        var entry = ["id": id]
        entry["node"] = node
        entry["content"] = content
        return entry
    }

    /// The folder's volume and inode: unchanged when it is moved or renamed on its volume.
    static func fileNode(_ directory: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path), // gone: no node
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let volume = (try? directory.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString // no UUID: device number
            ?? (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "?"
        return "\(volume):\(inode)"
    }
}

/// The names settings are stored under (defaults keys, display option entries, preset and editor
/// files), read once, to tell whether an old derived identity still holds settings.
struct LegacySettingsIndex {
    private let names: [String]

    init(defaults: UserDefaults, supportDirectory: URL) {
        var names = Array(defaults.dictionaryRepresentation().keys)
        if let data = defaults.data(forKey: WallpaperDisplayOptionsStore.defaultsKey),
           let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { // unreadable: none
            names += options.keys
        }
        for folder in ["presets", "editor"] {
            names += (try? FileManager.default.contentsOfDirectory(atPath: supportDirectory.appending(path: folder).path)) ?? [] // none yet
        }
        self.names = names
    }

    func hasSettings(for identity: String) -> Bool {
        let file = Self.fileName(identity)
        return names.contains { $0.contains(identity) || $0.contains(file) }
    }

    /// The distinct old derived identities (`local-<16 hex>-` prefixes) named by stored settings
    /// but none of `ids`.
    func legacyIdentities(excluding ids: Set<String>) -> Set<String> {
        let files = Set(ids.map(Self.fileName))
        var orphans = Set<String>()
        for name in names {
            guard let range = name.range(of: #"local-[0-9a-f]{16}-"#, options: .regularExpression),
                  !ids.contains(where: name.contains), !files.contains(where: name.contains) else { continue }
            orphans.insert(String(name[range]))
        }
        return orphans
    }

    /// The editor store's file name for an identity (`SceneEditOverlayStore.fileName`).
    private static func fileName(_ identity: String) -> String {
        String(identity.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "_" : $0 }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
