import XCTest
@testable import OWESceneEditing

/// The particle editor's changes through the session: each one undo step, kept in the overlay,
/// read back as the scene now has it.
@MainActor
final class ParticleEditingModelTests: XCTestCase {
    private var model: ParticleEditingModel!
    private var session: SceneEditSession { model.session }

    override func setUp() async throws {
        model = try ParticleFixtures.model()
    }

    private func operatorNames(_ path: String = "particles/rain.json") -> [String?] {
        model.definition(path)?.items(.operator).map { $0["name"]?.stringValue } ?? []
    }

    // MARK: Definitions

    func testComponentsAreAddedRemovedAndReorderedAsUndoableSteps() throws {
        let turbulence = try XCTUnwrap(model.schema.component(.operator, name: "turbulence"))
        XCTAssertEqual(model.addComponent(turbulence, to: "particles/rain.json", actionName: "Add Turbulence"), 2)
        XCTAssertEqual(operatorNames(), ["movement", "alphafade", "turbulence"])
        XCTAssertTrue(model.isEdited("particles/rain.json"))
        XCTAssertEqual(session.undoManager.undoActionName, "Add Turbulence")
        model.moveComponent(.operator, from: 2, to: 0, in: "particles/rain.json", actionName: "Move Up")
        XCTAssertEqual(operatorNames(), ["turbulence", "movement", "alphafade"])
        model.removeComponent(.operator, at: 1, from: "particles/rain.json", actionName: "Remove")
        XCTAssertEqual(operatorNames(), ["turbulence", "alphafade"])

        session.undo()
        XCTAssertEqual(operatorNames(), ["turbulence", "movement", "alphafade"])
        session.undo()
        session.undo()
        XCTAssertEqual(operatorNames(), ["movement", "alphafade"])
        XCTAssertFalse(model.isEdited("particles/rain.json"), "back to the file as authored")
        XCTAssertNil(session.overlay.particles)
        session.redo()
        XCTAssertEqual(operatorNames(), ["movement", "alphafade", "turbulence"])
    }

    func testAFieldEditIsKeptAndAnEditBackToTheFileIsNone() throws {
        let emitter = try XCTUnwrap(model.schema.component(.emitter, name: "sphererandom"))
        let rate = try XCTUnwrap(emitter.field("rate"))
        model.setField(rate, to: .number(80), section: .emitter, index: 0, definition: "particles/rain.json",
                       actionName: "Change Rate")
        XCTAssertEqual(model.definition("particles/rain.json")?.item(.emitter, at: 0)?["rate"], .number(80))
        XCTAssertEqual(model.definition("particles/sparks.json")?.items(.emitter).first?["rate"], .number(5), "others unchanged")
        model.setField(rate, to: .number(50), section: .emitter, index: 0, definition: "particles/rain.json",
                       actionName: "Change Rate")
        XCTAssertFalse(model.isEdited("particles/rain.json"))

        let system = try XCTUnwrap(model.schema.component(.system))
        model.setField(try XCTUnwrap(system.field("flags&0x1")), to: .bool(true), section: .system, index: nil,
                       definition: "particles/rain.json", actionName: "Change Worldspace")
        XCTAssertEqual(model.definition("particles/rain.json")?["flags"], .number(1))
    }

    func testASliderDragOfOneFieldIsOneStep() throws {
        session.coalescingInterval = 10
        let size = try XCTUnwrap(model.schema.component(.initializer, name: "sizerandom")?.field("max"))
        for value in [10.0, 12, 14, 16] {
            model.setField(size, to: .number(value), section: .initializer, index: 1, definition: "particles/rain.json",
                           actionName: "Change Max", coalescing: true)
        }
        XCTAssertEqual(model.definition("particles/rain.json")?.item(.initializer, at: 1)?["max"], .number(16))
        session.undo()
        XCTAssertEqual(model.definition("particles/rain.json")?.item(.initializer, at: 1)?["max"], .number(8))
    }

    func testAChildSystemIsAddedWithItsOwnDefinition() throws {
        let child = try XCTUnwrap(model.addChild(to: "particles/rain.json", actionName: "Add Child"))
        XCTAssertEqual(child, "particles/editor/rain_child.json")
        XCTAssertEqual(model.definition("particles/rain.json")?.childPaths, [child])
        XCTAssertEqual(model.definition(child), .template, "WE's template without its file")
        session.undo()
        XCTAssertNil(model.definition(child))
        XCTAssertEqual(model.definition("particles/rain.json")?.childPaths, [])
    }

