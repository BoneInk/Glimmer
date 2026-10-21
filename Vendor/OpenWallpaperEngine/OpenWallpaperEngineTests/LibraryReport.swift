import XCTest

/// What a library test checked beyond its committed fixture (items that appeared, changed or left
/// the library since), printed and attached to the test so the log says when to refresh it.
enum LibraryReport {
    /// Prints `lines` under `title` and attaches them to the running test; nothing when empty.
    static func attach(_ title: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = ([title] + lines.map { "  " + $0 }).joined(separator: "\n")
        print(text)
        XCTContext.runActivity(named: title) { $0.add(XCTAttachment(string: text)) }
    }
}
