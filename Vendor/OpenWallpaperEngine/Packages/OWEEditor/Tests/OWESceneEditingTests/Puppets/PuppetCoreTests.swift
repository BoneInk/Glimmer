import XCTest
import simd
@testable import OWESceneEditing

/// The puppet editor's model: mesh generation, weights, posing, rendering and the physics
/// preview.
final class PuppetCoreTests: XCTestCase {
    // MARK: Mesh generation

    func testMeshFromAlphaCoversTheShapeAndLeavesTheNotchOut() throws {
        let mask = PuppetFixtures.cShape(size: 200)
        let mesh = PuppetMeshGenerator.generate(mask, options: .init(spacing: 16, threshold: 8, padding: 0))
        XCTAssertGreaterThan(mesh.vertices.count, 30)
        XCTAssertGreaterThan(mesh.triangles.count, 30)
        var area: Float = 0
        for t in mesh.triangles {
            let a = mesh.vertices[Int(t.x)].position, b = mesh.vertices[Int(t.y)].position, c = mesh.vertices[Int(t.z)].position
            let signed = PuppetMath.cross(b - a, c - a) / 2
            XCTAssertGreaterThan(signed, 0, "triangles wind counter-clockwise (y up)")
            area += signed
            // Every triangle's centre is on the shape (mesh space → pixels: x + 100, 100 − y).
            let centre = (a + b + c) / 3
            let pixel = SIMD2(centre.x + 100, 100 - centre.y)
            XCTAssertGreaterThan(mask.value(Int(pixel.x), Int(pixel.y)), 0, "a triangle at \(centre) lies off the shape")
        }
        let opaque = Float(mask.alpha.filter { $0 > 0 }.count)
        XCTAssertEqual(area / opaque, 1, accuracy: 0.12, "the mesh covers the shape's area")
        // Nothing spans the notch (x > 0, |y| < 20) or the hole in the middle.
        for t in mesh.triangles {
            let centre = (mesh.vertices[Int(t.x)].position + mesh.vertices[Int(t.y)].position + mesh.vertices[Int(t.z)].position) / 3
            XCTAssertFalse(centre.x > 45 && abs(centre.y) < 14, "a triangle fills the notch at \(centre)")
            XCTAssertGreaterThan(simd_length(centre), 34, "a triangle fills the hole at \(centre)")
        }
        // Texture coordinates put each vertex where the image lies.
        var document = PuppetDocument.new(imageSize: SIMD2(200, 200), material: "m")
        document.replaceMesh(mesh)
        XCTAssertTrue(document.isTextureLayout)
    }

    func testDensityControlsTheVertexCount() {
        let mask = PuppetFixtures.mask(width: 160, height: 120) { _, _ in true }
        let coarse = PuppetMeshGenerator.generate(mask, options: .init(spacing: 40, padding: 0))
        let fine = PuppetMeshGenerator.generate(mask, options: .init(spacing: 12, padding: 0))
        XCTAssertGreaterThan(fine.vertices.count, coarse.vertices.count * 3)
        XCTAssertTrue(PuppetMeshGenerator.generate(PuppetFixtures.mask(width: 20, height: 20) { _, _ in false }).vertices.isEmpty)
    }

    func testManualVertexEdits() {
        var document = PuppetFixtures.twoBoneStrip()
        let count = document.mesh.vertices.count
        let triangles = document.mesh.triangles.count
        let added = document.addVertex(at: SIMD2(0, -55))
        XCTAssertEqual(added, count)
        XCTAssertEqual(document.mesh.triangles.count, triangles + 2, "a vertex inside a triangle splits it in three")
        XCTAssertEqual(document.weights[added].first?.bone, 0, "it takes its neighbours' weights")
        document.moveVertex(added, to: SIMD2(2, -50), textureLayout: true)
        XCTAssertEqual(document.mesh.vertices[added].uv, document.textureCoordinate(of: SIMD2(2, -50)))
        document.deleteVertices([added])
        XCTAssertEqual(document.mesh.vertices.count, count)
        XCTAssertEqual(document.mesh.triangles.count, triangles - 1)
    }

    // MARK: Skeleton

