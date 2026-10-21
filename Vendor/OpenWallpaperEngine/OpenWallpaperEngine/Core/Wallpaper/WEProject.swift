//
//  WEProject.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI
import ImageIO

struct WEProjectPropertyOption: Codable, Equatable, Hashable {
    var label: String
    var value: String
}

struct WEProjectProperty: Codable, Equatable, Hashable {
    // optional
    var condition: String?
    var index: Int?
    var options: [WEProjectPropertyOption]?
    var order: Int?
    
    // must have
    var text: String
    var type: String
    var value: String
}

struct WEProjectProperties: Codable, Equatable, Hashable {
    var schemecolor: WEProjectProperty?
}

struct WEProjectGeneral: Codable, Equatable, Hashable {
    var properties: WEProjectProperties
}

enum WorkshopId: Codable, Equatable, Hashable, RawRepresentable {
    case int(Int)
    case string(String)
    
    var rawValue: String {
        switch self {
        case .int(let x):
            return String(x)
        case .string(let x):
            return x
        }
    }
    
    init?(rawValue: String) {
        guard rawValue.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self = .string(rawValue)
    }

    /// project.json writes the id as a number or a string; both name the same item.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Int.self) {
            self = .int(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Self.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Workshop ID"))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        }
    }
}

struct WEProject: Codable, Equatable, Hashable {
    var approved: Bool?
    var contentrating: String?
    var description: String?
    var file: String
    var general: WEProjectGeneral?
    /// The preview image, relative to the wallpaper's folder. WE loads a project without one (the
    /// effect gallery's generated projects have none), so it's optional.
    var preview: String?
    var tags: [String]?
    var title: String
    var visibility: String?
    var workshopid: WorkshopId?
    var workshopurl: String?
    var type: String
    var version: Int?
    /// `"official": true`: one of Wallpaper Engine's own default wallpapers (not a Workshop item),
    /// whose author is Wallpaper Engine.
    var official: Bool? = nil
    
    static let invalid = Self(file: "",
                              title: "Error",
                              type: "video")

    /// The preview image in `directory`; nil when the project names none.
    func previewURL(in directory: URL) -> URL? {
        guard let preview, !preview.isEmpty else { return nil }
        return directory.appending(path: preview)
    }
    
    var inferredContentRating: String? {
        let ratings = ["everyone", "questionable", "mature"]
        return tags?.first { tag in
            ratings.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).capitalized }
    }
    
    mutating func applyTaggedContentRating() {
        if let rating = inferredContentRating {
            contentrating = rating
        }
    }
}

extension WEProject {
    private enum DecodingKeys: String, CodingKey {
        case approved, contentrating, description, file, general, preview, tags, title, visibility
        case workshopid, workshopurl, type, version, category, official
    }

    /// Decodes as the synthesized decoder would, except that a project without `type` (WE's own
    /// default projects leave it out) takes the type its `file` implies, as WE does, and `file`
    /// must be a relative path inside the wallpaper (`sanitizedFile`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let written = try container.decode(String.self, forKey: .file)
        guard let file = Self.sanitizedFile(written) else {
            throw DecodingError.dataCorruptedError(forKey: .file, in: container,
                                                   debugDescription: "not a relative path inside the wallpaper: \(written)")
        }
        self.init(approved: try container.decodeIfPresent(Bool.self, forKey: .approved),
                  contentrating: try container.decodeIfPresent(String.self, forKey: .contentrating),
                  description: try container.decodeIfPresent(String.self, forKey: .description),
                  file: file,
                  general: try container.decodeIfPresent(WEProjectGeneral.self, forKey: .general),
                  preview: try container.decodeIfPresent(String.self, forKey: .preview),
                  tags: try container.decodeIfPresent([String].self, forKey: .tags),
                  title: try container.decode(String.self, forKey: .title),
                  visibility: try container.decodeIfPresent(String.self, forKey: .visibility),
                  workshopid: try container.decodeIfPresent(WorkshopId.self, forKey: .workshopid),
                  workshopurl: try container.decodeIfPresent(String.self, forKey: .workshopurl),
                  type: try container.decodeIfPresent(String.self, forKey: .type)
                      ?? Self.impliedType(file: file,
                                          category: try container.decodeIfPresent(String.self, forKey: .category)),
                  version: try container.decodeIfPresent(Int.self, forKey: .version),
                  official: try container.decodeIfPresent(Bool.self, forKey: .official))
    }

    /// `file` as the app uses it: a remote wallpaper's http(s) URL as written, an empty one as it
    /// is, and any other a clean relative path (`AssetPathResolver.sanitize`); nil for a path that
    /// is absolute or climbs out of the wallpaper's folder.
    static func sanitizedFile(_ file: String) -> String? {
        if file.isEmpty { return file }
        if let scheme = URL(string: file)?.scheme?.lowercased(), scheme == "http" || scheme == "https" { return file }
        return AssetPathResolver.sanitize(file)
    }

    /// The wallpaper type a project's `file` implies when `type` is absent. A Workshop asset pack
    /// (`category` "Asset", `file` usually `assets.json`) has no wallpaper type, so it stays out of
    /// the library as it did when a missing `type` failed to decode.
    static func impliedType(file: String, category: String? = nil) -> String {
        if category?.caseInsensitiveCompare("Asset") == .orderedSame { return "" }
        switch (file as NSString).pathExtension.lowercased() {
        case "json": return "scene"
        case "html", "htm": return "web"
        case "exe": return "application"
        case "mp4", "webm", "mov", "m4v", "avi", "mkv", "wmv": return "video"
        default: return ""
        }
    }
}
