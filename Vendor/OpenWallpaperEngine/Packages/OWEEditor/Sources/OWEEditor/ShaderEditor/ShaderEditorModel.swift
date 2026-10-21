import Combine
import Foundation
import OWESceneEditing

/// What the shader editor needs from the app: its translator, as the scene loader uses it, and
/// WE's snippet files from the user's WE copy.
public struct ShaderEditorServices {
    /// Translates a pair as the loader would and maps its problems to the edited lines.
    public var checker: any ShaderChecking
    /// WE's snippet `<name>` (`ui/dist/monaco/snippets/<name>.js` of the user's WE copy); nil
    /// when the copy has none.
    public var snippet: (String) -> String?

    public init(checker: any ShaderChecking, snippet: @escaping (String) -> String?) {
        self.checker = checker
        self.snippet = snippet
    }
}

/// One shader file open in the shader editor: an editable effect's vertex or fragment shader.
struct ShaderDocument: Equatable {
    /// The effect (`effects/<id>/effect.json`).
    var effectFile: String
    /// The material's `shader` (`effects/<id>`).
    var shader: String
    var stage: ShaderDiagnostic.Stage
    /// The file the edits write (`effects/<id>/shaders/effects/<id>.frag`, or the project root's
    /// where the effect's folder has none).
    var path: String
    /// The effect's title, for the header (WE's "Shader - {{name}}").
    var title: String
    /// The text as edited, and as the wallpaper has it.
    var text: String
    var applied: String
    /// The layer and effect it was opened from, whose combos the check uses.
    var layerID: Int?
    var effectKey: String?

    var isDirty: Bool { text != applied }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// The shader editor (WE's "Shader Editor" pane, `codeeditor` with a `vert` or `frag` content
/// type): one file at a time, its Snippets menu, Apply (OK) writing it into the edits, which
/// reloads the canvas with it ("Rebuilding shaders"), then the translator's problems on its lines
/// and View Errors with the source the failing step compiled.
@MainActor
final class ShaderEditorModel: ObservableObject {
    let session: SceneEditSession
    /// A file as the scene loader finds it.
    let read: (String) -> Data?
    let services: ShaderEditorServices?

    @Published private(set) var document: ShaderDocument?
    @Published private(set) var result: ShaderCheckResult?
    @Published private(set) var isChecking = false
    /// A problem of the editor itself (a snippet that can't be inserted), shown in its status.
    @Published var notice: String?
    private var check: Task<Void, Never>?

    init(session: SceneEditSession, read: @escaping (String) -> Data?, services: ShaderEditorServices?) {
        self.session = session
        self.read = read
        self.services = services
    }

    // MARK: Opening

    /// The editor's file for `relative` (`shaders/effects/x.frag`) of the effect in `directory`:
    /// the effect's own copy where it has one, else the project root's, as the loader resolves it.
    func resolvedPath(_ relative: String, in directory: String) -> String {
        let own = "\(directory)/\(relative)"
        if session.overlay.effectFile(own) != nil || read(own) != nil { return own }
        return relative
    }

    /// The text of the editor's file at `path`: the edits' copy, else as the loader reads it.
    func text(at path: String) -> String? {
        session.overlay.effectFile(path) ?? read(path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Opens the `stage` shader of `shader`, a material of `effectFile`.
    func open(effectFile: String, title: String, shader: String, stage: ShaderDiagnostic.Stage,
              layerID: Int?, effectKey: String?) {
        let directory = (effectFile as NSString).deletingLastPathComponent
        let path = resolvedPath("shaders/\(shader).\(stage.rawValue)", in: directory)
        guard let text = text(at: path) else {
            notice = L("“\(path)” can’t be read.")
            return
        }
        check?.cancel()
        result = nil
        notice = nil
        document = ShaderDocument(effectFile: effectFile, shader: shader, stage: stage, path: path, title: title,
                                  text: text, applied: text, layerID: layerID, effectKey: effectKey)
        runCheck()
    }

    func close() {
        check?.cancel()
        document = nil
        result = nil
        notice = nil
        isChecking = false
    }

    // MARK: Editing

    func setText(_ text: String) {
        guard document?.text != text else { return }
        document?.text = text
        notice = nil
    }

    /// Edits the text with `edit` (a snippet).
    func edit(_ edit: (String) throws -> String) {
        guard let text = document?.text else { return }
        do {
            setText(try edit(text))
        } catch ShaderSnippets.SamplerError.tooMany(let number) {
            notice = L("Cannot add more than \(number) samplers.")
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Replace Shader: WE's snippet file; nil when the user's WE copy doesn't have it.
    func snippet(_ replacement: ShaderSnippets.Replacement) -> String? {
        services?.snippet(replacement.file).map(ShaderSnippets.replacement)
    }

    /// Apply (WE's ✓ and OK): writes the text into the edits (one undo step) and translates it.
    func apply() {
        guard let document, document.isDirty else { return }
        session.setEffectFile(document.path, text: document.text, actionName: L("Edit Shader"))
        self.document?.applied = document.text
        runCheck()
    }

    /// Cancel: back to the text the wallpaper has.
    func revert() {
        guard let applied = document?.applied else { return }
        setText(applied)
    }

    // MARK: Checking

    /// The current problems of the open stage, for the editor's gutter.
    var diagnostics: [SceneScriptDiagnostic] {
        guard let document, let result else { return [] }
        return result.diagnostics.filter { $0.stage == document.stage }.map { SceneScriptDiagnostic(line: $0.line, message: $0.message) }
    }

    /// Translates the applied pair in the background, as the canvas's reload will.
    private func runCheck() {
        guard let document, let checker = services?.checker else { return }
        check?.cancel()
        let request = checkRequest(for: document)
        isChecking = true
        check = Task { [weak self] in
            let result = await checker.check(request)
            guard !Task.isCancelled, let self else { return }
            self.result = result
            self.isChecking = false
        }
    }

    func checkRequest(for document: ShaderDocument) -> ShaderCheckRequest {
        var files = session.overlay.effectFiles ?? [:]
        files[document.path] = document.applied
        var combos: [String: Int] = [:]
        if let layerID = document.layerID, let key = document.effectKey,
           let effect = session.overlay.effectEdit(key, of: layerID) {
            for (name, value) in effect.combos ?? [:] { combos[name] = value }
        }
        if let layerID = document.layerID, let key = document.effectKey, let base = session.baseEffect(key, of: layerID) {
            for (name, value) in base.combos where combos[name] == nil { combos[name] = value }
        }
        return ShaderCheckRequest(shader: document.shader, effectDirectory: (document.effectFile as NSString).deletingLastPathComponent,
                                  files: files, combos: combos)
    }
}
