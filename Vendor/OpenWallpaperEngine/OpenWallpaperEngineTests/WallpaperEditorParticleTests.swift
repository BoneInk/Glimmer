import XCTest
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's particle editor against the runtime: every component WE's editor adds
/// builds in the app's particle system with WE's add values, adding, removing and reordering
/// components reaches the built system, the overlay's systems and documents load, and the JSON the
/// editor writes reads back into the same system.
@MainActor
final class WallpaperEditorParticleTests: XCTestCase {
    private var schema: ParticleEditorSchema!

    override func setUpWithError() throws {
        schema = try ParticleEditorServices.bundledSchema()
    }

    private func build(_ definition: ParticleDefinition) throws -> (WEParticleSystem, SceneMetalParticleSystem) {
        let particles = try JSONDecoder().decode(WEParticleSystem.self, from: definition.encoded())
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "particle": "particles/p.json"}"#.utf8))
        var system = ParticleSystemBuilder.build(
            "particles/p.json", particleSystem: particles, object: object, world: .identity,
            overrides: SceneParticleOverrides(), sceneSize: SIMD2(1920, 1080), source: .image(NSImage()),
            spriteSheet: nil, material: WEMaterial(), materialPlan: nil)
        ParticleSystemBuilder.addRenderers(to: &system, particleSystem: particles) { _ in nil }
        return (particles, system)
    }

    static let operatorKinds: [String: ParticleOperatorKind] = [
        "movement": .movement, "angularmovement": .angularMovement, "alphafade": .alphaFade, "sizechange": .sizeChange,
        "alphachange": .alphaChange, "colorchange": .colorChange, "oscillateposition": .oscillatePosition,
        "oscillatealpha": .oscillateAlpha, "oscillatesize": .oscillateSize, "controlpointattract": .controlPointAttract,
        "maintaindistancetocontrolpoint": .maintainDistanceToControlPoint,
        "maintaindistancebetweencontrolpoints": .maintainDistanceBetweenControlPoints,
        "reducemovementnearcontrolpoint": .reduceMovementNearControlPoint, "turbulence": .turbulence, "vortex": .vortex,
        "vortex_v2": .vortexV2, "boids": .boids, "capvelocity": .capVelocity, "remapvalue": .remapValue,
        "inheritvaluefromevent": .inheritValueFromEvent, "collisionplane": .collision, "collisionsphere": .collision,
        "collisionquad": .collision, "collisionbounds": .collision, "collisionmodel": .collision,
    ]

    static let initializerKinds: [String: ParticleInitializerKind] = [
        "lifetimerandom": .lifetimeRandom, "sizerandom": .sizeRandom, "alpharandom": .alphaRandom,
        "colorrandom": .colorRandom, "hsvcolorrandom": .hsvColorRandom, "colorlist": .colorList,
        "velocityrandom": .velocityRandom, "angularvelocityrandom": .angularVelocityRandom,
        "rotationrandom": .rotationRandom, "inheritcontrolpointvelocity": .inheritControlPointVelocity,
        "turbulentvelocityrandom": .turbulentVelocityRandom, "positionoffsetrandom": .positionOffsetRandom,
        "mapsequencearoundcontrolpoint": .mapSequenceAroundControlPoint,
        "mapsequencebetweencontrolpoints": .mapSequenceBetweenControlPoints,
        "remapinitialvalue": .remapInitialValue, "inheritinitialvaluefromevent": .inheritInitialValueFromEvent,
    ]

    // MARK: Schema against the runtime

    func testEveryComponentWEsEditorAddsBuildsWithItsAddValues() throws {
        let base = try build(.template).1
        for component in schema.components(in: .operator) where component.isAddable {
            let name = try XCTUnwrap(component.name)
            var definition = ParticleDefinition.template
            definition.add(component, pixelUnits: true)
            let operators = try build(definition).1.program.operators
            XCTAssertEqual(operators.count, base.program.operators.count + 1, "\(name) builds an operator")
            XCTAssertEqual(operators.last?.kind, Self.operatorKinds[name], name)
        }
        for component in schema.components(in: .initializer) where component.isAddable {
            let name = try XCTUnwrap(component.name)
            var definition = ParticleDefinition.template
            definition.add(component, pixelUnits: true)
            let initializers = try build(definition).1.program.initializers
            XCTAssertEqual(initializers.count, base.program.initializers.count + 1, "\(name) builds an initializer")
            XCTAssertEqual(initializers.last?.kind, Self.initializerKinds[name], name)
        }
        for component in schema.components(in: .emitter) {
            var definition = ParticleDefinition.template
            definition.add(component, pixelUnits: true)
            XCTAssertEqual(try build(definition).1.extraEmitters.count, 1, "\(component.id) emits")
        }
        for component in schema.components(in: .renderer) {
            var definition = ParticleDefinition.template
            definition.add(component, pixelUnits: true)
            XCTAssertEqual(try build(definition).1.rendererName, component.name, "\(component.id) draws")
        }
        var withChild = ParticleDefinition.template
        withChild.add(try XCTUnwrap(schema.component(.children)), pixelUnits: true)
        withChild.add(try XCTUnwrap(schema.component(.controlpoint)), pixelUnits: true)
        let decoded = try build(withChild).0
        XCTAssertEqual(decoded.children?.first?.type, "static")
        XCTAssertEqual(decoded.controlpoint?.first?.offset, "0 0 0")
    }

    // MARK: Editing reaches the built system

    func testAddRemoveAndReorderReachTheBuiltSystem() throws {
        let scene = Data(#"""
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 3, "name": "Dust", "particle": "particles/p.json", "origin": "960 540 0"}]}
        """#.utf8)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: undoManager)
        let files = ["particles/p.json": try ParticleDefinition.template.encoded()]
        let model = ParticleEditingModel(session: session, schema: schema, readAsset: { files[$0] })
        let path = "particles/p.json"

        func built() throws -> SceneMetalParticleSystem {
            try build(XCTUnwrap(model.definition(path))).1
        }
        XCTAssertEqual(try built().program.operators.map(\.kind), [.movement, .alphaFade])

        model.addComponent(try XCTUnwrap(schema.component(.operator, name: "turbulence")), to: path, actionName: "Add")
        model.addComponent(try XCTUnwrap(schema.component(.operator, name: "colorchange")), to: path, actionName: "Add")
        XCTAssertEqual(try built().program.operators.map(\.kind), [.movement, .alphaFade, .turbulence, .colorChange])
        model.moveComponent(.operator, from: 3, to: 0, in: path, actionName: "Move Up")
        XCTAssertEqual(try built().program.operators.map(\.kind), [.colorChange, .movement, .alphaFade, .turbulence],
                       "WE runs operators in list order")
        model.removeComponent(.operator, at: 1, from: path, actionName: "Remove")
        XCTAssertEqual(try built().program.operators.map(\.kind), [.colorChange, .alphaFade, .turbulence])
        model.removeComponent(.initializer, at: 0, from: path, actionName: "Remove")
        XCTAssertEqual(try built().program.initializers.map(\.kind), [.sizeRandom, .velocityRandom, .colorRandom])

        let rate = try XCTUnwrap(schema.component(.emitter, name: "sphererandom")?.field("rate"))
        model.setField(rate, to: .number(75), section: .emitter, index: 0, definition: path, actionName: "Change Rate")
        XCTAssertEqual(try built().emissionRate, 75)
        let maxCount = try XCTUnwrap(schema.component(.system)?.field("maxcount"))
        model.setField(maxCount, to: .number(42), section: .system, index: nil, definition: path, actionName: "Change")
        XCTAssertEqual(try built().maximumParticleCount, 42)

        // What the running wallpaper is told: only this document changed.
        var before = SceneEditOverlay()
        before.updateParticles { $0.assets[path] = ParticleDefinition.template.json }
        XCTAssertEqual(session.overlay.liveChange(from: before), .particleAssets([path]))
        session.undo()
        XCTAssertEqual(try built().maximumParticleCount, 500, "undone")
    }

    // MARK: The loader

    func testTheOverlaysSystemsAndDocumentsLoad() throws {
        let scene = Data(#"""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "image": "a.json"}, {"id": 2, "name": "Old", "particle": "particles/old.json"}]}
        """#.utf8)
        var overlay = SceneEditOverlay()
        let path = "particles/editor/particle_system.json"
        overlay.updateParticles { particles in
            particles.assets[path] = ParticleDefinition.template.json
            particles.addedObjects = [.object(["id": .number(3), "name": .string("New"), "particle": .string(path),
                                               "origin": .string("960 540 0")])]
            particles.removedObjects = [2]
        }
        overlay.setField("origin", to: .string("100 100 0"), of: 3)
        let resolved = try ScenePreparation.resolvedScene(scene, edits: [:], overlay: overlay)
        let decoded = try JSONDecoder().decode(WEScene.self, from: resolved)
        XCTAssertEqual(decoded.objects.map(\.id), [1, 3])
        XCTAssertEqual(decoded.objects.last?.particle, path)
        XCTAssertEqual(decoded.objects.last?.origin, "100 100 0", "an added system takes field edits too")

        let data = try XCTUnwrap(overlay.particles?.assetData()[path])
        let particles = try JSONDecoder().decode(WEParticleSystem.self, from: data)
        XCTAssertEqual(particles.maxcount, 500)
        XCTAssertEqual(particles.material, "materials/particle/halo.json")

        let request = ScenePreparation.Request(directory: URL(fileURLWithPath: "/nonexistent"), sceneFile: "scene.json",
                                               edits: [:], userProperties: [:], settings: "", displays: [], overlay: overlay)
        var edited = overlay
        edited.updateParticles { $0.assets[path] = .object(["maxcount": .number(1)]) }
        let editedRequest = ScenePreparation.Request(directory: URL(fileURLWithPath: "/nonexistent"), sceneFile: "scene.json",
                                                     edits: [:], userProperties: [:], settings: "", displays: [],
                                                     overlay: edited)
        XCTAssertNotEqual(request.key, editedRequest.key, "a fresh load reads the edited documents")
    }

    // MARK: WE-compatible output

    /// A system WE ships, read and written by the editor, builds the same system.
    func testTheEditorsJSONBuildsTheSameSystem() throws {
        let authored = Data(#"""
        {"animationmode": "randomframe", "flags": 4, "material": "materials/presets/rain.json", "maxcount": 4000,
         "sequencemultiplier": 2.5, "starttime": 3,
         "controlpoint": [{"flags": 1, "id": 0, "offset": "0 0 0"}, {"flags": 2, "id": 1, "offset": "10 -20 0.5"}],
         "emitter": [{"directions": "1 0.25 1", "distancemax": 1024, "distancemin": 0, "id": 6, "name": "sphererandom",
                      "origin": "0 768 0", "rate": 400, "flags": 4, "minperiodicduration": 1.5}],
         "initializer": [{"id": 2, "max": 0.5, "min": 0.5, "name": "lifetimerandom"},
                         {"id": 3, "max": "0 -3000 0", "min": "0 -2000 0", "name": "velocityrandom"},
                         {"id": 9, "colors": ["1 0 0", "0 0.5 1"], "name": "colorlist"},
                         {"id": 10, "input": "position", "output": "color", "inputcomponent": "y",
                          "inputrangemin": "0 0 0", "inputrangemax": "0 1080 0", "name": "remapinitialvalue"}],
         "operator": [{"drag": 0.1, "gravity": "0 -98.1 0", "id": 4, "name": "movement"},
                      {"fadeintime": 0.1, "fadeouttime": 0.9, "id": 5, "name": "alphafade"},
                      {"blendinstart": 0.1, "blendinend": 0.2, "id": 7, "mask": "1 1 0", "name": "turbulence",
                       "scale": 0.01, "speedmax": 300, "speedmin": 100, "timescale": 0.5}],
         "renderer": [{"id": 8, "length": 0.08, "maxlength": 20, "name": "spritetrail"}],
         "children": [{"name": "particles/presets/splash.json", "type": "eventdeath", "probability": 0.3, "maxcount": 20}]}
        """#.utf8)
        let definition = try ParticleDefinition(data: authored)
        let written = try definition.encoded()
        XCTAssertEqual(try ParticleDefinition(data: written), definition, "reads back identically")

        let original = try JSONDecoder().decode(WEParticleSystem.self, from: authored)
        let rewritten = try JSONDecoder().decode(WEParticleSystem.self, from: written)
        func built(_ particles: WEParticleSystem) throws -> SceneMetalParticleSystem {
            let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "particle": "p.json"}"#.utf8))
            return ParticleSystemBuilder.build("p.json", particleSystem: particles, object: object, world: .identity,
                                               overrides: SceneParticleOverrides(), sceneSize: SIMD2(1920, 1080),
                                               source: .image(NSImage()), spriteSheet: nil, material: WEMaterial(),
                                               materialPlan: nil)
        }
        let before = try built(original), after = try built(rewritten)
        XCTAssertEqual(after.program, before.program)
        XCTAssertEqual(after.emitter, before.emitter)
        XCTAssertEqual(after.emitterTiming, before.emitterTiming)
        XCTAssertEqual(after.controlPoints, before.controlPoints)
        XCTAssertEqual(after.maximumParticleCount, before.maximumParticleCount)
        XCTAssertEqual(after.emissionRate, before.emissionRate)
        XCTAssertEqual(after.rendererName, before.rendererName)
        XCTAssertEqual(after.trailLength, before.trailLength)
        XCTAssertEqual(after.startTime, before.startTime)
        XCTAssertEqual(after.perspective, before.perspective)
        XCTAssertEqual(rewritten.children?.first?.type, "eventdeath")
        XCTAssertEqual(rewritten.children?.first?.probability, 0.3)
    }
}
