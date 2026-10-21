//
//  WebCompatPatches.swift
//  Open Wallpaper Engine
//
//  WE's `assets/zcompat/web/<workshopid>.json` fixes web wallpapers that newer browser engines
//  broke: `{"actions": [{"file", "replace", "insert"}]}`, where each action replaces the text
//  `replace` with `insert` in the wallpaper's `file` (a path relative to the wallpaper folder).
//  WE writes the patched files to disk; here they are patched in memory as they are served, so
//  the wallpaper's own files never change.
//

import Foundation

struct WebCompatPatches: Equatable {
    struct Action: Equatable {
        let file: String
        let replace: String
        let insert: String
    }

    let actions: [Action]

    var isEmpty: Bool { actions.isEmpty }

    init(actions: [Action]) {
        self.actions = actions
    }

    /// The patches for Workshop item `workshopId`, or nil when WE has none.
    init?(workshopId: String?, assetsDirectory: URL?) {
        guard let workshopId, !workshopId.isEmpty, workshopId.allSatisfy({ $0.isASCII && $0.isNumber }),
              let assetsDirectory else { return nil }
        let url = assetsDirectory.appending(path: "zcompat/web/\(workshopId).json")
        // Nearly every wallpaper has no entry; a missing file is the normal case.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try self.init(json: Data(contentsOf: url))
        } catch {
            OWELog.error(.web, "Failed to read zcompat \(url.path): \(error)")
            return nil
        }
        guard !isEmpty else { return nil }
    }

    init(json data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = root?["actions"] as? [Any] ?? []
        // Element by element, so one malformed action doesn't drop the rest.
        actions = entries.compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let file = entry["file"] as? String, let replace = entry["replace"] as? String,
                  let insert = entry["insert"] as? String, !replace.isEmpty else {
                OWELog.error(.web, "Skipping malformed zcompat action \(entry)")
                return nil
            }
            return Action(file: Self.normalize(file), replace: replace, insert: insert)
        }
    }

    func hasPatches(for relativePath: String) -> Bool {
        let path = Self.normalize(relativePath)
        return actions.contains { $0.file == path }
    }

    /// `contents` of `relativePath` with every action for that file applied, in order.
    func apply(to contents: Data, relativePath: String) -> Data {
        let path = Self.normalize(relativePath)
        let matching = actions.filter { $0.file == path }
        guard !matching.isEmpty else { return contents }
        guard var text = String(data: contents, encoding: .utf8) else {
            OWELog.error(.web, "zcompat: \(relativePath) is not UTF-8; served unpatched")
            return contents
        }
        for action in matching {
            guard text.contains(action.replace) else {
                OWELog.debug(.web, "zcompat: \(relativePath) doesn't contain the text to replace")
                continue
            }
            text = text.replacingOccurrences(of: action.replace, with: action.insert)
        }
        return Data(text.utf8)
    }

    static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