    func testBonesStayParentsFirstAndDeletingHandsOverWeights() {
        var document = PuppetFixtures.twoBoneStrip()
        let tip = document.addBone(named: "tip", parent: 1, head: SIMD2(0, 80), angle: .pi / 2)
        XCTAssertEqual(document.bones[tip].name, "tip")
        XCTAssertEqual(document.uniqueBoneName("tip"), "tip 2")
        // A bone can't go under its own child (a cycle).
        XCTAssertFalse(document.reparent(1, to: tip))
        XCTAssertFalse(document.reparent(0, to: tip))
        // Make "tip" a root, then put "lower" under it: the order is fixed so parents come first.
        XCTAssertTrue(document.reparent(tip, to: nil))
        let worldBefore = document.bindWorlds
        XCTAssertTrue(document.reparent(0, to: tip))
        XCTAssertEqual(document.bones.map(\.name), ["tip", "lower", "upper"])
        for (index, bone) in document.bones.enumerated() {
            if let parent = bone.parent { XCTAssertLessThan(parent, index) }
        }
        let lower = document.bones.firstIndex { $0.name == "lower" }!
        XCTAssertEqual(PuppetMath.origin(of: document.bindWorlds[lower]).y, PuppetMath.origin(of: worldBefore[0]).y, accuracy: 1e-3,
                       "reparenting keeps the bone where it is")
        let upper = document.bones.firstIndex { $0.name == "upper" }!
        document.deleteBone(upper)
        XCTAssertEqual(document.bones.count, 2)
        for entries in document.weights {
            XCTAssertEqual(entries.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-5)
            XCTAssertTrue(entries.allSatisfy { $0.bone < 2 })
        }
    }

    // MARK: Weights

    func testAutoWeightsAreNormalisedAndFollowTheBones() {
        var document = PuppetFixtures.twoBoneStrip()
        document.mesh = PuppetMeshGenerator.generate(PuppetFixtures.mask(width: 40, height: 200) { _, _ in true },
                                                     options: .init(spacing: 10, padding: 0))
        document.imageSize = SIMD2(40, 200)
        for method in PuppetAutoWeights.Method.allCases {
            let weights = PuppetAutoWeights.compute(document, method: method)
            XCTAssertEqual(weights.count, document.mesh.vertices.count)
            for (index, entries) in weights.enumerated() {
                XCTAssertFalse(entries.isEmpty, "\(method): vertex \(index) has no weight")
                XCTAssertLessThanOrEqual(entries.count, 4)
                XCTAssertEqual(entries.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-5, "\(method): vertex \(index)")
                XCTAssertTrue(entries.allSatisfy { $0.weight > 0 && $0.weight <= 1 && $0.bone < 2 })
                let position = document.mesh.vertices[index].position
                if position.y < -40 { XCTAssertEqual(entries.first?.bone, 0, "\(method): \(position) belongs to the lower bone") }
                if position.y > 40 { XCTAssertEqual(entries.first?.bone, 1, "\(method): \(position) belongs to the upper bone") }
            }
        }
    }

    func testWeightBrushKeepsEveryVertexNormalised() {
        var document = PuppetFixtures.twoBoneStrip()
        let brush = PuppetWeightBrush(mode: .add, radius: 60, strength: 0.5)
        brush.apply(to: &document, bone: 1, at: SIMD2(0, -50))
        let painted = document.weights[document.mesh.vertex(near: SIMD2(-10, -40), radius: 1)!]
        XCTAssertGreaterThan(PuppetWeight.weight(of: 1, in: painted), 0.2)
        for mode in PuppetWeightBrush.Mode.allCases {
            PuppetWeightBrush(mode: mode, radius: 80, strength: 0.7).apply(to: &document, bone: 0, at: SIMD2(0, 0))
            for entries in document.weights {
                XCTAssertEqual(entries.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-5, "\(mode)")
            }
        }
        // Subtracting everything from a vertex's only bone hands it to the parent.
        var single = PuppetFixtures.twoBoneStrip()
        PuppetWeightBrush(mode: .subtract, radius: 5, strength: 1).apply(to: &single, bone: 1, at: SIMD2(-10, 100))
        XCTAssertEqual(single.weights[single.mesh.vertex(near: SIMD2(-10, 100), radius: 1)!].first?.bone, 0)
    }

    // MARK: Posing and rendering

