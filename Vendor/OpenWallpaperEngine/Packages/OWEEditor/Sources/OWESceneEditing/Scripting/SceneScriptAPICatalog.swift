import Foundation

/// One autocomplete suggestion of the script editor.
public struct SceneScriptCompletion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case property, method, global, function, `class`, module, callback, keyword
    }

    public let label: String
    public let kind: Kind
    /// The member's declaration: `getEffect(nameOrIndex: String | Number): IEffect`.
    public let detail: String
    public let documentation: String?

    public var id: String { "\(kind.rawValue):\(label)" }

    public init(label: String, kind: Kind, detail: String, documentation: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
    }
}

/// SceneScript's API read from `SceneScriptTypings`: its interfaces and globals, and what the
/// editor suggests at a position of a script (the members of the expression before a `.`, else
/// the globals, callbacks and keywords).
public struct SceneScriptAPICatalog: Sendable {
    public struct Member: Hashable, Sendable {
        public let name: String
        public let isMethod: Bool
        public let isReadOnly: Bool
        /// The parameter list as declared, without parentheses; nil for a property.
        public let parameters: String?
        /// The declared (or returned) type.
        public let type: String
        public let documentation: String?

        public var declaration: String {
            if let parameters { return "\(name)(\(parameters)): \(type)" }
            return "\(isReadOnly ? "readonly " : "")\(name): \(type)"
        }
    }

    public struct Interface: Hashable, Sendable {
        public let name: String
        public let extends: [String]
        public let members: [Member]
        public let documentation: String?
    }

    public struct Global: Hashable, Sendable {
        public enum Kind: String, Sendable { case constant, function, `class`, module }
        public let name: String
        public let kind: Kind
        /// The global's type; a function's return type.
        public let type: String
        public let parameters: String?
        public let documentation: String?
    }

    public let interfaces: [String: Interface]
    /// `type Name = A & B`.
    public let aliases: [String: [String]]
    public let globals: [Global]

    /// The catalog of WE's SceneScript API.
    public static let standard = SceneScriptAPICatalog(typings: SceneScriptTypings.source)

    /// The callbacks a script can export (`export function update(value)`).
    public static let callbackInterface = "SceneScriptCallbacks"

