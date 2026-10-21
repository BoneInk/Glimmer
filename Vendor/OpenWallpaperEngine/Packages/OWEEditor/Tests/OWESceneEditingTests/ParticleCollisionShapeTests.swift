import XCTest
@testable import OWESceneEditing

/// Show Particle Collision's shapes, placed as the renderer places a 2D scene's collision
/// operators (`ParticleCollision.placed`).
final class ParticleCollisionShapeTests: XCTestCase {
    private let scene = SIMD2<Double>(1000, 500)

    func testWEsDefaultsAroundAnEmitter() {
        let world = SceneTransform2D.layer(translation: SIMD2(500, 300), rotation: 0, scale: SIMD2(1, 1))
        let shapes = ParticleCollisionShape.shapes([["name": .string("collisionplane")], ["name": .string("collisionsphere")],
                                                    ["name": .string("collisionquad")], ["name": .string("collisionbounds")],
                                                    ["name": .string("collisionmodel")]], world: world, sceneSize: scene)
        XCTAssertEqual(shapes.count, 4, "a model's capsules aren't the editor's to draw")
        // The plane: "0 1 0" at −150 from the emitter, y = 150; particles stay above it.
        guard case .segment(let from, let to, let normal) = shapes[0] else { return XCTFail("a line") }
        XCTAssertEqual(from.y, 150, accuracy: 1e-9)
        XCTAssertEqual(to.y, 150, accuracy: 1e-9)
        XCTAssertEqual(normal, SIMD2(0, 1))
        XCTAssertEqual(shapes[1], .circle(centre: SIMD2(500, 100), radius: 50), "200 below the emitter, radius 50")
        guard case .segment(let left, let right, _) = shapes[2] else { return XCTFail("an edge") }
        XCTAssertEqual((left + right) / 2, SIMD2(500, 150))
        XCTAssertEqual(abs(right.x - left.x), 200, accuracy: 1e-9)
        XCTAssertEqual(shapes[3], .rectangle(size: scene))
    }

    func testTheEmittersTurnAndScaleCarryTheShapes() {
        let world = SceneTransform2D.layer(translation: SIMD2(100, 100), rotation: .pi / 2, scale: SIMD2(2, 2))
        let shapes = ParticleCollisionShape.shapes([["name": .string("collisionsphere"), "origin": .string("10 0 0"), "radius": .number(5)],
                                                    ["name": .string("collisionplane"), "plane": .string("1 0 0"), "distance": .number(10)]],
                                                   world: world, sceneSize: scene)
        guard case .circle(let centre, let radius) = shapes[0] else { return XCTFail("a circle") }
        XCTAssertEqual(centre.x, 100, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 120, accuracy: 1e-9)
        XCTAssertEqual(radius, 10, accuracy: 1e-9)
        guard case .segment(let from, _, let normal) = shapes[1] else { return XCTFail("a line") }
        XCTAssertEqual(normal.x, 0, accuracy: 1e-9)
        XCTAssertEqual(normal.y, 1, accuracy: 1e-9, "the turned normal")
        // d = 10 × 2 + dot(n, origin) = 120.
        XCTAssertEqual(from.y, 120, accuracy: 1e-9)
    }

    func testAShapeOnAControlPoint() {
        let shapes = ParticleCollisionShape.shapes([["name": .string("collisionsphere"), "flags": .number(1), "controlpoint": .number(2)]],
                                                   world: .identity, sceneSize: scene,
                                                   controlPoint: { $0 == 2 ? SIMD2(7, 8) : nil })
        XCTAssertEqual(shapes, [.circle(centre: SIMD2(7, 8), radius: 50)])
    }
}