    /// The two-bone strip with its upper bone turned −90° bends to the right: the upper half
    /// is drawn along +x, the lower half stays.
    func testPosedRenderOfATwoBonePuppetBending() {
        var document = PuppetFixtures.twoBoneStrip()
        let clip = document.addClip(named: "bend", fps: 30, frames: 10)
        var bent = document.bones[1].local
        bent.euler.z -= .pi / 2
        document.clips[clip].tracks[1].keys = [0: document.bones[1].local, 10: bent]
        let rig = PuppetRig(document)
        let pose = rig.pose(clip: clip, frame: 10)
        let positions = PuppetRig.skin(document, palette: rig.palette(worlds: rig.worlds(pose)))
        // The top corners land at (100, ±10).
        XCTAssertEqual(positions[document.mesh.vertices.count - 1].x, 100, accuracy: 1e-3)
        XCTAssertEqual(positions[document.mesh.vertices.count - 1].y, -10, accuracy: 1e-3)
        let texture = PuppetFixtures.solidImage(width: 20, height: 200)
        let viewport = PuppetRasterViewport(origin: SIMD2(-110, 110), scale: 1, width: 220, height: 220)
        let image = PuppetRasterizer.render(document, positions: positions, texture: texture, viewport: viewport)
        func alpha(_ p: SIMD2<Float>) -> UInt8 {
            let pixel = viewport.pixel(p)
            return image.pixel(Int(pixel.x), Int(pixel.y)).w
        }
        XCTAssertEqual(alpha(SIMD2(0, -50)), 255, "the lower half stays")
        XCTAssertEqual(alpha(SIMD2(75, 0)), 255, "the upper half bends right")
        XCTAssertEqual(alpha(SIMD2(0, 75)), 0, "nothing is left where the upper half was")
        XCTAssertEqual(alpha(SIMD2(-75, 0)), 0)
        // Halfway the joint is turned 45°: the tip is on the diagonal.
        let half = PuppetRig.skin(document, palette: rig.palette(worlds: rig.worlds(rig.pose(clip: clip, frame: 5))))
        let tip = (half[document.mesh.vertices.count - 1] + half[document.mesh.vertices.count - 2]) / 2
        XCTAssertEqual(tip.x, 100 * 0.70710677, accuracy: 0.5)
        XCTAssertEqual(tip.y, 100 * 0.70710677, accuracy: 0.5)
        // In the bind pose the strip draws as the texture lies.
        let still = PuppetRasterizer.render(document, positions: document.mesh.vertices.map(\.position), texture: texture,
                                            viewport: viewport)
        XCTAssertEqual(still.pixel(110, 30).w, 255)
        XCTAssertEqual(still.pixel(150, 110).w, 0)
    }

    func testLayersBlendAndAddLikeThePlayer() {
        var document = PuppetFixtures.twoBoneStrip()
        let clip = document.addClip(named: "turn", fps: 10, frames: 10)
        var turned = document.bones[1].local
        turned.euler.z += .pi / 2
        document.clips[clip].tracks[1].keys = [0: turned, 10: turned]
        let rig = PuppetRig(document)
        func angle(_ layers: [PuppetAnimationLayer]) -> Float {
            var player = PuppetLayerPlayer(rig: rig, layers: layers)
            let pose = player.evaluate(delta: 0.1)
            return PuppetMath.angle(of: pose[1].matrix)
        }
        let id = document.clips[clip].id
        XCTAssertEqual(angle([PuppetAnimationLayer(id: 1, name: "", clipID: id)]), .pi / 2, accuracy: 1e-4)
        XCTAssertEqual(angle([PuppetAnimationLayer(id: 1, name: "", clipID: id, blend: 0.5)]), .pi / 4, accuracy: 1e-4)
        XCTAssertEqual(angle([PuppetAnimationLayer(id: 1, name: "", clipID: id),
                              PuppetAnimationLayer(id: 2, name: "", clipID: id, additive: true, blend: 0.5)]),
                       .pi * 0.75, accuracy: 1e-4)
        XCTAssertEqual(angle([PuppetAnimationLayer(id: 1, name: "", clipID: id, visible: false)]), 0, accuracy: 1e-4)
    }

