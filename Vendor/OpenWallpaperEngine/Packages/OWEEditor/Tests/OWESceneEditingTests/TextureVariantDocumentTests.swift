import CoreGraphics
import XCTest
@testable import OWESceneEditing

/// Texture variants as the editor authors them (`TextureVariantDocument`): the conditions as WE's
/// loader reads them, the `.tex-json`, the options' numbering, and applying them to an image
/// layer (`SceneEditSession.applyTextureVariants`): the compiled `.tex` and `.tex-json` in the
/// edits, a copy of the layer's material naming it, one undo step.
final class TextureVariantDocumentTests: XCTestCase {
    func testConditionsCompileAsWEsLoaderReadsThem() {
        XCTAssertEqual(TextureVariantDocument.Condition.flag("hat").compiledJSON, #"{"condition":"hat"}"#)
        // Capture 540's `variant_a.tex`: `{"condition":{"condition":"1","name":"shapesel"}}`.
        XCTAssertEqual(TextureVariantDocument.Condition.equals("shapesel", "1").compiledJSON,
                       #"{"condition":{"condition":"1","name":"shapesel"}}"#)
        XCTAssertEqual(TextureVariantDocument.Condition.equals("a\"b", "x/y").compiledJSON,
                       #"{"condition":{"condition":"x/y","name":"a\"b"}}"#)
    }

    func testTheTexJSONRoundTripsAndWEsOwnGoesOverItsTexture() throws {
        let document = TextureVariantDocument(source: "editor/bg-1", groups: [
            .init(name: "Clothes", options: [
                .init(name: "Hat", file: "materials/editor/variants/hat.png", blend: .alphaBlend, condition: .flag("hat")),
                .init(name: "Coat", file: "materials/editor/variants/coat.png", condition: .equals("outfit", "2")),
            ]),
            .init(name: "Empty"),
        ])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: document.json) as? [String: Any])
        let options = try XCTUnwrap(((json["variants"] as? [[String: Any]])?.first)?["options"] as? [[String: Any]])
        XCTAssertEqual(Set(options[0].keys), ["blend", "file", "name", "variantcondition"], "WE's option keys")
        XCTAssertEqual(options[1]["variantcondition"] as? [String: String], ["name": "outfit", "condition": "2"])
        let read = try XCTUnwrap(TextureVariantDocument(json: document.json, texture: "ignored"))
        XCTAssertEqual(read.source, "editor/bg-1")
        XCTAssertEqual(read.groups.map(\.name), ["Clothes", "Empty"])
        XCTAssertEqual(read.groups[0].options.map(\.name), ["Hat", "Coat"])
        XCTAssertEqual(read.groups[0].options.map(\.file), document.groups[0].options.map(\.file))
        XCTAssertEqual(read.groups[0].options.map(\.blend), [.alphaBlend, .replace])
        XCTAssertEqual(read.groups[0].options.map(\.condition), [.flag("hat"), .equals("outfit", "2")])

        // WE's own `.tex-json` (`variantcondition`, no `source`).
        let we = Data(#"""
        {"format": "rgba8888", "variants": [{"name": "shapes", "options": [{"file": "materials/a_hat.png", "blend": "alphablend",
          "name": "a_hat", "variantcondition": {"condition": "3", "name": "outfit"}},
          {"blend": "replace", "file": "materials/b.png", "name": "b", "variantcondition": null}]}]}
        """#.utf8)
        let weDocument = try XCTUnwrap(TextureVariantDocument(json: we, texture: "a"))
        XCTAssertEqual(weDocument.source, "a")
        XCTAssertEqual(weDocument.groups.first?.options.map(\.condition), [.equals("outfit", "3"), nil])
        XCTAssertEqual(weDocument.groups.first?.name, "shapes")
        XCTAssertNil(TextureVariantDocument(json: Data(#"{"format": "dxt5"}"#.utf8), texture: "a"))
    }

    func testOptionsAreNumberedByGroupAndPosition() {
        let document = TextureVariantDocument(source: "a", groups: [
            .init(name: "A", options: [.init(name: "1", file: "f1"), .init(name: "2", file: "f2")]),
            .init(name: "B"),
            .init(name: "C", options: [.init(name: "3", file: "f3")]),
        ])
        let compiled = document.compiledOptions
        // From 1, as WE's compiler numbers them (capture 540: group 1, options 1 and 2).
        XCTAssertEqual(compiled.map(\.group), [1, 1, 3])
        XCTAssertEqual(compiled.map(\.id), [1, 2, 3])
        XCTAssertEqual(compiled.map(\.option.name), ["1", "2", "3"])
    }

    // MARK: Applying

    private final class Encoder: EditorTextureEncoding, @unchecked Sendable {
        var compiled: [(base: Data, options: [TextureVariantInput])] = []
        var rejects: UInt32?
        func texture(_ image: CGImage, options: TextureImportOptions) throws -> Data { Data() }
        func normalMap(_ image: CGImage) throws -> Data { Data() }
        func spriteSheet(_ frames: [TextureImportFrame], options: TextureImportOptions) throws -> (data: Data, size: SIMD2<Double>) {
            (Data(), .zero)
        }
        func video(_ url: URL) throws -> (data: Data, size: SIMD2<Double>) { (Data(), .zero) }
        func texture(_ base: Data, withVariants options: [TextureVariantInput]) throws -> Data {
            if let rejects, options.contains(where: { $0.id == rejects }) { throw TextureVariantError.incompatible(optionID: rejects) }
            compiled.append((base, options))
            return base + Data("+\(options.count)".utf8)
        }
        func variantBase(_ data: Data) -> TextureVariantBase? {
            TextureVariantBase(width: 4, height: 4, isVideo: false, allowsAlphaBlend: true,
                               hasCompiledVariants: data.starts(with: Data("compiled".utf8)))
        }
    }

    private let files: [String: Data] = [
        "models/bg.json": Data(#"{"autosize": true, "material": "materials/bg.json"}"#.utf8),
        "materials/bg.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["bg"]}]}"#.utf8),
        "materials/bg.png": Data("base".utf8),
        "materials/editor/variants/hat.png": Data("hat".utf8),
        "materials/editor/variants/coat.png": Data("coat".utf8),
    ]

    @MainActor
    func testApplyingCompilesTheTextureAndUndoesInOneStep() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = Encoder()
        let store = EditorAssetStore(directory: directory, encoder: encoder)
        let undoManager = UndoManager()
        // Each edit its own step, as separate events make them.
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        let readFile: (String) -> Data? = { path in self.files[path] ?? store.url(for: path).flatMap { try? Data(contentsOf: $0) } }

        let initial = try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: readFile))
        XCTAssertEqual(initial.document, TextureVariantDocument(source: "bg"))
        XCTAssertTrue(initial.isImported, "the texture's picture is there")
        XCTAssertEqual(initial.base?.width, 4)

        var document = initial.document
        document.groups = [.init(name: "Clothes", options: [
            .init(name: "Hat", file: "materials/editor/variants/hat.png", blend: .alphaBlend, condition: .flag("hat")),
            .init(name: "Coat", file: "materials/editor/variants/coat.png", condition: nil),
        ])]
        try session.applyTextureVariants(document, to: 10, store: store, readFile: readFile, actionName: "Add Option")

        let call = try XCTUnwrap(encoder.compiled.last)
        XCTAssertEqual(call.base, Data("base".utf8))
        XCTAssertEqual(call.options.map(\.id), [1, 2])
        XCTAssertEqual(call.options.map(\.alphaBlend), [true, false])
        XCTAssertEqual(call.options.map(\.condition), [#"{"condition":"hat"}"#, "{}"], "an option without a condition is never on")
        XCTAssertEqual(call.options.map(\.file), [Data("hat".utf8), Data("coat".utf8)])
        let model = try XCTUnwrap(session.overlay.field("image", of: 10)?.stringValue)
        let applied = try XCTUnwrap(ImageLayerMaterial(modelPath: model, readFile: readFile))
        let texture = try XCTUnwrap(applied.texture)
        XCTAssertTrue(texture.hasPrefix("editor/bg-"))
        XCTAssertEqual(readFile("materials/\(texture).tex"), Data("base+2".utf8))
        // Reading the layer again gives the document back, over the same base.
        let state = try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: readFile))
        XCTAssertEqual(state.document.source, "bg")
        XCTAssertEqual(state.document.groups.first?.options.map(\.name), ["Hat", "Coat"])

        // An incompatible option changes nothing.
        encoder.rejects = 3
        var more = state.document
        more.groups[0].options.append(.init(name: "Video", file: "materials/editor/variants/coat.png"))
        XCTAssertThrowsError(try session.applyTextureVariants(more, to: 10, store: store, readFile: readFile, actionName: "Add Option")) {
            XCTAssertEqual($0 as? TextureVariantError, .incompatible(optionID: 3))
        }
        XCTAssertEqual(session.overlay.field("image", of: 10)?.stringValue, model)

        // No groups left: the base texture again; undo twice gives the wallpaper's own model.
        try session.applyTextureVariants(TextureVariantDocument(source: "bg"), to: 10, store: store, readFile: readFile,
                                         actionName: "Remove Variant")
        let plainModel = try XCTUnwrap(session.overlay.field("image", of: 10)?.stringValue)
        XCTAssertEqual(ImageLayerMaterial(modelPath: plainModel, readFile: readFile)?.texture, "bg")
        session.undo()
        XCTAssertEqual(session.overlay.field("image", of: 10)?.stringValue, model)
        session.undo()
        XCTAssertNil(session.overlay.field("image", of: 10))
    }

    /// WE's editor takes variants only on a texture it imported (capture 540): one with its
    /// picture, or a `.tex` the editor wrote; a `.tex` compiled elsewhere has none.
    @MainActor
    func testOnlyAnImportedTextureTakesVariants() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: UndoManager())
        let store = EditorAssetStore(directory: directory, encoder: Encoder())
        var files = self.files
        files["materials/bg.png"] = nil
        files["materials/bg.tex"] = Data("compiled".utf8)
        let compiled = try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: { files[$0] }))
        XCTAssertFalse(compiled.isImported)
        XCTAssertThrowsError(try session.applyTextureVariants(
            TextureVariantDocument(source: "bg", groups: [.init(name: "A")]), to: 10, store: store,
            readFile: { files[$0] }, actionName: "Add Variant Group"))
        // The same `.tex` in the edits' files is the editor's own import.
        try store.store(Data("imported".utf8), at: "materials/bg.tex")
        let readFile: (String) -> Data? = { path in store.url(for: path).flatMap { try? Data(contentsOf: $0) } ?? files[path] }
        XCTAssertTrue(try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: readFile)).isImported)
    }

    func testCleanProjectKeepsTheFilesAUsedTexJSONNames() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory)
        let document = TextureVariantDocument(source: "bg", groups: [
            .init(name: "A", options: [.init(name: "Hat", file: "materials/editor/variants/hat-1.png")]),
        ])
        try store.store(Data("tex".utf8), at: "materials/editor/bg-2.tex")
        try store.store(document.json, at: "materials/editor/bg-2.tex-json")
        try store.store(Data("png".utf8), at: "materials/editor/variants/hat-1.png")
        try store.store(Data("png".utf8), at: "materials/editor/variants/old-1.png")
        let material = Data(#"{"passes": [{"textures": ["editor/bg-2"]}]}"#.utf8)
        try store.store(material, at: "materials/editor/m.json")
        let unused = ProjectCleaner.unusedAssets(in: store, roots: [Data(#"{"image": "materials/editor/m.json"}"#.utf8)])
        XCTAssertEqual(unused.map(\.path), ["materials/editor/variants/old-1.png"])
    }
}
