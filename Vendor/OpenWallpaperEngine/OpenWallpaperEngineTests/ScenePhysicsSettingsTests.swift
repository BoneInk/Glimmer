import XCTest
import simd
@testable import OpenWallpaperEngine

private struct PhysicsPropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    func userProperty(_ name: String) -> String? { properties[name] }
}

/// The scene options' gravity and wind (`ScenePhysicsSettings`, `SceneBonePhysicsWind`): `general`'s
/// fields with WE's defaults, the gravity vector and WE's noise-driven wind force.
final class ScenePhysicsSettingsTests: XCTestCase {
    private func general(_ json: String, properties: [String: String] = [:]) throws -> WESceneGeneral {
        try BoundDocument.decode(WESceneGeneral.self, from: Data(json.utf8), properties: properties)
    }

    /// 3803042537's (Nobara Gothic) block, the wind on.
    func testTheFieldsAreDecoded() throws {
        let json = #"""
            {"gravitydirection": "0.00000 -1.00000 0.00000", "gravitystrength": 1.0,
             "winddirection": "0.94795 0.07271 0.31000", "windenabled": true, "windstrength": 1.0}
            """#
        let physics = ScenePhysicsSettings(try general(json), in: PhysicsPropertyContext())
        XCTAssertEqual(physics.gravityDirection, SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(physics.gravityStrength, 1)
        XCTAssertTrue(physics.windEnabled)
        XCTAssertEqual(physics.windDirection, SIMD3<Float>(0.94795, 0.07271, 0.31))
        XCTAssertEqual(physics.windStrength, 1)
    }

    /// Without the fields: WE's constructor values (0x140187006…0x140187104), wind off.
    func testTheDefaultsAreWEs() throws {
        let physics = ScenePhysicsSettings(try general("{}"), in: PhysicsPropertyContext())
        XCTAssertEqual(physics, ScenePhysicsSettings())
        XCTAssertEqual(physics.gravityDirection, SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(physics.gravityStrength, 1)
        XCTAssertFalse(physics.windEnabled)
        XCTAssertEqual(physics.windDirection, SIMD3<Float>(0.707, 0.707, 0))
        XCTAssertEqual(physics.windStrength, 1)
        XCTAssertNil(SceneBonePhysicsWind.force(physics, x: 100, time: 3, projectionWidth: 1920))
    }

    /// A user property can turn the wind on and set its strength.
    func testTheFieldsFollowTheirUserProperties() throws {
        let json = #"""
            {"windenabled": {"user": "wind", "value": false},
             "windstrength": {"user": "windpower", "value": 1.0},
             "gravitystrength": {"user": "weight", "value": 1.0}}
            """#
        let physics = ScenePhysicsSettings(try general(json, properties: ["wind": "true", "windpower": "3", "weight": "0.39"]),
                                           in: PhysicsPropertyContext())
        XCTAssertTrue(physics.windEnabled)
        XCTAssertEqual(physics.windStrength, 3)
        XCTAssertEqual(physics.gravity, SIMD3<Float>(0, -0.39, 0))
    }

    /// The gravity is the direction times the strength, as authored (0x1401988e0): 3546971487's
    /// 0.39 doesn't normalise anything.
    func testTheGravityIsTheDirectionTimesTheStrength() {
        var physics = ScenePhysicsSettings()
        physics.gravityDirection = SIMD3<Float>(0, -2, 0)
        physics.gravityStrength = 0.39
        XCTAssertEqual(physics.gravity, SIMD3<Float>(0, -0.78, 0))
    }

    /// WE's noise, bit for bit: values from the same algorithm in float32 (numpy), in WE's order.
    func testTheNoiseIsWEsSimplexNoise() {
        let cases: [(Float, Float, UInt32)] = [
            (0, 0, 0x0000_0000), (0.3, 0.7, 0xBF29_57EE), (1.25, -2.5, 0xBF0E_AA3D),
            (12.5, 3.75, 0x3CA4_7848), (100.1, -7.3, 0x3E00_89DC), (3.2, 5.0, 0x3F4F_9064),
        ]
        for (x, y, bits) in cases {
            let value: Float = SceneBonePhysicsWind.noise(x, y)
            XCTAssertEqual(value.bitPattern, bits, "noise(\(x), \(y)) = \(value)")
        }
    }

    /// The floor is `cvttss2si` with one off when it rounded up, x86's indefinite out of range.
    func testTheFloorIsWEs() {
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(2.5), 2)
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(-2.5), -3)
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(-3), -3)
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(.nan), Int32.min)
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(.infinity), Int32.min)
        XCTAssertEqual(SceneBonePhysicsWind.fastFloor(-.infinity), Int32.max)
    }

    /// The force: never against the direction (the noise's negative half is cut), scaled by the
    /// strength, the noise read at (time, 10 · x / width).
    func testTheWindBlowsAlongItsDirectionOnly() throws {
        var physics = ScenePhysicsSettings()
        physics.windEnabled = true
        physics.windDirection = SIMD3<Float>(0.94795, 0.07271, 0.31)
        physics.windStrength = 2
        var positive = 0
        for step in 0..<200 {
            let time = Float(step) * 0.05
            let force = try XCTUnwrap(SceneBonePhysicsWind.force(physics, x: 960, time: time, projectionWidth: 3840))
            let n = max(0, SceneBonePhysicsWind.noise(time, 960 / 3840 * 10))
            XCTAssertEqual(force, physics.windDirection * (n * 2))
            XCTAssertGreaterThanOrEqual(simd_dot(force, physics.windDirection), 0)
            if n > 0 { positive += 1 }
        }
        XCTAssertGreaterThan(positive, 0)
        XCTAssertLessThan(positive, 200)
    }

    /// The CPU cost of one force (one 2D simplex noise): measured, not a budget.
    func testTheWindCostsLittle() throws {
        var physics = ScenePhysicsSettings()
        physics.windEnabled = true
        let calls = 1_000_000
        var sum = SIMD3<Float>.zero
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<calls {
            sum += SceneBonePhysicsWind.force(physics, x: Float(index % 3840), time: Float(index) * 1e-4,
                                              projectionWidth: 3840) ?? .zero
        }
        let nanoseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls)
        print("SceneBonePhysicsWind.force: \(nanoseconds) ns a call (sum \(sum))")
        XCTAssertLessThan(nanoseconds, 1000)
    }
}
