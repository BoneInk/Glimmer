import Combine
import Foundation
import OWESceneEditing

/// A field of a layer that a script or a binding attaches to.
struct FieldTarget: Hashable, Identifiable {
    let layer: Int
    let path: SceneFieldPath

    var id: String { "\(layer):\(path)" }
}

/// The script being edited: the draft text against what the scene runs, its syntax problems and
/// when it was last applied (runtime errors from then on are its own).
struct ScriptDraft: Equatable {
    let target: FieldTarget
    /// The source the scene runs now (empty for a new script).
    var applied: String
    var text: String
    var syntax: [SceneScriptDiagnostic] = []
    var appliedAt: Date?

    var isDirty: Bool { text != applied }
}

/// The editor window's authoring state beside the edit session: the script editor's draft, the
/// binding being made, the user-property editor, and the console of the running scripts.
@MainActor
final class EditorAuthoringModel: ObservableObject {
    let session: SceneEditSession
    let properties: UserPropertyAuthoring
    let console: SceneScriptConsoleFeed?
    /// Names bound user properties by their labels (`userPropertyTitle`); nil names them by key.
    let services: WallpaperEditorServices?
    let catalog = SceneScriptAPICatalog.standard

    @Published var draft: ScriptDraft?
    @Published var bindingTarget: FieldTarget?
    @Published var isEditingProperties = false
    /// Whether the canvas runs the scripts (WE's Run Preview / Stop Preview).
    @Published private(set) var scriptsRunning = true
    /// The console empties when a script is applied (WE's Clear log on run).
    @Published var clearsLogOnRun: Bool { didSet { preferences.set(clearsLogOnRun, forKey: Self.clearsLogKey) } }
    /// The console follows its newest line (WE's Auto scroll).
    @Published var autoScrollsLog: Bool { didSet { preferences.set(autoScrollsLog, forKey: Self.autoScrollKey) } }
    /// The editor's text handle, for the panel's menus.
    let codeEditor = CodeEditorController()
    private let preferences: UserDefaults
    static let clearsLogKey = "WallpaperEditorScriptConsoleClearsOnRun"
    static let autoScrollKey = "WallpaperEditorScriptConsoleAutoScroll"
    private var syntaxCheck: DispatchWorkItem?
    private var forward: [AnyCancellable] = []

