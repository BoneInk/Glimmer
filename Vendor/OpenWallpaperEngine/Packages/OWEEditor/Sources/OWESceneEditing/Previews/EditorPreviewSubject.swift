import CryptoKit
import Foundation
import WEFormat

/// What an editor preview shows (`EditorPreviewCache`): an effect applied to the test card, or a
/// particle system on a dark background.
public enum EditorPreviewSubject: Codable, Hashable, Sendable {
    /// An effect (`effects/<name>/effect.json`) with its default values. `wallpaper` is the folder
    /// of the wallpaper that ships it, for a Workshop effect; nil for one of WE's.
    case effect(file: String, wallpaper: String?)
    /// One of WE's default systems (`particles/example.json`), as a new system starts.
    case particleSystem(path: String, is3D: Bool)
    /// A variant of one of WE's presets (`presets/<name>`, by its index in the preset's variants).
    case particlePreset(directory: String, variant: Int, is3D: Bool)

    /// A particle preview always moves; an effect's moves only when its output changes over time.
    public var isParticle: Bool {
        if case .effect = self { return false }
        return true
    }

    /// A 3D particle system, seen through WE's particle editor camera.
    public var is3D: Bool {
        switch self {
        case .effect: return false
        case .particleSystem(_, let is3D), .particlePreset(_, _, let is3D): return is3D
        }
    }

    /// The preview's file name without its extension: readable, and unique by a digest of the
    /// whole subject (a Workshop effect's wallpaper included).
    public var cacheName: String {
        let readable: String
        let identity: String
        switch self {
        case .effect(let file, let wallpaper):
            readable = "effect-" + ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            identity = "effect|\(file.lowercased())|\(wallpaper ?? "")"
        case .particleSystem(let path, let is3D):
            readable = "system-" + ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            identity = "system|\(path.lowercased())|\(is3D)"
        case .particlePreset(let directory, let variant, let is3D):
            readable = "preset-\((directory as NSString).lastPathComponent)-\(variant)"
            identity = "preset|\((directory as NSString).lastPathComponent.lowercased())|\(variant)|\(is3D)"
        }
        let digest = Digest.hex(SHA256.hash(data: Data(identity.utf8)).prefix(6))
        return Self.fileSafe(readable) + "-" + digest
    }

    /// `text` with only letters, digits, `-` and `_`, at most 60 characters.
    static func fileSafe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = text.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" }
        return String(String(scalars).prefix(60))
    }
}
