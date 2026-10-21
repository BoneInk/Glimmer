import Foundation

/// What `WEReferenceComparisonTests` compares: WE's captures (tools/peer on the
/// `we-test-wp-images` branch) and, per wallpaper, the settings they were taken with, the regions
/// that can't match (clocks, particles, media widgets) and the item's own checks. Read from
/// `Tests/Fixtures/WEReference/captures.json`.
struct WEReferenceConfig: Decodable {
    /// Rows at the bottom of every capture covered by the Windows taskbar.
    var taskbarHeight: Int
    var grid: Grid
    var items: [Item]

    struct Grid: Decodable {
        var columns: Int
        var rows: Int
    }

    /// x, y (from the top-left), width, height, in capture pixels.
    struct Rect: Decodable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            x = try values.decode(Int.self)
            y = try values.decode(Int.self)
            width = try values.decode(Int.self)
            height = try values.decode(Int.self)
        }

        func contains(x px: Int, y py: Int) -> Bool {
            px >= x && px < x + width && py >= y && py < y + height
        }

        var description: String { "x \(x)–\(x + width), y \(y)–\(y + height)" }
    }

    struct Mask: Decodable {
        var rect: Rect
        var reason: String
    }

    /// A region whose mean brightness is reported for WE and for us.
    struct Region: Decodable {
        var name: String
        var rect: Rect
    }

    struct Item: Decodable {
        var id: String
        var title: String
        /// What the capture checks, for the report.
        var focus: String
        var captures: [Capture]
        var masks: [Mask]?
        var regions: [Region]?
        var parallax: Parallax?
    }

    /// One folder of stills taken with one set of settings.
    struct Capture: Decodable {
        var folder: String
        /// WE's `volumetrics` and `shadows` settings (`GSLightingQuality` raw values); medium when absent.
        var volumetrics: String?
        var shadows: String?
        /// WE's `postprocessing` setting (`GSPostProcessingQuality` raw value); enabled when absent.
        var postProcessing: String?
        /// WE's `resolution` setting as its config holds it (`full`, `half`, anything else is
        /// `auto`: `GSTextureResolutionQuality(weConfigValue:)`); full when absent.
        var textureResolution: String?
        /// Stills; WE's two, 10 s and 12 s after the wallpaper opened, when absent.
        var stills: [Still]?
        /// Another capture of the item whose first still is the baseline for this one's: the
        /// setting's own light (brightness, centroid and direction of what it adds).
        var baseline: String?
        /// The wall-clock time (HH:mm or HH:mm:ss) the first still was taken at, read off the
        /// capture's clock, for wallpapers that show the time or follow the time of day.
        var localTime: String?
        /// Stills known not to be comparable (a transition frame), reported but not ranked.
        var unreliable: [String]?

        var resolvedStills: [Still] {
            stills ?? [Still(file: "still1.png", time: 10, cursor: nil), Still(file: "still2.png", time: 12, cursor: nil)]
        }
    }

    struct Still: Decodable {
        var file: String
        /// Seconds of scene time at the capture.
        var time: Double
        /// Screen pixels from the top-left; the screen's centre when absent.
        var cursor: [Double]?
    }

    /// Cursor parallax: the image's shift between the first still and each other, WE's and ours.
    struct Parallax: Decodable {
        var from: String
        var to: [String]
        var rect: Rect
    }

    static func load() throws -> WEReferenceConfig {
        try JSONDecoder().decode(WEReferenceConfig.self, from: Fixtures.data("WEReference/captures.json"))
    }
}
