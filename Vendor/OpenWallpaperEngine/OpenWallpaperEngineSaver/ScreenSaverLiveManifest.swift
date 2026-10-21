import Foundation

/// The live screen saver's frames: while the screen saver runs, the app renders each loop of the
/// screen saver's layout (`ScreenSaverLayoutPlan`) into a ring of global IOSurfaces and lists them
/// here, in `live.json` in the shared folder (`ScreenSaverManifest.sharedFolder`). The
/// legacy `.saver` looks the surfaces up by id (`IOSurfaceLookup`), which its host's sandbox
/// allows, and shows the newest one a Darwin notification names (`ScreenSaverLiveStamp`).
///
/// The file changes only when the rings do (the screen saver starts or stops, the plan changes);
/// frames are announced by the notification alone. An empty manifest (no rings) means no live
/// frames: the saver shows its still. Shared by the app, the `.saver` and the extension, so it
/// uses Foundation only.
struct ScreenSaverLiveManifest: Codable, Equatable {
    /// Bump when the format changes; a saver ignores a manifest of another revision.
    static let revision = 1
    static let fileName = "live.json"

    /// A ring of surfaces one loop is drawn into, in turn.
    struct Ring: Codable, Equatable {
        /// The ring's place in `rings`, which stamps name (`ScreenSaverLiveStamp.ring`).
        var id: Int
        var width: Int
        var height: Int
        /// The surfaces' global ids (`IOSurfaceGetID`), in ring order.
        var surfaces: [UInt32]
        /// The Darwin notification posted for each frame, whose state is its stamp.
        var notifyName: String
    }

    /// What a display shows: a ring, whole or (a stretch) a rect of it.
    struct Display: Codable, Equatable {
        /// The display's identity (`CGDisplayCreateUUIDFromDisplayID`); nil for any display.
        var display: String?
        var ring: Int
        /// The rect of the ring's frames the display shows; nil for the whole frame.
        var crop: ScreenSaverManifest.Crop?
    }

    var revision = ScreenSaverLiveManifest.revision
    /// Counts up with every new set of rings (wraps at `UInt16.max`); stamps carry it, so a saver
    /// never shows a frame of rings it hasn't read.
    var generation = 0
    /// The app process that draws the frames.
    var pid: Int32 = 0
    /// The rate the frames are drawn at, per second.
    var frameRate = 0
    var rings: [Ring] = []
    var displays: [Display] = []

    /// Whether it lists any frames.
    var isLive: Bool { !rings.isEmpty && !displays.isEmpty }

    /// The ring and display entry for the display `display` (its identity; nil when unknown) in a
    /// view of `pixels`: the entry naming it, else one for any display. A known display that isn't
    /// listed has no live frames (it shows its still: its loop isn't drawn live); an unknown one
    /// takes the whole ring nearest the view's size and shape.
    func entry(forDisplay display: String?, pixels: (width: Int, height: Int)) -> (display: Display, ring: Ring)? {
        func resolved(_ entry: Display) -> (display: Display, ring: Ring)? {
            rings.first { $0.id == entry.ring }.map { (entry, $0) }
        }
        if let display, let named = displays.first(where: { $0.display == display }) { return resolved(named) }
        if let any = displays.first(where: { $0.display == nil }) { return resolved(any) }
        guard display == nil else { return nil }
        let whole = displays.filter { $0.crop == nil }
        let candidates = whole.isEmpty ? displays : whole
        func score(_ entry: Display) -> Double {
            guard let ring = rings.first(where: { $0.id == entry.ring }), ring.width > 0, ring.height > 0,
                  pixels.width > 0, pixels.height > 0 else { return .infinity }
            let aspect = abs(log(Double(ring.width) / Double(ring.height) / (Double(pixels.width) / Double(pixels.height))))
            let area = abs(log(Double(ring.width * ring.height) / Double(pixels.width * pixels.height)))
            return aspect * 4 + area
        }
        return candidates.min { score($0) < score($1) }.flatMap(resolved)
    }

    /// Reads the manifest at `url`; nil when there is none, it can't be read or it is of another
    /// revision (an older or newer app).
    static func read(_ url: URL) -> ScreenSaverLiveManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil } // Optional: no live frames yet.
        do {
            let manifest = try JSONDecoder().decode(ScreenSaverLiveManifest.self, from: data)
            return manifest.revision == revision ? manifest : nil
        } catch {
            return nil // A half-written or foreign file: no live frames, the still shows.
        }
    }
}
