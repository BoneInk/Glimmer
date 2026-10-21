import Foundation

/// The text layers that show the wall-clock time, day or date: those whose `text` script reads the
/// current date (`new Date`, `Date.now`, a `Date`'s fields). A recorded picture (the screen
/// saver's loop video, the lock-screen picture) would show the moment it was captured, so those
/// renders leave them out (`SceneMetalRenderer.hidesClockLayers`). The desktop always draws them.
/// A still leaves out more (`stillIDs`).
enum SceneClockLayers {
    private static let readsDate = try! NSRegularExpression(
        pattern: #"new\s+Date\b|Date\.now\b|\.get(UTC)?(Hours|Minutes|Seconds|Day|Date|Month|FullYear)\s*\(|toLocale(Time|Date)?String\s*\("#)

    /// Whether a script's source reads the current date or time.
    static func readsDate(_ source: String) -> Bool {
        readsDate.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }

    /// The ids of the scene document's clock text layers.
    static func ids(in document: SceneJSON) -> Set<String> {
        guard case .object(let root) = document, case .array(let objects)? = root["objects"] else { return [] }
        var ids: Set<String> = []
        for case .object(let object) in objects {
            guard case .object(let text)? = object["text"], case .string(let script)? = text["script"],
                  readsDate(script) else { continue }
            switch object["id"] {
            case .number(let id)?: ids.insert(String(Int(id)))
            case .string(let id)?: ids.insert(id)
            default: continue
            }
        }
        return ids
    }

    /// The ids of the layers a still leaves out (`SceneMetalRenderer.hidesStillLayers`), so a
    /// picture shown later never shows the time it was taken: every text layer (a clock, day or
    /// date, or text a script rewrites) and the clock hands, the layers whose rotation script
    /// (`angles`) reads the current date. Other date-reading scripts stay: in Workshop scenes they
    /// tint colours, fade layers in and out and switch day and night backgrounds, which a still
    /// shows as they stand.
    static func stillIDs(in document: SceneJSON) -> Set<String> {
        guard case .object(let root) = document, case .array(let objects)? = root["objects"] else { return [] }
        var ids: Set<String> = []
        for case .object(let object) in objects {
            let isText = object["text"] != nil
            var isHand = false
            if case .object(let angles)? = object["angles"], case .string(let script)? = angles["script"] {
                isHand = readsDate(script)
            }
            guard isText || isHand else { continue }
            switch object["id"] {
            case .number(let id)?: ids.insert(String(Int(id)))
            case .string(let id)?: ids.insert(id)
            default: continue
            }
        }
        return ids
    }
}
