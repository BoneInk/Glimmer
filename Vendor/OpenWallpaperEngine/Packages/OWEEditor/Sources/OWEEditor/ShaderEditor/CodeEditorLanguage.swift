import AppKit
import OWESceneEditing

/// What the code editor (`CodeEditorView`) edits: a SceneScript (JavaScript, SceneScript's API)
/// or a WE shader (GLSL in WE's dialect, `ShaderLanguage`), as WE's Monaco editor switches
/// between `javascript` and `cpp`.
enum CodeEditorLanguage: Sendable {
    case sceneScript
    case shader

    /// The colour of each token that has one.
    func colors(in text: String) -> [(range: NSRange, color: NSColor)] {
        switch self {
        case .sceneScript:
            return JavaScriptTokenizer.tokens(in: text).compactMap { token in
                CodeEditorStyle.color(token.kind).map { (token.range, $0) }
            }
        case .shader:
            return ShaderTokenizer.tokens(in: text).compactMap { token in
                Self.color(token.kind).map { (token.range, $0) }
            }
        }
    }

    /// The partial word at `offset` and what to complete it with.
    func completions(in text: String, at offset: Int, catalog: SceneScriptAPICatalog) -> (range: NSRange, items: [SceneScriptCompletion]) {
        switch self {
        case .sceneScript: return catalog.completions(in: text, at: offset)
        case .shader: return ShaderLanguage.completions(in: text, at: offset)
        }
    }

    /// A `.` offers members (SceneScript's objects); a shader's `.` is a swizzle.
    var completesAfterDot: Bool { self == .sceneScript }

    var accessibilityLabel: String {
        switch self {
        case .sceneScript: return L("Script")
        case .shader: return L("Shader")
        }
    }

    static func color(_ kind: ShaderToken.Kind) -> NSColor? {
        switch kind {
        case .keyword: return .systemPink
        case .type: return .systemIndigo
        case .builtin: return .systemTeal
        case .engine: return .systemBlue
        case .string: return .systemRed
        case .number: return .systemPurple
        case .comment: return .systemGray
        case .preprocessor: return .systemOrange
        case .identifier, .punctuation: return nil
        }
    }
}