    func testAMaterialSharedWithOthersIsCopiedBeforeItChanges() throws {
        model.editMaterial(ofDefinition: "particles/rain.json", actionName: "Change Texture") { $0.texture = "particle/halo" }
        let definition = try XCTUnwrap(model.definition("particles/rain.json"))
        XCTAssertEqual(definition.materialPath, "materials/editor/rain.json")
        XCTAssertEqual(model.material(ofDefinition: "particles/rain.json")?.texture, "particle/halo")
        XCTAssertEqual(model.document("materials/particle/drop.json").flatMap(ParticleMaterial.init(json:))?.texture,
                       "particle/drop", "WE's material stays as it is")
        model.editMaterial(ofDefinition: "particles/rain.json", actionName: "Change Blending") { $0.setString("normal", for: "blending") }
        XCTAssertEqual(model.definition("particles/rain.json")?.materialPath, "materials/editor/rain.json", "copied once")
        XCTAssertEqual(model.material(ofDefinition: "particles/rain.json")?.string("blending"), "normal")
        session.undo()
        session.undo()
        XCTAssertNil(session.overlay.particles, "one step each")
    }

    func testAControlPointMovesAndIsAddedWhenMissing() throws {
        model.setControlPointOffset(SIMD3(10, 20, 0), index: 3, definition: "particles/rain.json", actionName: "Move Control Point")
        let points = try XCTUnwrap(model.definition("particles/rain.json")?.items(.controlpoint))
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[3]["offset"], .string("10 20 0"))
        XCTAssertEqual(points[1]["offset"], .string("100 50 0"))
        XCTAssertEqual(points[2]["id"], .number(2))
    }

    // MARK: Systems

    func testABlankSystemIsAddedCentredAndSelected() throws {
        model.addBlankSystem(name: "Particle System", actionName: "Add Particle System")
        let id = try XCTUnwrap(session.selection)
        XCTAssertEqual(id, 6, "after every id the scene has")
        let layer = try XCTUnwrap(session.outline.layer(id))
        XCTAssertEqual(layer.kind, .particle)
        XCTAssertEqual(session.transform(of: id).origin, SIMD3(960, 540, 0))
        let path = try XCTUnwrap(model.particlePath(of: id))
        XCTAssertEqual(path, "particles/editor/particle_system.json")
        XCTAssertEqual(model.definition(path), .template)
        model.addBlankSystem(name: "Particle System", actionName: "Add Particle System")
        XCTAssertEqual(model.particlePath(of: 7), "particles/editor/particle_system_2.json", "a name of its own")

        session.undo()
        session.undo()
        XCTAssertNil(session.outline.layer(id))
        XCTAssertNil(session.selection, "the selection went with it")
        XCTAssertNil(session.overlay.particles)
    }

    func testATemplateFileOfWEsIsUsed() throws {
        var files = ParticleFixtures.files
        files["particles/example.json"] = Data(#"{"material": "materials/particle/halo.json", "maxcount": 7}"#.utf8)
        model = try ParticleFixtures.model(files: files)
        XCTAssertEqual(model.templateDefinition()["maxcount"], .number(7))
    }

    func testDuplicateCopiesTheLayerWithItsEditsAndDeleteUndoes() throws {
        session.setValue(.string("1 2 0"), for: "origin", of: 5, actionName: "Move")
        let copy = try XCTUnwrap(model.duplicateSystem(5, name: "Rain Copy", actionName: "Duplicate"))
        XCTAssertEqual(session.outline.layer(copy)?.name, "Rain Copy")
        XCTAssertEqual(session.transform(of: copy).origin, SIMD3(1, 2, 0), "the edit is part of the copy")
        XCTAssertEqual(model.particlePath(of: copy), "particles/rain.json", "the same definition, as WE's duplicate")
        XCTAssertEqual(model.instanceOverride(of: copy)["alpha"], .number(0.8))

        model.deleteSystem(5, actionName: "Delete")
        XCTAssertNil(session.outline.layer(5))
        XCTAssertEqual(session.overlay.particles?.removedObjects, [5])
        XCTAssertNil(session.overlay.objects["5"], "its edits go with it")
        model.deleteSystem(copy, actionName: "Delete")
        XCTAssertEqual(session.overlay.particles?.addedObjects, [], "an added system is dropped")
        session.undo()
        session.undo()
        XCTAssertNotNil(session.outline.layer(5))
        XCTAssertEqual(session.transform(of: 5).origin, SIMD3(1, 2, 0))
        XCTAssertNotNil(session.outline.layer(copy))
    }

    func testOnlyParticleLayersAreDuplicatedOrDeleted() {
        XCTAssertNil(model.duplicateSystem(1, name: "x", actionName: "Duplicate"))
        model.deleteSystem(1, actionName: "Delete")
        XCTAssertNil(session.overlay.particles)
    }

    func testThePresetsFilesAreCopiedUnderNamesOfTheirOwn() throws {
        let root = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "rain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "particles/presets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "materials/presets"), withIntermediateDirectories: true)
        try Data(#"""
        {"name": "ui_editor_preset_rain_title", "options": {"droplistOptions": [{"label": "ui_rain_1", "value": 0}]},
         "variants": [{"objects": [{"name": "Rain perspective", "particle": "particles/rain.json", "origin": "0 100 0"}],
                       "dependencies": ["materials/presets/rain.json", "particles/rain.json", {"x": 1}]}]}
        """#.utf8).write(to: folder.appending(path: "preset.json"))
        try Data(#"{"material": "materials/presets/rain.json", "maxcount": 9, "emitter": [], "children": [{"name": "particles/rain.json"}]}"#.utf8)
            .write(to: folder.appending(path: "particles/rain.json"))
        try Data(ParticleFixtures.dropMaterialJSON.utf8).write(to: folder.appending(path: "materials/presets/rain.json"))
        try Data(#"{"name": "x", "variants": [{"objects": [{"text": "12:00"}]}]}"#.utf8).write(to: root.appending(path: "clock.json"))

        let presets = ParticlePresetCatalog.load(presetsDirectory: root, translate: { $0 == "ui_editor_preset_rain_title" ? "Rain" : nil })
        let preset = try XCTUnwrap(presets.first)
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(preset.title, "Rain")
        XCTAssertEqual(preset.variants.first?.title, "ui_rain_1", "an untranslated label as written")
        XCTAssertEqual(preset.variants.first?.dependencies, ["materials/presets/rain.json", "particles/rain.json"])

        let id = try XCTUnwrap(model.addPreset(preset, variant: try XCTUnwrap(preset.variants.first), actionName: "Add Rain"))
        let path = try XCTUnwrap(model.particlePath(of: id))
        XCTAssertEqual(path, "particles/rain_2.json", "the wallpaper has particles/rain.json")
        let definition = try XCTUnwrap(model.definition(path))
        XCTAssertEqual(definition["maxcount"], .number(9))
        XCTAssertEqual(definition.materialPath, "materials/presets/rain.json")
        XCTAssertEqual(definition.childPaths, ["particles/rain_2.json"], "the copies name each other by their new names")
        XCTAssertEqual(session.transform(of: id).origin, SIMD3(960, 640, 0), "its offset from the scene's centre")
        XCTAssertEqual(session.outline.layer(id)?.name, "Rain perspective")
        session.undo()
        XCTAssertNil(session.overlay.particles, "one step")
    }

    func testInstanceOverrideValuesAreSetUnlessAUserPropertySetsThem() {
        model.setInstanceOverride("size", to: .number(2), of: 5, actionName: "Change")
        XCTAssertEqual(model.instanceOverride(of: 5)["size"], .number(2))
        XCTAssertEqual(model.instanceOverride(of: 5)["alpha"], .number(0.8), "the rest kept")
        model.setInstanceOverride("count", to: .number(2), of: 5, actionName: "Change")
        XCTAssertEqual(model.instanceOverride(of: 5)["count"], .object(["user": .string("raincount"), "value": .number(1)]))
    }

    // MARK: Canvas

    func testControlPointsSitOnTheSystemAndDragBack() throws {
        let points = model.controlPoints(of: 5)
        XCTAssertEqual(points.map(\.index), [0, 1])
        XCTAssertEqual(points[1].position, SIMD2(1060, 950), "the system's origin plus the offset")
        XCTAssertEqual(model.controlPoint(of: 5, at: SIMD2(1062, 948), radius: 5)?.index, 1)
        XCTAssertEqual(model.controlPointOffset(points[1], at: SIMD2(1000, 1000), of: 5), SIMD3(40, 100, 0))

        // Sparks is turned a quarter: its control points turn with it.
        XCTAssertEqual(model.origin(of: 2), SIMD2(100, 100))
        XCTAssertEqual(model.system(at: SIMD2(103, 98), radius: 5), 2)
        XCTAssertNil(model.system(at: SIMD2(300, 300), radius: 5))

        model.controlPointPreview = .init(layer: 5, index: 1, offset: SIMD3(0, -100, 0))
        XCTAssertEqual(model.controlPoints(of: 5)[1].position, SIMD2(960, 800), "the drag is drawn before it commits")
    }

    func testAMovedSystemCommitsOnceOnRelease() {
        let drag = model.moveDrag(of: 5, from: SIMD2(960, 900))
        session.dragPreview = (5, drag.transform(at: SIMD2(1000, 880)))
        XCTAssertEqual(model.origin(of: 5), SIMD2(1000, 880))
        session.endDrag(actionName: "Move Particle System")
        XCTAssertEqual(session.overlay.field("origin", of: 5), .string("1000 880 0"))
    }
}
