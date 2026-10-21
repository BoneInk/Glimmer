import Foundation
import OWESceneEditing

/// The previews one helper run renders (`--render-editor-previews <job.json>`), in order. The
/// helper writes a line `done <index>` to standard output as each one is finished, written or not.
/// With `-` for the job file (`streamArgument`) the helper reads items from standard input
/// instead, one JSON line each (`streamLine`), numbered from 0, until it is closed: the background
/// pre-warm keeps one helper per lane for every preview it renders.
struct EditorPreviewJob: Codable, Equatable {
    struct Item: Codable, Equatable {
        var subject: EditorPreviewSubject
        /// The file to write, without its extension (`EditorPreviewCache.outputBase`).
        var outputBase: String
        /// In a stream: a browser shows it, so the helper renders it out of the background
        /// (`EditorPreviewRenderer.runStream`). Nil (false) otherwise.
        var isUrgent: Bool?
    }

    var items: [Item]

    static let streamArgument = "-"

    static func doneLine(_ index: Int) -> String { "done \(index)\n" }

    /// An item as a line of the helper's standard input.
    static func streamLine(_ item: Item) throws -> Data {
        try JSONEncoder().encode(item) + Data("\n".utf8)
    }

    /// The index a `done` line reports; nil for any other line.
    static func doneIndex(fromLine line: Substring) -> Int? {
        guard line.hasPrefix("done ") else { return nil }
        return Int(line.dropFirst("done ".count).trimmingCharacters(in: .whitespaces))
    }
}