    func testClipClockModes() {
        var clip = PuppetClip(id: 1, name: "c", fps: 10, frames: 10)
        var loop = PuppetClipClock(clip: clip)
        XCTAssertTrue(loop.advance(by: 1.25))
        XCTAssertEqual(loop.time, 0.25, accuracy: 1e-5)
        clip.mode = .mirror
        var mirror = PuppetClipClock(clip: clip)
        mirror.advance(by: 1.25)
        XCTAssertTrue(mirror.reversed)
        XCTAssertEqual(mirror.time, 0.75, accuracy: 1e-5)
        clip.mode = .single
        var single = PuppetClipClock(clip: clip)
        single.advance(by: 5)
        XCTAssertTrue(single.finished)
        XCTAssertEqual(single.samplePosition.frame0, 9)
    }

    func testKeyReductionKeepsEverySample() {
        let samples = (0...30).map { frame -> PuppetTransform in
            let t = Float(frame)
            return PuppetTransform(translation: SIMD3(frame < 15 ? t : 15, 0, 0), euler: SIMD3(0, 0, frame < 10 ? t * 0.1 : 1),
                                   scale: SIMD3(repeating: 1))
        }
        let keys = PuppetClipBaker.keys(from: samples)
        XCTAssertLessThan(keys.count, samples.count)
        let track = PuppetTrack(keys: keys)
        for (frame, sample) in samples.enumerated() {
            XCTAssertTrue(track.transform(at: Float(frame))!.isClose(to: sample, tolerance: 2e-4), "frame \(frame)")
        }
    }

    // MARK: Physics

    func testPhysicsBoneSagsUnderGravityAndSpringsBack() throws {
        var document = PuppetFixtures.twoBoneStrip()
        var physics = PuppetBonePhysics(preset: .floppy)
        physics.gravity = true
        // Sideways, across the upright bone (straight down would pull along it).
        physics.gravityDirection = SIMD3(1, 0, 0)
        document.bones[1].physics = physics
        var simulation = try XCTUnwrap(PuppetPhysicsSimulation(document))
        XCTAssertNil(simulation.constraints[0])
        XCTAssertNotNil(simulation.constraints[1])
        let locals = document.bones.map(\.local.matrix)
        let parents = document.bones.map(\.parent)
        var models: [simd_float4x4] = []
        for _ in 0..<240 {
            models = simulation.step(locals: locals, parents: parents, delta: 1 / 60, objectWorld: matrix_identity_float4x4)
        }
        // The upper bone points up; gravity pulls its tip over to +x.
        let angle = PuppetMath.angle(of: models[1])
        XCTAssertLessThan(angle, .pi / 2 - 0.05)
        XCTAssertTrue(models.allSatisfy { $0.columns.3.x.isFinite })
        // Without gravity a still bone stays put.
        document.bones[1].physics?.gravity = false
        var still = try XCTUnwrap(PuppetPhysicsSimulation(document))
        for _ in 0..<60 { models = still.step(locals: locals, parents: parents, delta: 1 / 60, objectWorld: matrix_identity_float4x4) }
        XCTAssertEqual(PuppetMath.angle(of: models[1]), .pi / 2, accuracy: 1e-3)
    }

    func testPhysicsPropertiesUseWEsCompiledKeys() throws {
        var document = PuppetFixtures.twoBoneStrip()
        document.bones[0].physics = PuppetBonePhysics()
        let properties = PuppetMDLWriter.boneProperties(document)
        XCTAssertEqual(properties[0]["se"], .bool(true))
        XCTAssertEqual(properties[0]["r"], .bool(true))
        XCTAssertEqual(properties[0]["rs"], .number(200))
        XCTAssertEqual(properties[0]["gd"], .string("0.0 -1.0 0.0"))
        // Tip size 0: the distance to the child (100 px) along the forward direction.
        XCTAssertEqual(properties[0]["tp"], .string("100.00000 0.00000 0.00000"))
        XCTAssertEqual(properties[0]["raz"], .bool(true))
        XCTAssertEqual(properties[0]["rax"], .bool(false))
        XCTAssertTrue(properties[1].isEmpty)
        let constraint = try XCTUnwrap(PuppetPhysicsConstraint(properties: properties[0]))
        XCTAssertEqual(constraint.rotationInertia, 0.7, accuracy: 1e-6)
        XCTAssertEqual(constraint.lockRotation, PuppetAxes(true, true, false))
        XCTAssertEqual(PuppetBonePhysics(properties: properties[0]), {
            var expected = PuppetBonePhysics()
            expected.compiledTip = SIMD3(100, 0, 0)
            return expected
        }())
    }
}
