import Foundation

/// Every particle system WE's editor offers, as it groups them: its default systems (the new
/// system's sources, `assets/particles/*.json`, which its Add dialog lists for a 2D scene and a 3D
/// one) and each preset of `assets/presets` with its particle variants.
public struct ParticleCatalog: Sendable {
    public struct Group: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// WE's default systems for 2D scenes, or for 3D ones.
            case systems(is3D: Bool)
            /// One preset's variants (`rain`).
            case preset(String)
        }

        public let kind: Kind
        /// The preset's title in WE's words; empty for the default systems (the browser names them).
        public let title: String
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public enum Source: Hashable, Sendable {
            /// A new system from this file (`particles/example.json`).
            case system(path: String)
            /// A preset's variant.
            case preset(ParticlePreset, variant: ParticlePreset.Variant)
        }

        public let source: Source
        public let title: String
        public let summary: String
        public let group: Group
        public let is3D: Bool

        public var id: String {
            switch source {
            case .system(let path): return "system:\(path)"
            case .preset(let preset, let variant): return "preset:\(preset.id)/\(variant.id)"
            }
        }

        /// What its preview renders.
        public var previewSubject: EditorPreviewSubject {
            switch source {
            case .system(let path):
                return .particleSystem(path: path, is3D: is3D)
            case .preset(let preset, let variant):
                return .particlePreset(directory: preset.directory.path(percentEncoded: false), variant: variant.id, is3D: is3D)
            }
        }
    }

    /// WE's default systems, in its order, by file and label key (its editor's
    /// `particleDefaultPresets` and `particleDefaultPresets3d`).
    public static let defaultSystems: [(path: String, label: String, is3D: Bool)] = [
        ("particles/example.json", "ui_editor_particle_example_basic", false),
        ("particles/examplecursorfollow.json", "ui_editor_particle_example_cursor_follow", false),
        ("particles/examplecursoravoid.json", "ui_editor_particle_example_cursor_avoid", false),
        ("particles/exampleturbolence.json", "ui_editor_particle_example_turbulence", false),
        ("particles/example3d.json", "ui_editor_particle_example_basic", true),
        ("particles/exampleturbolence3d.json", "ui_editor_particle_example_turbulence", true),
    ]

    public var items: [Item]
    /// The assets have WE's presets folder (a copy made before presets were kept has none).
    public var hasPresets: Bool

    public init(items: [Item], hasPresets: Bool) {
        self.items = items
        self.hasPresets = hasPresets
    }

    /// The catalog of the WE assets in `assets`. `translate` reads WE's locale keys. The default
    /// systems are WE's list, then any other file of `particles/` (a 2D system titled by its name).
    public static func load(assetsDirectory assets: URL, translate: (String) -> String?,
                            fileManager: FileManager = .default) -> ParticleCatalog {
        var items: [Item] = []
        let particles = assets.appending(path: "particles", directoryHint: .isDirectory)
        // Optional: an asset tree without a particles folder has no default systems.
        let files = ((try? fileManager.contentsOfDirectory(atPath: particles.path(percentEncoded: false))) ?? [])
            .filter { $0.lowercased().hasSuffix(".json") && !$0.hasPrefix(".") }
        var listed = Set<String>()
        for system in defaultSystems where files.contains(where: { "particles/\($0)".lowercased() == system.path }) {
            listed.insert(system.path)
            items.append(Item(source: .system(path: system.path), title: translate(system.label) ?? title(ofFile: system.path),
                              summary: "", group: Group(kind: .systems(is3D: system.is3D), title: ""), is3D: system.is3D))
        }
        for file in files.sorted() where !listed.contains("particles/\(file)".lowercased()) {
            let path = "particles/\(file)"
            items.append(Item(source: .system(path: path), title: title(ofFile: path), summary: "",
                              group: Group(kind: .systems(is3D: false), title: ""), is3D: false))
        }
        let presetsDirectory = assets.appending(path: "presets", directoryHint: .isDirectory)
        let hasPresets = fileManager.fileExists(atPath: presetsDirectory.path(percentEncoded: false))
        for preset in ParticlePresetCatalog.load(presetsDirectory: presetsDirectory, translate: translate) {
            let group = Group(kind: .preset(preset.id), title: preset.title)
            for variant in preset.variants {
                items.append(Item(source: .preset(preset, variant: variant), title: variant.title, summary: preset.summary,
                                  group: group, is3D: preset.is3D))
            }
        }
        return ParticleCatalog(items: items, hasPresets: hasPresets)
    }

    /// `particles/examplecursorfollow.json` → `Examplecursorfollow`.
    static func title(ofFile path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The items matching `query` in their title, summary or group title, ignoring case and
    /// accents, every word of it somewhere; all of them for an empty query. In catalog order.
    public static func filter(_ items: [Item], query: String) -> [Item] {
        let words = query.split(whereSeparator: \.isWhitespace).map { EffectCatalog.fold(String($0)) }
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = EffectCatalog.fold([item.title, item.summary, item.group.title].joined(separator: " "))
            return words.allSatisfy(haystack.contains)
        }
    }

    /// Items by group: the default systems for the scene's kind first, then the presets by
    /// title, then the other kind's default systems.
    public static func grouped(_ items: [Item], sceneIs3D: Bool) -> [(group: Group, items: [Item])] {
        var order: [Group] = []
        var members: [Group: [Item]] = [:]
        for item in items {
            if members[item.group] == nil { order.append(item.group) }
            members[item.group, default: []].append(item)
        }
        func rank(_ group: Group) -> Int {
            switch group.kind {
            case .systems(let is3D): return is3D == sceneIs3D ? 0 : 2
            case .preset: return 1
            }
        }
        let sorted = order.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            if left != right { return left < right }
            if case .preset = lhs.element.kind, case .preset = rhs.element.kind {
                let comparison = lhs.element.title.localizedStandardCompare(rhs.element.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }
        return sorted.map { ($0.element, members[$0.element] ?? []) }
    }
}
