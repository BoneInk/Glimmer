import SwiftUI
import OWESceneEditing

/// The script editor's Snippets menu, as WE's (`openSnippetMenu`): Insert Function, Insert Property,
/// Import Base Module, Import Custom Module and Replace Script.
struct ScriptSnippetsMenu: View {
    @ObservedObject var authoring: EditorAuthoringModel

    var body: some View {
        Menu {
            Menu(L("Insert Function")) {
                ForEach(Array(SceneScriptSourceEdits.Callback.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { callback in
                        Button {
                            authoring.insertFunction(callback)
                        } label: {
                            Text(verbatim: callback.name)
                        }
                        .disabled(SceneScriptSourceEdits.exports(callback.name, in: authoring.draft?.text ?? ""))
                    }
                }
            }
            Menu(L("Insert Property")) {
                ForEach(SceneScriptSourceEdits.PropertyKind.allCases, id: \.self) { kind in
                    Button(kind.title) { authoring.insertProperty(kind) }
                }
            }
            Menu(L("Import Base Module")) {
                ForEach(SceneScriptSourceEdits.baseModules, id: \.self) { module in
                    Button(Self.moduleTitle(module)) { authoring.importModule(module) }
                }
            }
            Menu(L("Import Custom Module")) {
                let modules = authoring.services?.customScriptModules() ?? []
                if modules.isEmpty {
                    Text(L("No other modules in Wallpaper Engine’s scripts"))
                }
                ForEach(modules, id: \.self) { module in
                    Button {
                        authoring.importModule(module)
                    } label: {
                        Text(verbatim: module)
                    }
                }
            }
            Divider()
            Menu(L("Replace Script")) {
                ForEach(SceneScriptSnippet.Field.order, id: \.self) { field in
                    let snippets = SceneScriptSnippet.all.filter { $0.field == field }
                    if !snippets.isEmpty {
                        Section(field.title) {
                            ForEach(snippets) { snippet in
                                Button(snippet.id.title) { authoring.useSnippet(snippet) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(L("Snippets"), systemImage: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Insert a function, a property or a module, or replace the script with a snippet"))
    }

    /// WE's names of its base modules (`ui_editor_script_module_*`).
    static func moduleTitle(_ module: String) -> String {
        switch module {
        case "WEColor": return L("Color Utilities")
        case "WEMath": return L("Math Utilities")
        case "WEVector": return L("Vector Utilities")
        default: return module
        }
    }
}

/// The script editor's Edit menu, as WE's (`openEditMenu`): Format Document, Comment Selection,
/// Uncomment Selection and the SceneScript documentation.
struct ScriptEditMenu: View {
    @ObservedObject var authoring: EditorAuthoringModel
    @Environment(\.openURL) private var openURL

    /// WE's SceneScript documentation (`W.url.docsSceneScript`).
    static let documentation = URL(string: "https://docs.wallpaperengine.io/en/scene/scenescript/introduction.html")!

    var body: some View {
        Menu {
            Button(L("Format Document")) { authoring.codeEditor.formatDocument() }
            Button(L("Comment Selection")) { authoring.codeEditor.commentSelection() }
                .keyboardShortcut("/", modifiers: .command)
            Button(L("Uncomment Selection")) { authoring.codeEditor.uncommentSelection() }
                .keyboardShortcut("/", modifiers: [.command, .option])
            Divider()
            Button(L("SceneScript Documentation")) { openURL(Self.documentation) }
        } label: {
            Label(L("Edit"), systemImage: "wand.and.stars")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Format the script or comment lines"))
    }
}

extension SceneScriptSourceEdits.PropertyKind {
    var title: String {
        switch self {
        case .slider: return L("Slider")
        case .checkbox: return L("Checkbox")
        case .text: return L("Text")
        case .color: return L("Color")
        case .combo: return L("Combo")
        }
    }
}

extension SceneScriptSnippet.Field {
    /// The sections of Replace Script, by the field a snippet is for.
    static let order: [SceneScriptSnippet.Field] = [.color, .number, .origin, .angles, .layer]

    var title: String {
        switch self {
        case .color: return L("For a Color")
        case .number: return L("For a Number")
        case .origin: return L("For a Position")
        case .angles: return L("For a Rotation")
        case .layer: return L("For a Layer")
        }
    }
}

extension SceneScriptSnippet.ID {
    var title: String {
        switch self {
        case .rainbowColor: return L("Rainbow Color")
        case .flicker: return L("Flicker")
        case .dragDrop: return L("Drag & Drop")
        case .clickPlaySound: return L("Click Play Sound")
        case .rotation: return L("Rotation")
        case .rotationPivot: return L("Rotation Pivot")
        case .screenBounce: return L("Screen Bounce")
        case .audioFactor: return L("Audio Factor")
        case .clickWiggle: return L("Click Wiggle")
        case .cursorAvoid: return L("Cursor Avoid")
        case .cursorFollow: return L("Cursor Follow")
        }
    }
}
