import Foundation

/// An effect the editor can add: one of WE's built-in effects (`effects/<name>/effect.json` in
/// its assets), or a Workshop effect the wallpaper already uses.
public struct EffectCatalogEntry: Hashable, Sendable, Identifiable {
    /// `effects/<name>/effect.json`, as an added effect's `file`.
    public var file: String
    public var title: String
    public var summary: String
    /// WE's group (`animate`, `blur`, `distort`, …) and its title.
    public var group: String
    public var groupTitle: String
    /// A picture of the effect (its preview, else nothing: the browser draws its group's symbol).
    public var preview: URL?
    /// A Workshop effect the wallpaper ships rather than one of WE's.
    public var isWorkshop: Bool
    /// The effect's passes, which an added effect's scene object lists.
    public var passCount: Int
    /// One of the wallpaper's own effects that can be edited (WE's "My Effects", `group`
    /// `localeffects`): made in the editor, or shipped by the wallpaper with `editable` set.
    public var isEditable = false
    /// Made in this editor (its files are in the edits): it can be deleted.
    public var isMadeHere = false

    public var id: String { file }

    public init(file: String, title: String, summary: String = "", group: String = "", groupTitle: String = "",
                preview: URL? = nil, isWorkshop: Bool = false, passCount: Int = 1) {
        self.file = file
        self.title = title
        self.summary = summary
        self.group = group
        self.groupTitle = groupTitle
        self.preview = preview
        self.isWorkshop = isWorkshop
        self.passCount = passCount
    }

    /// For a Workshop effect, the folder of the wallpaper that ships it (its preview reads it there).
    public var wallpaperDirectory: String?

    /// What its rendered preview shows: the effect, at its defaults, on the test card.
    public var previewSubject: EditorPreviewSubject {
        .effect(file: file, wallpaper: isWorkshop ? wallpaperDirectory : nil)
    }

    /// The effect's folder name (`waterripple`).
    public var folderName: String {
        ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
    }
}

public enum EffectCatalog {
    /// The entries matching `query` in their title, summary, group or folder name, ignoring case
    /// and accents, every word of it somewhere; all of them for an empty query. In title order.
    public static func filter(_ entries: [EffectCatalogEntry], query: String) -> [EffectCatalogEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let sorted = entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !words.isEmpty else { return sorted }
        return sorted.filter { entry in
            let haystack = fold([entry.title, entry.summary, entry.groupTitle, entry.group, entry.folderName].joined(separator: " "))
            return words.allSatisfy(haystack.contains)
        }
    }

    /// Entries by group title, groups in title order, WE's before the Workshop's; the wallpaper's
    /// editable effects ("My Effects") first, as WE's dialog lists them.
    public static func grouped(_ entries: [EffectCatalogEntry]) -> [(title: String, entries: [EffectCatalogEntry])] {
        var groups: [String: [EffectCatalogEntry]] = [:]
        for entry in entries { groups[entry.groupTitle, default: []].append(entry) }
        return groups.keys.sorted { lhs, rhs in
            let leftOwn = groups[lhs]!.allSatisfy(\.isEditable), rightOwn = groups[rhs]!.allSatisfy(\.isEditable)
            if leftOwn != rightOwn { return leftOwn }
            let left = groups[lhs]!.allSatisfy(\.isWorkshop), right = groups[rhs]!.allSatisfy(\.isWorkshop)
            if left != right { return !left }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    /// WE's built-in effects in the asset tree `assets`: every `effects/<name>/effect.json`, by
    /// folder name, but the internal ones (`_empty`), which its editor doesn't offer.
    public static func builtInEffectFiles(in assets: URL, fileManager: FileManager = .default) -> [String] {
        let effects = assets.appending(path: "effects", directoryHint: .isDirectory)
        // Optional: an asset tree without an effects folder has no effects.
        let folders = (try? fileManager.contentsOfDirectory(atPath: effects.path(percentEncoded: false))) ?? []
        return folders.sorted().filter { name in
            !name.hasPrefix("_") && !name.hasPrefix(".")
                && fileManager.fileExists(atPath: effects.appending(path: "\(name)/effect.json").path(percentEncoded: false))
        }.map { "effects/\($0)/effect.json" }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Effects the scene's layers use from outside WE's own set (`builtIn` folder names): the
    /// Workshop effects a wallpaper ships, which it can add again.
    /// `excluded` (lower-cased files) are listed elsewhere (the wallpaper's editable effects).
    public static func workshopEffects(in outline: SceneOutline, builtIn: Set<String>, excluded: Set<String> = []) -> [String] {
        var seen = Set<String>(), files: [String] = []
        for layer in outline.layers {
            for effect in layer.effects where !effect.file.isEmpty && !excluded.contains(effect.file.lowercased()) {
                let isBuiltIn = effect.file.lowercased().hasPrefix("effects/") && builtIn.contains(effect.folderName)
                    && effect.file.split(separator: "/").count == 3
                guard !isBuiltIn, seen.insert(effect.file.lowercased()).inserted else { continue }
                files.append(effect.file)
            }
        }
        return files
    }
}