    init(session: SceneEditSession, projectJSON: Data?, console: SceneScriptConsoleFeed?,
         services: WallpaperEditorServices? = nil) {
        self.session = session
        properties = UserPropertyAuthoring(session: session, projectJSON: projectJSON, readAsset: services?.readAsset ?? { _ in nil })
        self.console = console
        self.services = services
        let preferences = services?.preferences ?? .standard
        self.preferences = preferences
        // Clear Log on Run starts off and Auto Scroll on.
        clearsLogOnRun = preferences.bool(forKey: Self.clearsLogKey)
        autoScrollsLog = preferences.object(forKey: Self.autoScrollKey) == nil ? true : preferences.bool(forKey: Self.autoScrollKey)
        forward.append(session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        if let console {
            forward.append(console.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    /// The label of the user property `key`, as the property panels show it
    /// (`WallpaperEditorServices.userPropertyTitle`), including one added in this edit.
    func userPropertyTitle(_ key: String) -> String {
        services?.userPropertyTitle(key, properties: session.overlay.authoring?.properties) ?? key
    }

    // MARK: Script editor

    /// Opens the script on `target` in the editor, or a new one from `template`.
    func editScript(_ target: FieldTarget, template: SceneScriptTemplate.ID? = nil) {
        let current = session.drivers(target.path, of: target.layer).script?.source ?? ""
        let fieldName = target.path.name
        let starting = template.map { SceneScriptTemplate.template($0).source }
            ?? (current.isEmpty ? Self.defaultTemplate(for: target.path, field: fieldName).source : current)
        draft = ScriptDraft(target: target, applied: current, text: starting)
        checkSyntax(now: true)
    }

    static func defaultTemplate(for path: SceneFieldPath, field: String) -> SceneScriptTemplate {
        path == .objectScript ? .template(.objectScript) : .template(.empty)
    }

    func closeScript() {
        draft = nil
    }

    func setDraftText(_ text: String) {
        guard draft?.text != text else { return }
        draft?.text = text
        checkSyntax(now: false)
    }

    /// Replaces the draft with a template (the editor's own undo can bring the text back).
    func useTemplate(_ id: SceneScriptTemplate.ID) {
        setDraftText(SceneScriptTemplate.template(id).source)
        checkSyntax(now: true)
    }

    // MARK: Snippets

    /// Snippets › Replace Script: WE's own script from the user's WE copy, else the editor's.
    func useSnippet(_ snippet: SceneScriptSnippet) {
        let source = snippet.resolvedSource(weSource: { [services] in services?.scriptSnippet($0) })
        codeEditor.replaceText { _ in source }
        if draft?.text != source { setDraftText(source) }
        checkSyntax(now: true)
    }

    /// Snippets › Insert Function, documented for the field's type.
    func insertFunction(_ callback: SceneScriptSourceEdits.Callback) {
        let type = draft.map { Self.valueType(of: $0.target.path) }
        editDraft { SceneScriptSourceEdits.inserting(callback, into: $0, valueType: type) }
    }

    /// Snippets › Insert Property.
    func insertProperty(_ kind: SceneScriptSourceEdits.PropertyKind) {
        editDraft { SceneScriptSourceEdits.inserting(kind, into: $0) }
    }

    /// Snippets › Import Base Module / Import Custom Module.
    func importModule(_ name: String) {
        editDraft { SceneScriptSourceEdits.importing(name, into: $0) }
    }

    private func editDraft(_ edit: (String) -> String) {
        codeEditor.replaceText(edit)
        // Without a text view (tests), the draft changes directly.
        if codeEditor.textView == nil, let text = draft?.text { setDraftText(edit(text)) }
    }

    /// The JSDoc type of a field's value, as WE documents a bound script's `init` and `update`.
    static func valueType(of path: SceneFieldPath) -> String {
        if path.effectIndex != nil { return path.name == "visible" ? "Boolean" : "Number" }
        switch path.objectField {
        case "origin", "scale", "angles", "color": return "Vec3"
        case "parallaxDepth": return "Vec2"
        case "alpha", "pointsize": return "Number"
        case "text": return "String"
        case "visible": return "Boolean"
        default: return "*"
        }
    }

    // MARK: Run Preview

    /// Stops or runs the canvas's scripts, saying so in the console as WE does.
    func setScriptsRunning(_ running: Bool) {
        guard let set = services?.setScriptsRunning, running != scriptsRunning else { return }
        scriptsRunning = running
        if running, clearsLogOnRun { console?.clear() }
        console?.append(level: .log, message: running ? L("Running script preview.") : L("Stopping script preview."),
                        scriptID: "", line: nil)
        set(running)
    }

    var canStopScripts: Bool { services?.setScriptsRunning != nil }

    /// Applies the draft: the script is attached in the overlay (one undo step), and the scene
    /// runs it from the next reload of the canvas and the desktop. A draft with a syntax error
    /// isn't applied (the runtime would only disable it).
    func applyScript() {
        checkSyntax(now: true)
        guard var draft, draft.syntax.isEmpty else { return }
        let target = draft.target
        let existing = session.drivers(target.path, of: target.layer).script
        let declared = Set(SceneScriptPropertyDeclaration.declarations(in: draft.text).map(\.name))
        // Script-property values the script no longer declares are dropped.
        let kept = existing?.scriptProperties?.filter { declared.contains($0.key) }
        if clearsLogOnRun { console?.clear() }
        session.attachScript(SceneScriptAttachment(source: draft.text, scriptProperties: kept ?? [:]),
                             to: target.path, of: target.layer,
                             actionName: existing == nil ? L("Add Script") : L("Edit Script"))
        draft.applied = draft.text
        draft.appliedAt = Date()
        self.draft = draft
    }

    func removeScript(_ target: FieldTarget) {
        session.removeScript(target.path, of: target.layer, actionName: L("Remove Script"))
        if draft?.target == target { draft = nil }
    }

    /// Sets a value of a property the script declares (stored in `scriptproperties`).
    func setScriptProperty(_ name: String, to value: SceneJSONValue?, on target: FieldTarget) {
        guard var script = session.drivers(target.path, of: target.layer).script else { return }
        var values = script.scriptProperties ?? [:]
        values[name] = value
        script.scriptProperties = values
        session.editOverlay(actionName: L("Change Script Property"), coalescingKey: "script:\(target.id):\(name)") { overlay in
            var authoring = overlay.authoring ?? SceneAuthoring()
            var edit = authoring.driverEdit(target.path, of: target.layer) ?? SceneFieldDriverEdit()
            edit.attach(script)
            authoring.setDriverEdit(edit, target.path, of: target.layer)
            overlay.authoring = authoring
        }
    }

    /// Syntax errors of the draft, checked a moment after typing stops.
    private func checkSyntax(now: Bool) {
        syntaxCheck?.cancel()
        guard let text = draft?.text else { return }
        if now {
            draft?.syntax = SceneScriptSyntaxCheck.diagnostics(of: text)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.draft?.text == text else { return }
                self.draft?.syntax = SceneScriptSyntaxCheck.diagnostics(of: text)
            }
        }
        syntaxCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Problems of the draft: its syntax, else what the running script reported since it was
    /// applied (only while the draft is what runs).
    var diagnostics: [SceneScriptDiagnostic] {
        guard let draft else { return [] }
        if !draft.syntax.isEmpty { return draft.syntax }
        guard !draft.isDirty, let console else { return [] }
        return console.diagnostics(of: draft.target.layer, draft.target.path, since: draft.appliedAt)
    }

    // MARK: Fields

    /// The title of a field in menus and headers ("Clock › Text").
    func title(of target: FieldTarget) -> String {
        let layer = session.outline.layer(target.layer)
        let layerTitle = layer?.title ?? String(target.layer)
        return "\(layerTitle) › \(Self.fieldTitle(target.path, layer: layer))"
    }

    static func fieldTitle(_ path: SceneFieldPath, layer: SceneLayer?) -> String {
        if let index = path.effectIndex {
            let effect = layer?.effects.first { $0.id == index }
            return effect?.title ?? L("Effect")
        }
        switch path.objectField {
        case "visible": return L("Visible")
        case "origin": return L("Position")
        case "scale": return L("Scale")
        case "angles": return L("Rotation")
        case "alpha": return L("Opacity")
        case "color": return L("Color")
        case "text": return L("Text")
        case "pointsize": return L("Point Size")
        case "parallaxDepth": return L("Parallax Depth")
        default: return path.description
        }
    }

    /// The fields a script can be added to on `layer`, in WE's run order.
    func scriptableFields(of layer: SceneLayer) -> [SceneFieldPath] {
        var fields: [SceneFieldPath] = [.objectScript]
        if layer.kind != .sound { fields += ["origin", "scale", "angles"] }
        if layer.kind == .image || layer.kind == .text { fields += ["alpha", "color"] }
        if layer.kind == .text { fields += ["text", "pointsize"] }
        fields += layer.effects.map { SceneFieldPath.effect($0.id) }
        return fields
    }

    /// The kind of user property a field can be bound to; nil for a field WE doesn't bind.
    static func propertyKind(for path: SceneFieldPath) -> UserPropertyDraft.Kind? {
        if path.effectIndex != nil { return path.name == "visible" ? .bool : nil }
        switch path.objectField {
        case "visible": return .bool
        case "alpha", "scale", "pointsize": return .slider
        case "color": return .color
        case "text": return .textInput
        default: return nil
        }
    }
}