    public static let keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                                  "delete", "do", "else", "export", "extends", "false", "finally", "for", "function",
                                  "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static",
                                  "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
                                  "void", "while", "yield"]

    /// JavaScript's own globals a script uses most.
    static let builtins = ["Math", "Date", "JSON", "Number", "String", "Boolean", "Array", "Object", "parseInt",
                           "parseFloat", "isNaN", "isFinite", "Float32Array", "Infinity", "NaN"]

    // MARK: Reading the typings

    public init(typings: String) {
        var interfaces: [String: Interface] = [:]
        var aliases: [String: [String]] = [:]
        var globals: [Global] = []
        var documentation: String?
        var current: (name: String, extends: [String], documentation: String?, members: [Member])?

        for rawLine in typings.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("/**") {
                documentation = line.dropFirst(3).replacingOccurrences(of: "*/", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("//") { continue }
            if var open = current {
                if line == "}" {
                    interfaces[open.name] = Interface(name: open.name, extends: open.extends, members: open.members,
                                                      documentation: open.documentation)
                    current = nil
                } else if let member = Self.member(line, documentation: documentation) {
                    open.members.append(member)
                    current = open
                }
                documentation = nil
                continue
            }
            if let match = Self.match(#"^interface\s+(\w+)(?:\s+extends\s+([\w\s,]+))?\s*\{\s*(\})?$"#, line) {
                let extends = match[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if match[2] == "}" {
                    interfaces[match[0]] = Interface(name: match[0], extends: extends, members: [], documentation: documentation)
                } else {
                    current = (match[0], extends, documentation, [])
                }
            } else if let match = Self.match(#"^type\s+(\w+)\s*=\s*([^;]+);$"#, line) {
                aliases[match[0]] = Self.parts(of: match[1])
            } else if let match = Self.match(#"^declare\s+const\s+(\w+)\s*:\s*([^;]+);$"#, line) {
                globals.append(Global(name: match[0], kind: .constant, type: match[1].trimmingCharacters(in: .whitespaces),
                                      parameters: nil, documentation: documentation))
            } else if let match = Self.match(#"^declare\s+function\s+(\w+)\s*\((.*)\)\s*:\s*([^;]+);$"#, line) {
                globals.append(Global(name: match[0], kind: .function, type: match[2].trimmingCharacters(in: .whitespaces),
                                      parameters: match[1], documentation: documentation))
            } else if let match = Self.match(#"^declare\s+(class|module)\s+(\w+)\s*:\s*([^;]+);$"#, line) {
                globals.append(Global(name: match[1], kind: match[0] == "class" ? .class : .module,
                                      type: match[2].trimmingCharacters(in: .whitespaces), parameters: nil,
                                      documentation: documentation))
            }
            documentation = nil
        }
        self.interfaces = interfaces
        self.aliases = aliases
        self.globals = globals
    }

    private static func member(_ line: String, documentation: String?) -> Member? {
        if let match = Self.match(#"^(\w+)\s*\((.*)\)\s*:\s*([^;]+);$"#, line) {
            return Member(name: match[0], isMethod: true, isReadOnly: false, parameters: match[1],
                          type: match[2].trimmingCharacters(in: .whitespaces), documentation: documentation)
        }
        if let match = Self.match(#"^(readonly\s+)?(\w+)\??\s*:\s*([^;]+);$"#, line) {
            return Member(name: match[1], isMethod: false, isReadOnly: !match[0].isEmpty, parameters: nil,
                          type: match[2].trimmingCharacters(in: .whitespaces), documentation: documentation)
        }
        return nil
    }

    /// The capture groups of `pattern` in `text` (an unmatched group is empty).
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// `A & B | C` as its named types (unions and intersections both offer every part's members).
    static func parts(of type: String) -> [String] {
        type.split(whereSeparator: { $0 == "&" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Members

    /// Every member of `type` (an interface, an alias, `A & B`), inherited ones included, first
    /// declaration of a name first.
    public func members(of type: String) -> [Member] {
        var seen = Set<String>()
        var visited = Set<String>()
        var result: [Member] = []
        func collect(_ name: String) {
            guard visited.insert(name).inserted else { return }
            if let alias = aliases[name] {
                alias.forEach(collect)
                return
            }
            guard let interface = interfaces[name] else { return }
            for member in interface.members where seen.insert(member.name).inserted { result.append(member) }
            interface.extends.forEach(collect)
        }
        Self.parts(of: type).forEach(collect)
        return result
    }

    public func member(_ name: String, of type: String) -> Member? {
        members(of: type).first { $0.name == name }
    }

    public func global(_ name: String) -> Global? {
        globals.first { $0.name == name }
    }

    /// Every member name of every interface, for a receiver whose type isn't known.
    var allMembers: [Member] {
        var seen = Set<String>()
        var result: [Member] = []
        for name in interfaces.keys.sorted() where name != Self.callbackInterface && !name.hasSuffix("Module") {
            for member in interfaces[name]!.members where seen.insert(member.name).inserted { result.append(member) }
        }
        return result
    }

    // MARK: Completing

    /// What to suggest at `offset` (UTF-16) of `text`: the range of the partial word to replace and
    /// the suggestions for it, best first.
    public func completions(in text: String, at offset: Int) -> (range: NSRange, items: [SceneScriptCompletion]) {
        let utf16 = Array(text.utf16)
        let end = max(0, min(offset, utf16.count))
        var start = end
        while start > 0, Self.isIdentifier(utf16[start - 1]) { start -= 1 }
        let prefix = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        let range = NSRange(location: start, length: end - start)
        let before = String(utf16CodeUnits: Array(utf16[0..<start]), count: start)

        // A module name in `import … from '`.
        if before.range(of: #"from\s+['"]$"#, options: .regularExpression) != nil {
            let modules = globals.filter { $0.kind == .module }.map {
                SceneScriptCompletion(label: $0.name, kind: .module, detail: "module \($0.name)", documentation: nil)
            }
            return (range, Self.filter(modules, prefix: prefix))
        }
        // In a comment or a string: nothing.
        if Self.isInsideCommentOrString(before) { return (range, []) }

        var items: [SceneScriptCompletion]
        if before.hasSuffix(".") {
            let receiver = Self.receiverChain(before.dropLast())
            items = memberCompletions(receiver: receiver, text: before)
        } else if before.range(of: #"export\s+(async\s+)?function\s+$"#, options: .regularExpression) != nil {
            items = members(of: Self.callbackInterface).map(Self.completion(callback:))
        } else {
            items = globals.map(Self.completion(global:))
            items += Self.builtins.map { SceneScriptCompletion(label: $0, kind: .global, detail: $0) }
            items += Self.keywords.map { SceneScriptCompletion(label: $0, kind: .keyword, detail: $0) }
        }
        return (range, Self.filter(items, prefix: prefix))
    }

    /// Suggestions starting with `prefix` (any case), exact-case matches first, then by name.
    static func filter(_ items: [SceneScriptCompletion], prefix: String) -> [SceneScriptCompletion] {
        var seen = Set<String>()
        let lowered = prefix.lowercased()
        let matching = items.filter { item in
            (prefix.isEmpty || item.label.lowercased().hasPrefix(lowered)) && seen.insert(item.label).inserted
        }
        return matching.sorted { lhs, rhs in
            let left = (lhs.label.hasPrefix(prefix) ? 0 : 1, lhs.label.lowercased())
            let right = (rhs.label.hasPrefix(prefix) ? 0 : 1, rhs.label.lowercased())
            return left < right
        }
    }

    private func memberCompletions(receiver: [ChainStep], text: String) -> [SceneScriptCompletion] {
        let members: [Member]
        if let type = resolve(receiver, in: text, depth: 0) {
            members = self.members(of: type)
        } else {
            members = allMembers
        }
        return members.map { member in
            SceneScriptCompletion(label: member.name, kind: member.isMethod ? .method : .property,
                                  detail: member.declaration, documentation: member.documentation)
        }
    }

    private static func completion(global: Global) -> SceneScriptCompletion {
        let kind: SceneScriptCompletion.Kind
        let detail: String
        switch global.kind {
        case .constant: kind = .global; detail = "\(global.name): \(global.type)"
        case .function: kind = .function; detail = "\(global.name)(\(global.parameters ?? "")): \(global.type)"
        case .class: kind = .class; detail = "class \(global.name)"
        case .module: kind = .module; detail = "module \(global.name)"
        }
        return SceneScriptCompletion(label: global.name, kind: kind, detail: detail, documentation: global.documentation)
    }

    private static func completion(callback: Member) -> SceneScriptCompletion {
        SceneScriptCompletion(label: callback.name, kind: .callback, detail: callback.declaration,
                              documentation: callback.documentation)
    }

    // MARK: Resolving the receiver

    enum ChainStep: Equatable {
        case name(String)
        case call
        case index
    }

    /// The expression before a `.` as steps: `thisScene.getLayer('x').origin` is
    /// `[name thisScene, name getLayer, call, name origin]`. Empty when it isn't a member chain.
    static func receiverChain<S: StringProtocol>(_ text: S) -> [ChainStep] {
        let characters = Array(text)
        var index = characters.count
        var steps: [ChainStep] = []
        while index > 0 {
            let character = characters[index - 1]
            if character == ")" || character == "]" {
                let open: Character = character == ")" ? "(" : "["
                var depth = 0
                var position = index - 1
                while position >= 0 {
                    if characters[position] == character { depth += 1 }
                    if characters[position] == open {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    position -= 1
                }
                guard position >= 0 else { return [] }
                steps.append(character == ")" ? .call : .index)
                index = position
                continue
            }
            guard character.isLetter || character.isNumber || character == "_" || character == "$" else { break }
            var position = index
            while position > 0, characters[position - 1].isLetter || characters[position - 1].isNumber
                    || characters[position - 1] == "_" || characters[position - 1] == "$" {
                position -= 1
            }
            steps.append(.name(String(characters[position..<index])))
            index = position
            if index > 0, characters[index - 1] == "." {
                index -= 1
                continue
            }
            if index > 0, characters[index - 1] == " " {
                // `new Vec3(…)`: the constructor's name is the type.
                let head = String(characters[0..<index]).trimmingCharacters(in: .whitespaces)
                let isNew = head == "new" || head.hasSuffix(" new") || head.hasSuffix("(new") || head.hasSuffix("=new")
                if isNew, case .name(let name)? = steps.last { steps[steps.count - 1] = .name("new " + name) }
            }
            break
        }
        return steps.reversed()
    }

    /// The type a chain evaluates to; nil when it can't be known.
    func resolve(_ chain: [ChainStep], in text: String, depth: Int) -> String? {
        guard case .name(let head)? = chain.first, depth < 4 else { return nil }
        var type: String?
        var methodPending: Member?
        var constructorCall = head.hasPrefix("new ")
        if head.hasPrefix("new ") {
            type = String(head.dropFirst(4))
        } else if let global = global(head) {
            switch global.kind {
            case .constant, .class, .module: type = global.type
            case .function: type = nil; methodPending = Member(name: head, isMethod: true, isReadOnly: false,
                                                                parameters: global.parameters, type: global.type,
                                                                documentation: nil)
            }
        } else if let module = Self.importedModule(head, in: text), let global = global(module) {
            type = global.type
        } else if let expression = Self.declaration(of: head, in: text) {
            let inner = Self.receiverChain(expression)
            type = inner.isEmpty ? nil : resolve(inner, in: text, depth: depth + 1)
        }
        for step in chain.dropFirst() {
            switch step {
            case .call:
                if constructorCall {
                    constructorCall = false
                    continue
                }
                guard let method = methodPending else { return nil }
                type = method.type
                methodPending = nil
            case .index:
                guard let current = type, current.hasSuffix("[]") else { return nil }
                type = String(current.dropLast(2))
            case .name(let name):
                guard let current = type, methodPending == nil, let member = member(name, of: current) else { return nil }
                if member.isMethod {
                    methodPending = member
                    type = nil
                } else {
                    type = member.type
                }
            }
        }
        guard methodPending == nil, let type else { return nil }
        return type
    }

    /// `import * as Name from 'Module'` (or `{ … }` imports bound to a namespace) in `text`.
    static func importedModule(_ name: String, in text: String) -> String? {
        let pattern = #"import\s+\*\s+as\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s+from\s+['"](\w+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The expression the last `let|const|var name =` before the cursor assigns.
    static func declaration(of name: String, in text: String) -> String? {
        let pattern = #"(?:let|const|var)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*([^;\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }

    static func isIdentifier(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }

    /// Whether the end of `text` is inside a comment or a string literal.
    static func isInsideCommentOrString(_ text: String) -> Bool {
        let tokens = JavaScriptTokenizer.tokens(in: text)
        guard let last = tokens.last else { return false }
        let length = (text as NSString).length
        guard NSMaxRange(last.range) == length else { return false }
        switch last.kind {
        case .lineComment: return true
        case .blockComment: return !text.hasSuffix("*/")
        case .string:
            let token = (text as NSString).substring(with: last.range)
            guard let quote = token.first else { return false }
            return token.count == 1 || token.last != quote || token.hasSuffix("\\\(quote)")
        case .template: return !text.hasSuffix("`") || last.range.length == 1
        default: return false
        }
    }
}
