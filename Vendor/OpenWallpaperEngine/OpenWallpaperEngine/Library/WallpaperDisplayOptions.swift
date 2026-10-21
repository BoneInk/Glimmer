import CoreGraphics
import Foundation
import QuartzCore

/// WE's per-wallpaper display options (`ui_browse_properties_alignment_*`, `…_playback_rate`;
/// WE stores them per monitor as `alignmentx`, `alignmenty`, `alignmentz`, `alignmentfliph`):
/// where the picture sits on one display beyond its placement, and a video's speed. Kept per
/// wallpaper and display (`WallpaperDisplayOptionsStore`). The picture options apply when the
/// frame is shown (`WallpaperDisplayTransformView`), so changing them draws nothing again.
struct WallpaperDisplayOptions: Codable, Equatable {
    /// The picture's offset as a share of the display's width, right positive (−1…1).
    var offsetX: Double = 0
    /// The picture's offset as a share of the display's height, up positive (−1…1).
    var offsetY: Double = 0
    /// The picture's scale about the display's centre (`zoomRange`).
    var zoom: Double = 1
    /// Mirrored left to right (WE's "Flip").
    var flipHorizontal = false
    /// Mirrored top to bottom.
    var flipVertical = false
    /// A video's speed, times the app's (`playbackRateRange`). WE offers it for videos only.
    var playbackRate: Double = 1

    static let identity = WallpaperDisplayOptions()
    static let offsetRange: ClosedRange<Double> = -1...1
    static let zoomRange: ClosedRange<Double> = 0.25...4
    static let playbackRateRange: ClosedRange<Double> = 0.1...4

    /// Whether the picture options move, scale or mirror the picture.
    var transformsPicture: Bool {
        offsetX != 0 || offsetY != 0 || zoom != 1 || flipHorizontal || flipVertical
    }

    /// The picture options with every value inside its range.
    var clamped: WallpaperDisplayOptions {
        var options = self
        options.offsetX = min(max(offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        options.offsetY = min(max(offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        options.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        options.playbackRate = min(max(playbackRate, Self.playbackRateRange.lowerBound), Self.playbackRateRange.upperBound)
        return options
    }

    /// The transform that places a frame of `size` (y up) on the display: scaled by `zoom` and
    /// mirrored about its centre, then moved by the offset. `anchor` is the point, relative to
    /// the layer's bounds origin, the transform is applied about (Core Animation applies a layer's
    /// `sublayerTransform` about its anchor point).
    func transform(size: CGSize, anchor: CGPoint = .zero) -> CGAffineTransform {
        let center = CGPoint(x: size.width / 2 - anchor.x, y: size.height / 2 - anchor.y)
        let scaleX = zoom * (flipHorizontal ? -1 : 1)
        let scaleY = zoom * (flipVertical ? -1 : 1)
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: center.x + offsetX * size.width,
                                             y: center.y + offsetY * size.height))
    }

    /// Reads each value on its own; a missing or unreadable one keeps its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) {
            do {
                if let stored = try container.decodeIfPresent(Value.self, forKey: key) { value = stored }
            } catch {
                OWELog.error(.library, "Display option \(key.stringValue) can't be read and keeps its default: \(error)")
            }
        }
        read(.offsetX, &offsetX)
        read(.offsetY, &offsetY)
        read(.zoom, &zoom)
        read(.flipHorizontal, &flipHorizontal)
        read(.flipVertical, &flipVertical)
        read(.playbackRate, &playbackRate)
        self = clamped
    }

    init(offsetX: Double = 0, offsetY: Double = 0, zoom: Double = 1, flipHorizontal: Bool = false,
         flipVertical: Bool = false, playbackRate: Double = 1) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.zoom = zoom
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.playbackRate = playbackRate
    }
}

/// Every wallpaper's display options, per wallpaper (`WallpaperSettingsIdentity`, so they follow
/// the wallpaper when the library moves) and display, stored in one `UserDefaults` entry
/// (`defaultsKey`). Options at their defaults aren't stored.
@MainActor
final class WallpaperDisplayOptionsStore: ObservableObject {
    static let defaultsKey = "WallpaperDisplayOptions"

    @Published private(set) var entries: [String: WallpaperDisplayOptions]
    /// Nil: kept in memory only (a preview's wallpapers).
    private let defaults: UserDefaults?
    /// Each wallpaper folder's identity, resolved once.
    private var identities: [String: String] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = defaults.map(Self.load(from:)) ?? [:]
    }

    /// The entry key of `identity` on `screenID`.
    nonisolated static func key(identity: String, screenID: String) -> String { "\(identity)|\(screenID)" }

    func options(for wallpaper: WEWallpaper, on screenID: String) -> WallpaperDisplayOptions {
        entries[Self.key(identity: identity(of: wallpaper), screenID: screenID)] ?? .identity
    }

    func set(_ options: WallpaperDisplayOptions, for wallpaper: WEWallpaper, on screenIDs: Set<String>) {
        let identity = identity(of: wallpaper)
        var entries = entries
        let options = options.clamped
        for screenID in screenIDs {
            entries[Self.key(identity: identity, screenID: screenID)] = options == .identity ? nil : options
        }
        guard entries != self.entries else { return }
        self.entries = entries
        save()
    }

    /// WE's "Copy to": `wallpaper`'s options on `source` become its options on `destination`.
    func copy(for wallpaper: WEWallpaper, from source: String, to destination: String) {
        set(options(for: wallpaper, on: source), for: wallpaper, on: [destination])
    }

    /// WE's "Swap with" of one wallpaper shown on both: its options on `first` and `second` change places.
    func swap(for wallpaper: WEWallpaper, _ first: String, _ second: String) {
        let firstOptions = options(for: wallpaper, on: first), secondOptions = options(for: wallpaper, on: second)
        set(secondOptions, for: wallpaper, on: [first])
        set(firstOptions, for: wallpaper, on: [second])
    }

    private func identity(of wallpaper: WEWallpaper) -> String {
        let path = wallpaper.settingsDirectory.standardizedFileURL.path
        if let identity = identities[path] { return identity }
        let identity = defaults.map { WallpaperSettingsIdentity.resolve(wallpaper, defaults: $0).rawValue }
            ?? WallpaperSettingsIdentity(directory: wallpaper.settingsDirectory, projectData: nil).rawValue
        identities[path] = identity
        return identity
    }

    /// The stored entries, read one by one: an unreadable one is dropped and logged.
    static func load(from defaults: UserDefaults) -> [String: WallpaperDisplayOptions] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        let raw: [String: Any]
        do {
            raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            OWELog.error(.library, "Wallpaper display options can't be read; none are applied: \(error)")
            return [:]
        }
        var entries: [String: WallpaperDisplayOptions] = [:]
        for (key, value) in raw {
            do {
                let entry = try JSONSerialization.data(withJSONObject: value)
                entries[key] = try JSONDecoder().decode(WallpaperDisplayOptions.self, from: entry)
            } catch {
                OWELog.error(.library, "Display options \(key) can't be read and are dropped: \(error)")
            }
        }
        return entries
    }

    private func save() {
        guard let defaults else { return }
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.library, "Wallpaper display options can't be saved: \(error)")
        }
    }
}
