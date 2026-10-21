import AppKit
import SwiftUI
import XCTest
import OWEModelImport
@testable import OWEEditor
@testable import OWESceneEditing

/// The Model Editor on the importer's skinned fixture: clips, events, attachments, physics and
/// materials edited, OK compiling the model again and pointing the layer at it; its views draw;
/// its catalog has every key in every language.
@MainActor
final class ModelEditorTests: XCTestCase {
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ModelEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func imported() throws -> (EditorAssetStore, ImportedModel, SceneEditSession, UndoManager) {
        let source = directory.appending(path: "skinned-quad.fbx")
        try FileManager.default.copyItem(at: Self.packageRoot.appending(path: "Tests/OWEModelImportTests/Fixtures/skinned-quad.fbx"), to: source)
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let model = try EditorModelImporter.importModel(from: source, into: store)
        let scene = try JSONSerialization.data(withJSONObject: ["objects": [["id": 1, "name": "quad", "model": model.model]]])
        let undo = UndoManager()
        return (store, model, SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: undo), undo)
    }

    func testEditsCompileIntoANewModelTheLayerDraws() throws {
        let (store, model, session, undo) = try imported()
        let editor = ModelEditorModel(model: model.model, store: store, readFile: { _ in nil })
        XCTAssertNil(editor.problem)
        XCTAssertEqual(editor.animations.map(\.name), ["Wave"])
        XCTAssertEqual(editor.bones, ["RootNode", "Root", "Tip"])
        XCTAssertEqual(editor.sortedBones, ["Root", "RootNode", "Tip"])
        XCTAssertEqual(editor.materialNames, ["Skin"])
        XCTAssertFalse(editor.hasChanges)

        let clip = editor.addClip(from: 1)
        XCTAssertEqual(editor.clips.map(\.id), [clip])
        editor.updateClip(clip) { $0.start = 5; $0.end = 15; $0.rootMotion = "Root"; $0.motionFlags = ModelImportConfig.Clip.positionY }
        XCTAssertEqual(editor.clips.first?.frames, 10)
        let event = editor.addEvent(to: clip)
        editor.updateEvent(event) { $0.name = "step"; $0.frame = 3 }
        let attachment = editor.addAttachment()
        XCTAssertEqual(editor.config.attachments.first?.bone, "Root")
        editor.updateAttachment(attachment) { $0.bone = "Tip" }
        editor.config.constraints["Tip"] = PuppetBonePhysics(preset: .stiff)
        editor.updateMaterial("Skin") { $0.setCombo("RIMLIGHTING", 1) }
        XCTAssertTrue(editor.hasChanges)

        let new = try XCTUnwrap(editor.apply(to: session))
        XCTAssertNotEqual(new, model.model)
        XCTAssertEqual(editor.model, new)
        XCTAssertEqual(session.value("model", of: 1)?.stringValue, new)
        let config = try XCTUnwrap(store.modelConfig(for: new))
        XCTAssertEqual(config.clips.first?.name, editor.config.clips.first?.name)
        XCTAssertEqual(config.events.map(\.name), ["step"])
        XCTAssertNotNil(config.constraints["Tip"])
        let material = try XCTUnwrap(config.materials["Skin"])
        let document = try XCTUnwrap(store.url(for: material).flatMap { try? Data(contentsOf: $0) }.flatMap(MaterialPassDocument.init(json:)))
        XCTAssertEqual(document.combo("RIMLIGHTING", default: 0), 1)
        undo.undo()
        XCTAssertEqual(session.value("model", of: 1)?.stringValue, model.model)

        // The layer plays a clip as an animation layer.
        ModelAnimationLayers.play(1, name: "Wave", layer: 1, in: session)
        XCTAssertTrue(ModelAnimationLayers.plays(1, layer: 1, in: session))
        ModelAnimationLayers.play(nil, name: "", layer: 1, in: session)
        XCTAssertFalse(ModelAnimationLayers.plays(1, layer: 1, in: session))
    }

    func testRemovingAClipRemovesItsEvents() throws {
        let (store, model, _, _) = try imported()
        let editor = ModelEditorModel(model: model.model, store: store, readFile: { _ in nil })
        let clip = editor.addClip(from: 1)
        editor.addEvent(to: clip)
        editor.addEvent(to: 1)
        editor.removeClip(clip)
        XCTAssertEqual(editor.config.events.map(\.animation), [1])
        XCTAssertTrue(editor.clips.isEmpty)
    }

    /// Every tab draws (the model's lists and a selected clip's options).
    func testTheEditorsTabsDraw() throws {
        let (store, model, session, _) = try imported()
        let editor = ModelEditorModel(model: model.model, store: store, readFile: { _ in nil })
        editor.addClip(from: 1)
        let layer = try XCTUnwrap(session.outline.layer(1))
        for tab in [AnyView(ModelEditorView(session: session, layer: layer, editor: editor)),
                    AnyView(ModelAttachmentsTab(editor: editor)), AnyView(ModelEventsTab(editor: editor)),
                    AnyView(ModelConstraintsTab(editor: editor)), AnyView(ModelMaterialsTab(editor: editor))] {
            let host = NSHostingView(rootView: tab.frame(width: 860, height: 600))
            host.frame = NSRect(x: 0, y: 0, width: 860, height: 600)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }

    // MARK: Catalog

    static let languages = ["de", "fr", "es", "pt-BR", "it", "ja", "ko", "zh-Hans", "zh-Hant", "ru", "pl", "tr", "uk", "ar", "hi"]

    func testEveryModelEditorKeyIsInTheCatalogInEveryLanguage() throws {
        let data = try Data(contentsOf: Self.packageRoot.appending(path: "Sources/OWEEditor/Resources/ModelEditor.xcstrings"))
        let strings = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]])
        let regex = try NSRegularExpression(pattern: #"ML\("((?:[^"\\]|\\\([^)]*\))*)"\)"#)
        let folder = Self.packageRoot.appending(path: "Sources/OWEEditor/ModelEditor")
        var used = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var key = String(text[Range(match.range(at: 1), in: text)!])
                key = key.replacingOccurrences(of: #"\\\(id\)"#, with: "%llu", options: .regularExpression)
                key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%lld", options: .regularExpression)
                used.insert(key)
            }
        }
        XCTAssertGreaterThan(used.count, 50)
        XCTAssertEqual(used.filter { strings[$0] == nil }.sorted(), [])
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|llu|@)"#)
        func arguments(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }.sorted()
        }
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let value = (localizations[language]?["stringUnit"] as? [String: Any])?["value"] as? String
                XCTAssertNotNil(value, "\(key) in \(language)")
                if let value, !key.hasPrefix("ui_") { XCTAssertEqual(arguments(value), arguments(key), "\(key) in \(language)") }
            }
        }
        // The catalog's title, or the key's fallback where `swift test` doesn't compile string
        // catalogs into the bundle (Xcode 26.3's SwiftPM, as on CI).
        XCTAssertTrue(["Rim lighting", "Rim Lighting"].contains(ModelMaterialLabels.title("ui_editor_properties_rim_lighting")))
        XCTAssertEqual(ModelMaterialLabels.title("ui_editor_properties_something_new"), "Something New")
    }
}
