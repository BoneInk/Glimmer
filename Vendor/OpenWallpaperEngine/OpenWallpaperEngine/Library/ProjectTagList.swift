import Foundation

/// Edits to project.json's `tags` from the Details inspector: tags are trimmed, empty ones dropped
/// and duplicates (ignoring case) removed, keeping the first spelling and the written order, so an
/// edit rewrites only what changed.
enum ProjectTagList {
    static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// `tags` with `tag` appended unless it's empty or there already.
    static func adding(_ tag: String, to tags: [String]) -> [String] {
        normalized(tags + [tag])
    }

    /// `tags` without `tag` (ignoring case).
    static func removing(_ tag: String, from tags: [String]) -> [String] {
        let removed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized(tags).filter { $0.lowercased() != removed }
    }
}
