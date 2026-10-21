import Foundation

/// What `SceneScriptModuleScanner` found at a module's top level: the source edits that turn it
/// into a function body, the modules it imports and the names it exports.
struct SceneScriptModuleLayout {
    enum Edit {
        /// Every unit of the range becomes a space except line terminators, so lines and columns
        /// stay put. `separator` makes the first unit `;`, so the statements before and after a
        /// removed statement are not joined (`foo()` + `(bar)` would otherwise become a call).
        case blank(Range<Int>, separator: Bool)
        /// `text`, then the range's line terminators, so later lines stay put.
        case replace(Range<Int>, with: String)

        var range: Range<Int> {
            switch self {
            case .blank(let range, _), .replace(let range, _): return range
            }
        }
    }

    struct Import {
        /// The module name as written (`'WEMath'`); the runtime resolves it case-insensitively.
        var specifier: String
        /// `import * as X`
        var namespace: String?
        /// `import D` is (`default`, `D`); `import { a as b }` is (`a`, `b`).
        var bindings: [(imported: String, local: String)] = []
        var line: Int
    }

    struct Export {
        /// The name importers and the runtime see.
        var name: String
        /// The module-scope binding it reads.
        var local: String
    }

    var edits: [Edit] = []
    var imports: [Import] = []
    var exports: [Export] = []
}
