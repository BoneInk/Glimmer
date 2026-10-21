import Foundation

/// The module compiler (docs/scenescript-plan.md §4.2, WP3): turns a WE script, an ES module, into
/// the factory `SceneScriptModuleCompiling` specifies, for scripts and WE's jsmodules alike.
///
/// ```js
/// (function (__rt, __scope) { 'use strict'; const thisLayer = …, thisObject = …; <imports>
///   return Object.freeze(Object.setPrototypeOf((function (__rt) { <source, imports and `export` blanked>
/// ;return { get "update"() { return update; }, … }; })(), null)); })
/// ```
///
/// - Everything up to the source is on line 1 and blanked statements keep their line breaks, so
///   line N of the source is line N of the factory. Columns stay put except on line 1.
/// - The source runs in its own function scope inside the one holding `thisLayer`, `thisObject`
///   and the imports, so a script's top-level names can shadow WE's globals, as in a module.
/// - Imports are resolved before the body runs, in source order (`__scope.require`). A missing
///   named import throws V8's SyntaxError when the module is evaluated.
/// - The source's own scope has a parameter `__rt` that is always undefined, so a script can't
///   name the runtime object the factory receives (test-risks S28); the global `__rt` hides itself
///   while script code runs (runtime.js).
/// - The exports object is a frozen, prototype-less namespace with one getter per export, keys
///   sorted like a module namespace: `export let` stays live and nothing but the exported names is
///   visible (WE calls only exported callbacks).
struct SceneScriptModuleTransformer: SceneScriptModuleCompiling {
    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let units = Array(source.utf16)
        let tokens = try SceneScriptTokenizer.tokenize(units)
        var scanner = SceneScriptModuleScanner(tokens: tokens)
        var layout = try scanner.scan()
        if units.count >= 2, units[0] == 0x23, units[1] == 0x21 {
            let end = units.firstIndex(where: SceneScriptSyntax.isLineTerminator) ?? units.count
            layout.edits.insert(.blank(0..<end, separator: false), at: 0)
        }
        let body = Self.apply(layout.edits, to: units)
        return SceneScriptCompiledModule(factorySource: Self.header(layout.imports) + body + Self.footer(layout.exports))
    }

    private static func header(_ imports: [SceneScriptModuleLayout.Import]) -> String {
        var header = "(function (__rt, __scope) { 'use strict'; "
            + "const thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        for (index, entry) in imports.enumerated() {
            let module = "__oweImport\(index)"
            let specifier = SceneScriptStringLiteral.literal(entry.specifier)
            header += "const \(module) = __scope.require(\(specifier)); "
            if let namespace = entry.namespace { header += "const \(namespace) = \(module); " }
            for binding in entry.bindings {
                let key = SceneScriptStringLiteral.literal(binding.imported)
                let message = SceneScriptStringLiteral.literal(
                    "The requested module '\(entry.specifier)' does not provide an export named '\(binding.imported)'")
                header += "if (!(\(key) in \(module))) throw new SyntaxError(\(message)); "
                    + "const \(binding.local) = \(module)[\(key)]; "
            }
        }
        return header + "return Object.freeze(Object.setPrototypeOf((function (__rt) { "
    }

    private static func footer(_ exports: [SceneScriptModuleLayout.Export]) -> String {
        // A module namespace lists its keys in code-unit order (ECMAScript §10.4.6).
        let getters = exports
            .sorted { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }
            .map { "get \(SceneScriptStringLiteral.literal($0.name))() { return \($0.local); }" }
            .joined(separator: ", ")
        return "\n;return { \(getters) }; })(), null)); })"
    }

    /// Applies non-overlapping edits in source order.
    private static func apply(_ edits: [SceneScriptModuleLayout.Edit], to units: [UInt16]) -> String {
        let ordered = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var output: [UInt16] = []
        output.reserveCapacity(units.count + 64)
        var position = 0
        for edit in ordered {
            let range = edit.range
            output.append(contentsOf: units[position..<range.lowerBound])
            switch edit {
            case .blank(_, let separator):
                for (offset, unit) in units[range].enumerated() {
                    if SceneScriptSyntax.isLineTerminator(unit) {
                        output.append(unit)
                    } else {
                        output.append(separator && offset == 0 ? 0x3B : 0x20)
                    }
                }
            case .replace(_, let text):
                output.append(contentsOf: text.utf16)
                output.append(contentsOf: units[range].filter(SceneScriptSyntax.isLineTerminator))
            }
            position = range.upperBound
        }
        output.append(contentsOf: units[position...])
        return String(decoding: output, as: UTF16.self)
    }
}
