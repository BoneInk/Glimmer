import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// The SceneScript corpus (`/Volumes/980Pro/dd-scenescript/corpus`, docs/scenescript-plan.md):
/// every script site of the library, extracted once by `dd-scenescript/extract.py` into
/// `index.json`. The library keeps gaining and updating wallpapers after that, so a corpus
/// wallpaper is compared with the index only while it is `current`: its folder still extracts to
/// the same sites. One that changed or left the library is reported, not failed.
enum SceneScriptCorpus {
    static let directory = URL(fileURLWithPath: "/Volumes/980Pro/dd-scenescript/corpus", isDirectory: true)
    static let roots = [
        "workshop": URL(fileURLWithPath: "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"),
        "owe": URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage"),
    ]

    struct Entry {
        var file: String
        var field: String
        var hash: String
    }

    struct Wallpaper {
        /// `library/id`, as the tests label it.
        var label: String
        var id: String
        /// Nil when the library root isn't one of `roots`.
        var directory: URL?
        var entries: [Entry]
    }

    /// The index's wallpapers with script sites, by label.
    static func wallpapers() throws -> [Wallpaper] {
        let index = directory.appending(path: "index.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]] ?? []
        var byLabel: [String: Wallpaper] = [:]
        for entry in json {
            guard let hash = entry["hash"] as? String, let library = entry["library"] as? String,
                  let id = entry["wallpaper"] as? String else { continue }
            let label = "\(library)/\(id)"
            byLabel[label, default: Wallpaper(label: label, id: id,
                                              directory: roots[library]?.appending(path: id, directoryHint: .isDirectory),
                                              entries: [])]
                .entries.append(Entry(file: entry["file"] as? String ?? "", field: "\(entry["field"] ?? "")", hash: hash))
        }
        return byLabel.values.sorted { $0.label < $1.label }
    }

    enum State {
        case current
        /// The folder extracts to other sites than the index lists.
        case changed
        case removed
    }

    /// Whether `wallpaper`'s folder extracts, as `extract.py` extracts it, to the index's sites.
    static func state(of wallpaper: Wallpaper) -> State {
        guard let directory = wallpaper.directory,
              FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path) else { return .removed }
        let now = extract(directory).map { "\($0.file)\u{0}\($0.field)\u{0}\($0.hash)" }.sorted()
        let then = wallpaper.entries.map { "\($0.file)\u{0}\($0.field)\u{0}\($0.hash)" }.sorted()
        return now == then ? .current : .changed
    }

    /// `extract.py`'s sites of one folder: `scene.pkg`'s entries, then the loose `.json` files it
    /// doesn't have; in each JSON document every object with a non-blank string `script`. A file
    /// that isn't JSON has none.
    static func extract(_ directory: URL) -> [Entry] {
        var files: [String: Data] = [:]
        let package = directory.appending(path: "scene.pkg")
        if FileManager.default.fileExists(atPath: package.path) {
            do {
                let parser = try PKGParser(url: package)
                for name in parser.fileList { files[name] = parser.extractFile(named: name) }
            } catch {
                XCTFail("\(package.path): \(error)")
            }
        }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
            if files[relative] == nil { files[relative] = FileManager.default.contents(atPath: url.path) }
        }
        var entries: [Entry] = []
        for (name, data) in files where name.hasSuffix(".json") {
            let text = String(decoding: data, as: UTF8.self)
            let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            // Not JSON: extract.py skips it too.
            guard let document = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) else {
                continue
            }
            walk(document, path: []) { path, script in
                let isObject = name == "scene.json" && path.count >= 2 && path[0] == "objects"
                let field = (isObject ? Array(path.dropFirst(2)) : path).joined(separator: ".")
                entries.append(Entry(file: name, field: field, hash: SceneScriptReplayWallpaper.hash(script)))
            }
        }
        return entries
    }

    private static func walk(_ node: Any, path: [String], found: (_ path: [String], _ script: String) -> Void) {
        if let object = node as? [String: Any] {
            if let script = object["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found(path, script)
            }
            for (key, value) in object where key != "script" { walk(value, path: path + [key], found: found) }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() { walk(value, path: path + [String(index)], found: found) }
        }
    }

    /// The attachment lines for the wallpapers a corpus test couldn't compare.
    static func notes(changed: [String], removed: [String]) -> [String] {
        var lines: [String] = []
        if !changed.isEmpty {
            lines.append("\(changed.count) corpus wallpapers changed since the corpus was extracted, not compared with its "
                         + "index: \(changed.joined(separator: ", "))")
        }
        if !removed.isEmpty {
            lines.append("\(removed.count) corpus wallpapers no longer in the library, skipped: \(removed.joined(separator: ", "))")
        }
        if !lines.isEmpty { lines.append("Refresh the corpus: /Volumes/980Pro/dd-scenescript/extract.py") }
        return lines
    }
}
