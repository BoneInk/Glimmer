import Foundation

/// The Workshop tab's search text as WE sends it to Steam (`P()` in WE's `ui/dist/scripts/scripts.js`).
///
/// Steam matches a quoted phrase in `search_text` as a phrase, so text the user quotes is sent as
/// it is. WE's "Exact phrase" checkbox, which it shows once the search has a space in it, quotes
/// the whole search unless it already has a quote.
enum WorkshopSearchText {
    /// Whether WE shows "Exact phrase" for `text`: it has a space between words.
    static func offersExactPhrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).contains(" ")
    }

    /// The `search_text` QueryFiles gets for `text`.
    static func steamText(_ text: String, exactPhrase: Bool) -> String {
        guard exactPhrase, !text.isEmpty, !text.trimmingCharacters(in: .whitespaces).contains("\"") else { return text }
        return "\"" + text + "\""
    }
}
