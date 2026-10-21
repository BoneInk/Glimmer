import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Child particle systems (`children`): decoding, how the loader flattens them, and how static and
/// event children run.
final class ParticleChildrenTests: XCTestCase {
    private func particleSystem(_ name: String) throws -> WEParticleSystem {
        try JSONDecoder().decode(WEParticleSystem.self,
                                 from: Fixtures.data("Scenes/particle-children/particles/\(name).json"))
    }

    // MARK: - Format

    func testChildrenDecodeWithTheirLinkFields() throws {
        let rocket = try particleSystem("rocket")
        let children = try XCTUnwrap(rocket.children)
        XCTAssertEqual(children.map(\.type), [nil, "eventfollow", "eventspawn", "eventdeath"])
        XCTAssertEqual(children.map(\.name), ["particles/glow.json", "particles/trail.json",
                                              "particles/spark.json", "particles/burst.json"])
        XCTAssertEqual(children[0].origin?.vectorValue.1, 100)
        XCTAssertEqual(children[0].scale?.vectorValue.0, 2)
        XCTAssertEqual(children[0].angles?.vectorValue.2, 0.5)
        XCTAssertEqual(children[1].maxcount, 4)
        XCTAssertEqual(children[1].probability, 0.5)
        XCTAssertEqual(children[2].flags, 1)
        XCTAssertEqual(children[2].controlpointstartindex, 2)
        XCTAssertFalse(rocket.isWorldSpace)
    }

    func testEmitterBurstShapeAndSystemFlagsDecode() throws {
        let burst = try particleSystem("burst")
        XCTAssertTrue(burst.isWorldSpace)
        let emitter = try XCTUnwrap(burst.emitter?.first)
        XCTAssertEqual(emitter.instantaneous, 20)
        XCTAssertEqual(emitter.speedmin, 200)
        XCTAssertEqual(emitter.speedmax, 300)
        XCTAssertEqual(emitter.directions?.vectorValue.0, 1)
        XCTAssertEqual(emitter.directions?.vectorValue.2, 0)
        XCTAssertEqual(burst.operator?.first?.flags, 1, "movement: gravity in world space")
        XCTAssertEqual(burst.children?.count, 1, "children nest")
    }

    func testNullAndMissingLinkFieldsDecode() throws {
        let json = #"""
        {"children": [{"angles": "0 0 0", "controlpointstartindex": null, "flags": null, "id": 13,
                       "maxcount": 10, "name": "particles/a.json", "origin": "0 0 0", "probability": 1.0,
                       "scale": "1 1 1", "type": "static"},
                      {"name": "particles/b.json"}]}
        """#
        let system = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        XCTAssertEqual(system.children?.count, 2)
        XCTAssertNil(system.children?[0].controlpointstartindex)
        XCTAssertNil(system.children?[1].type)
    }

    // MARK: - Loading

    private func content() throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/particle-children")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/particle-children/project.json"))
        addTeardownBlock {
            Fixtures.removeStoredSettings(for: directory)
        }
        return try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
    }

    func testTheLoaderFlattensAFamilyDepthFirst() throws {
        _ = try Fixtures.assets()
        let systems = try content().particleSystems
        XCTAssertEqual(systems.count, 6, "rocket, glow, trail, spark, burst and burst's glow")
        XCTAssertEqual(systems.map { $0.link?.parentIndex }, [nil, 0, 0, 0, 0, 4])
        XCTAssertEqual(systems.map { $0.link?.kind }, [nil, .static, .follow, .spawn, .death, .static])
        XCTAssertEqual(systems.map(\.isInstanced), [false, false, true, true, true, true],
                       "a static child of an instanced system is instanced too")
        XCTAssertEqual(systems.map { $0.link?.maximumInstances }, [nil, 1, 4, 10, 3, 3])
        XCTAssertEqual(systems.map(\.objectID), ["5", nil, nil, nil, nil, nil])
        XCTAssertEqual(Set(systems.map(\.order)), [0])
        XCTAssertEqual(systems.map(\.hasEventChildren), [true, false, false, false, false, false])
        XCTAssertEqual(systems[2].link?.probability, 0.5)
        let spawnVerbs = systems[2].program.initializers.filter { $0.kind == .inheritInitialValueFromEvent }
            .map { ParticleInheritance(rawValue: $0.record.header.y) }
        XCTAssertEqual(spawnVerbs, [.multiplySize, .setColor], "setcolor when no input is named")
        let stepVerbs = systems[2].program.operators.filter { $0.kind == .inheritValueFromEvent }
            .map { ParticleInheritance(rawValue: $0.record.header.y) }
        XCTAssertEqual(stepVerbs, [[.setColor, .setOpacity]], "setcoloropacity when no input is named")
        XCTAssertEqual(systems[3].instantaneous, 3)
        XCTAssertTrue(systems[4].worldSpace)
        // The static glow sits 100 units above the rocket's emitter, turned and doubled.
        let glow = systems[1].authoredWorld
        XCTAssertLessThan(simd_distance(glow.translation, SIMD2(500, 400)), 1e-3)
        XCTAssertEqual(glow.axisScale.x, 2, accuracy: 1e-5)
    }

    func testACycleOfChildrenIsReportedNotFollowed() throws {
        let cyclic = try JSONDecoder().decode(WEParticleSystem.self, from: Data(#"{"children": [{"name": "a.json"}]}"#.utf8))
        var reports: [String] = []
        let builder = ParticleFamilyBuilder(
            load: { _ in cyclic },
            build: { _, _, world, _ in
                var system = ParticleTestSystem().configuration
                system.emitterLinear = world.linear
                return system
            },
            report: { reports.append($0) })
        let family = builder.family("a.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(reports.count, 1)
    }

    func testUnsupportedLinkFeaturesAreReported() throws {
        let json = "{\"children\": [{\"name\": \"b.json\", \"flags\": 1}, {\"name\": \"c.json\", \"type\": \"eventburst\"}]}"
        let parent = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        var reports: [String] = []
        let builder = ParticleFamilyBuilder(
            load: { $0 == "a.json" ? parent : WEParticleSystem() },
            build: { _, _, _, _ in ParticleTestSystem().configuration },
            report: { reports.append($0) })
        let family = builder.family("a.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 2)
        XCTAssertEqual(reports.count, 1, "an unknown type")
        XCTAssertEqual(family[1].link?.controlPointStart, 0, "control points from the parent's particles, from 0 by default")
    }

    // MARK: - Simulation

    func testAStaticChildEmitsFromItsParentsEmitterAndFollowsIt() throws {
        let family = try Family(root: rocketTestSystem(), children: [(staticGlow(), 0)])
        try family.step(frames: 30, root: translation(SIMD2(500, 300)))
        let glow = family.particles(1)
        XCTAssertGreaterThan(glow.count, 5)
        for particle in glow { XCTAssertLessThan(simd_distance(particle.position, SIMD2<Float>(500, 400)), 1) }
        try family.step(frames: 1, root: translation(SIMD2(700, 300)))
        for particle in family.particles(1) {
            XCTAssertLessThan(simd_distance(particle.position, SIMD2<Float>(700, 400)), 1)
        }
    }

    func testFollowInstancesTrackTheirParticleAndClearWithIt() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 60
        trail.maximum = 50
        trail.spawnExtent = .zero
        trail.minimumVelocity = .zero
        trail.maximumVelocity = .zero
        trail.lifetime = 10...10
        let family = try Family(root: rocketTestSystem(), children: [(trail.link(.follow, instances: 4, probability: 1), 0)])
        try family.step(frames: 20, root: translation(SIMD2(500, 300)))
        let parent = family.particles(0)
        let instances = family.instances(1)
        let active = instances.filter { $0.flags.contains(.active) }
        XCTAssertEqual(active.count, min(parent.count, 4))
        for instance in active {
            let source = try XCTUnwrap(parent.first { $0.serial == instance.state.y })
            XCTAssertLessThan(simd_distance(SIMD2<Float>(instance.place.x, instance.place.y), source.position), 1e-3)
        }
        // Local-space trail particles move with their source.
        for particle in family.particles(1) {
            let instance = instances[particle.instance]
            XCTAssertLessThan(simd_distance(particle.position, SIMD2<Float>(instance.place.x, instance.place.y)), 1e-3)
        }
        // Parent particles live 1 s: their followers and their particles go with them.
        try family.step(frames: 70, root: translation(SIMD2(500, 300)))
        let serials = Set(family.particles(0).map(\.serial))
        let later = family.instances(1)
        for instance in later where instance.flags.contains(.active) {
            XCTAssertTrue(serials.contains(instance.state.y) || instance.flags.contains(.clearing))
        }
        for particle in family.particles(1) {
            XCTAssertTrue(serials.contains(later[particle.instance].state.y))
        }
    }

    func testSpawnAndDeathEventsBurstWhereTheParticleIs() throws {
        var spark = ParticleTestSystem()
        spark.emissionRate = 0
        spark.instantaneous = 3
        spark.maximum = 3
        spark.spawnExtent = .zero
        spark.minimumVelocity = .zero
        spark.maximumVelocity = .zero
        spark.lifetime = 5...5
        var burst = spark
        burst.instantaneous = 7
        burst.maximum = 7
        burst.worldSpace = true
        let family = try Family(root: rocketTestSystem(), children: [(spark.link(.spawn, instances: 100, probability: 1), 0),
                                                                    (burst.link(.death, instances: 100, probability: 1), 0)])
        try family.step(frames: 90, root: translation(SIMD2(500, 300)))
        let spawned = family.spawned(0), died = spawned - UInt32(family.particles(0).count)
        XCTAssertEqual(family.particles(1).count, 3 * Int(spawned), "three sparks per rocket spawned")
        let bursts = family.particles(2)
        XCTAssertEqual(bursts.count, 7 * Int(died), "seven per rocket died")
        XCTAssertGreaterThan(died, 0)
        // Death bursts stay where their rocket died; the rockets rise at 400 units a second.
        for particle in bursts { XCTAssertGreaterThan(particle.position.y, 600) }
    }

    func testChildrenInheritFromTheirEventParticle() throws {
        var root = rocketTestSystem()
        root.minimumColor = SIMD4(0.1, 0.2, 0.3, 1)
        root.maximumColor = SIMD4(0.9, 0.8, 0.7, 1)
        var child = ParticleTestSystem()
        child.emissionRate = 30
        child.maximum = 20
        child.lifetime = 3...3
        child.inheritOnSpawn = [.setColor, .setVelocity, .multiplySize]
        child.inheritEachStep = [.setOpacity]
        let family = try Family(root: root, children: [(child.link(.follow, instances: 20, probability: 1), 0)])
        try family.step(frames: 40, root: translation(SIMD2(500, 300)))
        let parent = family.particles(0), children = family.particles(1), instances = family.instances(1)
        XCTAssertGreaterThan(children.count, 10)
        for particle in children {
            let instance = instances[particle.instance]
            guard let source = parent.first(where: { $0.serial == instance.state.y }) else { continue }
            let color = SIMD3<Float>(particle.color.x, particle.color.y, particle.color.z)
            let sourceColor = SIMD3<Float>(source.color.x, source.color.y, source.color.z)
            XCTAssertLessThan(simd_distance(color, sourceColor), 1e-5, "colour at spawn")
            XCTAssertEqual(particle.alpha, source.alpha, accuracy: 1e-6, "opacity every step")
        }
    }

    func testProbabilityAndTheInstanceBudgetLimitEvents() throws {
        var child = ParticleTestSystem()
        child.emissionRate = 0
        child.instantaneous = 1
        child.maximum = 1
        child.lifetime = 100...100
        var root = rocketTestSystem()
        root.emissionRate = 60
        root.maximum = 1000
        let half = try Family(root: root, children: [(child.link(.spawn, instances: 1000, probability: 0.5), 0)])
        try half.step(frames: 120, root: translation(SIMD2(500, 300)))
        let ratio = Float(half.particles(1).count) / Float(half.spawned(0))
        XCTAssertEqual(ratio, 0.5, accuracy: 0.12)
        let capped = try Family(root: root, children: [(child.link(.spawn, instances: 5, probability: 1), 0)])
        try capped.step(frames: 120, root: translation(SIMD2(500, 300)))
        XCTAssertEqual(capped.instances(1).filter { $0.flags.contains(.active) }.count, 5)
        XCTAssertEqual(capped.particles(1).count, 5)
    }

    /// Every kind of child (static, follow, spawn, death and an instanced static child of the death
    /// child) runs under a moving, turning parent emitter.
    func testEveryKindOfChildRunsUnderAMovingParent() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 40
        trail.maximum = 30
        trail.lifetime = 0.5...0.8
        trail.gravity = SIMD2(0, -100)
        var spark = trail
        spark.instantaneous = 5
        spark.emissionRate = 0
        spark.emitterSpeed = SIMD2(50, 120)
        spark.maximum = 10
        var burst = spark
        burst.instantaneous = 12
        burst.maximum = 12
        burst.worldSpace = true
        trail.inheritOnSpawn = [.multiplyColor, .addVelocity, .setSize, .addRotation, .setAngularVelocity]
        trail.inheritEachStep = [.multiplyOpacity, .multiplySize, .setRotation]
        spark.inheritOnSpawn = [.setColor, .setOpacity]
        var glow = trail
        glow.emissionRate = 20
        glow.maximum = 10
        let links: [(ParticleTestSystem.Linked, Int)] = [
            (staticGlow(), 0),
            (trail.link(.follow, instances: 6, probability: 0.7), 0),
            (spark.link(.spawn, instances: 20, probability: 1), 0),
            (burst.link(.death, instances: 4, probability: 1), 0),
            (glow.link(.static, instances: 4, probability: 1, instanced: true), 4),
        ]
        let moving: (Int) -> SceneAffineTransform = { frame in
            SceneAffineTransform(SceneLocalTransform(origin: SIMD2(400 + Float(frame) * 2, 300), scale: SIMD2(1, 1),
                                                     angle: Float(frame) * 0.01))
        }
        let family = try Family(root: rocketTestSystem(), children: links)
        try family.step(frames: 150, root: moving)
        for index in 1..<family.runtimes.count {
            let particles = family.particles(index)
            XCTAssertGreaterThan(particles.count, 0, "system \(index)")
            let instances = family.instances(index)
            for particle in particles where !instances.isEmpty {
                XCTAssertLessThan(particle.instance, instances.count, "system \(index)")
            }
        }
    }

    /// A family over the particle budget is thinned: every system, the event children's instances
    /// included, holds the scaled maximum and emits at the scaled rate.
    func testABudgetThinsAFamily() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 120
        trail.maximum = 60
        trail.lifetime = 0.5...0.8
        let links: [(ParticleTestSystem.Linked, Int)] = [(staticGlow(), 0), (trail.link(.follow, instances: 6, probability: 1), 0)]
        var root = rocketTestSystem()
        root.maximum = 200
        let authored = try Family(root: root, children: links).runtimes.reduce(0) { $0 + ParticleBudget.capacity(of: $1.configuration) }
        let budget = authored / 4
        let family = try Family(root: root, children: links, budget: budget)
        XCTAssertEqual(family.runtimes.map(\.configuration.budgetScale), Array(repeating: Float(budget) / Float(authored), count: 3))
        let moving: (Int) -> SceneAffineTransform = { frame in
            SceneAffineTransform(SceneLocalTransform(origin: SIMD2(400 + Float(frame) * 2, 300), scale: SIMD2(1, 1), angle: 0))
        }
        try family.step(frames: 150, root: moving)
        var total = 0
        for index in family.runtimes.indices {
            let count = family.particles(index).count
            XCTAssertGreaterThan(count, 0, "system \(index) still draws")
            total += count
        }
        // Each system's maximum is rounded, instance by instance.
        XCTAssertLessThanOrEqual(total, budget + family.runtimes.count + 6)
    }

    /// Each instance keeps its own emitter clock: a periodic follow child, and under it a delayed,
    /// time-limited static child that emits 8 a period (WE's thunderbolt beam).
    func testTimedChildInstancesKeepTheirOwnClocks() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 60
        trail.maximum = 30
        trail.lifetime = 0.3...0.6
        trail.instantaneous = 2
        trail.emitterTiming.periodic = true
        trail.emitterTiming.periodDuration = 0.1...0.3
        trail.emitterTiming.periodDelay = 0.05...0.2
        trail.emitterTiming.maximumPerPeriod = 6
        var beam = ParticleTestSystem()
        beam.emissionRate = 100
        beam.maximum = 16
        beam.lifetime = 0.6...0.6
        beam.emitterTiming.delay = 0.2
        beam.emitterTiming.duration = 1
        beam.emitterTiming.periodic = true
        beam.emitterTiming.periodDuration = 1...1
        beam.emitterTiming.periodDelay = 9999...9999
        beam.emitterTiming.maximumPerPeriod = 8
        let links: [(ParticleTestSystem.Linked, Int)] = [
            (trail.link(.follow, instances: 6, probability: 1), 0),
            (beam.link(.static, instances: 6, probability: 1, instanced: true), 1),
        ]
        let family = try Family(root: rocketTestSystem(), children: links)
        try family.step(frames: 90, root: translation(SIMD2(500, 300)))
        let beams = family.particles(2)
        XCTAssertGreaterThan(beams.count, 0)
        for slot in 0..<6 {
            XCTAssertLessThanOrEqual(beams.filter { $0.instance == slot }.count, 8, "8 a period, one period")
        }
    }

    /// Each instance runs every emitter of the child, each on its own clock (WE's dripping-water
    /// droplets have two).
    func testChildInstancesRunEveryEmitter() throws {
        var drops = ParticleTestSystem()
        drops.emissionRate = 40
        drops.maximum = 40
        drops.lifetime = 0.3...0.6
        var second = ParticleEmitter(rate: 70)
        second.instantaneous = 3
        second.shape.distanceMaximum = SIMD3(repeating: 10)
        second.timing.periodic = true
        second.timing.periodDuration = 0.1...0.2
        second.timing.periodDelay = 0.05...0.1
        second.timing.maximumPerPeriod = 5
        drops.extraEmitters = [second]
        var sequence = ParticleInitializer(.mapSequenceAroundControlPoint, flags: 2, a: SIMD4(0.125, 0, 1, 0))
        sequence.sequenceCount = 8
        drops.initializers = [sequence]
        let links: [(ParticleTestSystem.Linked, Int)] = [(drops.link(.follow, instances: 6, probability: 1), 0)]
        let family = try Family(root: rocketTestSystem(), children: links)
        try family.step(frames: 90, root: translation(SIMD2(500, 300)))
        let particles = family.particles(1)
        XCTAssertGreaterThan(particles.count, 20)
        for particle in particles { XCTAssertLessThan(particle.instance, 6) }
    }

    /// WE's thunderbolt: each spawner instance flies one particle off the bolt, and a static child of
    /// it draws a beam from the instance to that particle through its control point 1 (link flag 1,
    /// start index 1).
    func testLinkedControlPointsFollowTheParentsParticles() throws {
        let family = try Family(root: rocketTestSystem(), children: thunderboltLinks())
        var checked = 0
        for _ in 0..<40 {
            try family.step(frames: 1, root: translation(SIMD2(500, 300)))
            // Beam particles spawned this step lie between their instance and its spawner's particle.
            let beams = family.particles(2), instances = family.instances(2), spawners = family.particles(1)
            for particle in beams where particle.age <= 1 / 60 + 1e-4 {
                let start = SIMD2<Float>(instances[particle.instance].place.x, instances[particle.instance].place.y)
                let ends: [SIMD2<Float>] = spawners.filter { $0.instance == particle.instance }.map(\.position)
                let end = try XCTUnwrap(ends.first, "the spawner instance has its particle")
                let t: Float = simd_dot(particle.position - start, end - start) / max(simd_length_squared(end - start), 1e-6)
                let closest: SIMD2<Float> = start + (end - start) * min(max(t, 0), 1)
                XCTAssertLessThan(simd_distance(particle.position, closest), 0.05)
                checked += 1
            }
        }
        XCTAssertGreaterThan(family.particles(2).count, 0)
        XCTAssertGreaterThan(checked, 0)
    }

    /// An instanced rope draws one strand per instance: no segment joins two instances' particles.
    func testAnInstancedRopeDrawsOneStrandPerInstance() throws {
        let family = try Family(root: rocketTestSystem(), children: thunderboltLinks())
        try family.step(frames: 40, root: translation(SIMD2(500, 300)), kinds: [2: .rope])
        let beams = family.particles(2)
        let records = family.simulator.records(family.runtimes[2], as: ParticleRopeSegmentInstance.self,
                                               queue: family.queue).records
        XCTAssertGreaterThan(records.count, 0)
        var drawn = 0
        for (index, record) in records.enumerated() where index < beams.count {
            // The end of a strand joins nothing.
            guard record.start.w != 0 else { continue }
            drawn += 1
            let end = SIMD2<Float>(record.end.x, record.end.y)
            XCTAssertLessThan(simd_distance(SIMD2<Float>(record.start.x, record.start.y), beams[index].position), 1e-4)
            let next = try XCTUnwrap(beams.firstIndex { simd_distance($0.position, end) < 1e-4 })
            XCTAssertEqual(beams[index].instance, beams[next].instance)
            XCTAssertEqual(Int(record.end.w), beams.filter { $0.instance == beams[index].instance }.count)
        }
        XCTAssertGreaterThan(drawn, 0)
        XCTAssertLessThan(drawn, records.count, "more than one strand")
    }

    /// WE's thunderbolt children: a follow spawner flying one particle off each rocket, and under it
    /// a beam, a rope from the spawner instance to that particle through control point 1.
    private func thunderboltLinks() -> [(ParticleTestSystem.Linked, Int)] {
        var spawner = ParticleTestSystem()
        spawner.emissionRate = 0
        spawner.instantaneous = 1
        spawner.maximum = 1
        spawner.spawnExtent = .zero
        spawner.minimumVelocity = SIMD2(200, 50)
        spawner.maximumVelocity = SIMD2(200, 50)
        spawner.lifetime = 2...2
        var beam = ParticleTestSystem()
        beam.emissionRate = 120
        beam.maximum = 8
        beam.spawnExtent = .zero
        beam.minimumVelocity = .zero
        beam.maximumVelocity = .zero
        beam.lifetime = 0.5...0.5
        beam.rendererName = "rope"
        var sequence = ParticleInitializer(.mapSequenceBetweenControlPoints, controlPoints: 0 | 1 << 8, a: SIMD4(0, 0, 1, 0))
        sequence.sequenceCount = 8
        beam.initializers = [sequence]
        var beamLink = beam.link(.static, instances: 4, probability: 1, instanced: true)
        beamLink.controlPointStart = 1
        return [(spawner.link(.follow, instances: 4, probability: 1), 0), (beamLink, 1)]
    }

    func testTheFixtureFamilyRuns() throws {
        _ = try Fixtures.assets()
        let systems = try content().particleSystems
        let family = try Family(systems)
        try family.step(frames: 120, root: { _ in systems[0].authoredWorld })
        XCTAssertGreaterThan(family.particles(4).count, 0, "rockets burst")
        XCTAssertGreaterThan(family.particles(5).count, 0, "bursts glow")
    }

    // MARK: - Helpers

    private func translation(_ point: SIMD2<Float>) -> (Int) -> SceneAffineTransform {
        { _ in SceneAffineTransform(linear: matrix_identity_float2x2, translation: point) }
    }

    /// Rockets: six a second, straight up at 400 units a second for a second.
    private func rocketTestSystem() -> ParticleTestSystem {
        var rocket = ParticleTestSystem()
        rocket.emissionRate = 6
        rocket.maximum = 20
        rocket.spawnExtent = .zero
        rocket.minimumVelocity = SIMD2(0, 400)
        rocket.maximumVelocity = SIMD2(0, 400)
        rocket.lifetime = 1...1
        return rocket
    }

    private func staticGlow() -> ParticleTestSystem.Linked {
        var glow = ParticleTestSystem()
        glow.emissionRate = 30
        glow.maximum = 40
        glow.spawnExtent = .zero
        glow.minimumVelocity = .zero
        glow.maximumVelocity = .zero
        glow.lifetime = 2...2
        return glow.link(.static, instances: 1, probability: 1, origin: SIMD2(0, 100))
    }
}

/// A particle system and its children stepped together, parents first, as the renderer does.
private final class Family {
    let runtimes: [ParticleSystemRuntime]
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulator: ParticleGPUSimulator

    /// `budget`: the particle budget the family is thinned to (`ParticleBudget`).
    convenience init(root: ParticleTestSystem, children: [(ParticleTestSystem.Linked, Int)], budget: Int? = nil) throws {
        var systems = [root.configuration]
        for (child, parent) in children {
            var configuration = child.system.configuration
            configuration.link = child.link(parentIndex: parent, parent: systems[parent].link)
            systems[parent].hasEventChildren = systems[parent].hasEventChildren || child.kind != .static
            systems.append(configuration)
        }
        ParticleBudget.apply(budget, to: &systems)
        try self.init(systems)
    }

    init(_ systems: [SceneMetalParticleSystem]) throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        runtimes = systems.enumerated().map { index, system in
            ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(UInt32(index)))
        }
        ParticleSystemRuntime.linkFamilies(runtimes)
    }

    private var frame = 0

    private func inputs(_ runtime: ParticleSystemRuntime, root: (Int) -> SceneAffineTransform) -> ParticleFrameInputs {
        ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: SIMD2(100, 100),
                                    emitter: runtime.configuration.link == nil ? root(frame) : nil)
    }

    /// Steps the family `frames` times, one command buffer a frame, and waits for the last.
    /// `kinds`: what the step writes records for, by system (the built-in sprite otherwise).
    func step(frames: Int, root: (Int) -> SceneAffineTransform, kinds: [Int: ParticleGPUDrawKind] = [:]) throws {
        var last: MTLCommandBuffer?
        for _ in 0..<frames {
            let requests = runtimes.enumerated().map { index, runtime in
                ParticleGPUSimulator.Request(system: runtime, inputs: inputs(runtime, root: root),
                                             kind: kinds[index] ?? .fallbackSprite, materialVertexCount: 6)
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode(requests, sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
            frame += 1
        }
        last?.waitUntilCompleted()
        XCTAssertNil(last?.error)
    }

    /// System `index`'s live particles after the last step.
    func particles(_ index: Int) -> [ParticleGPUState] {
        simulator.snapshot(runtimes[index], queue: queue)
    }

    /// Instanced system `index`'s instances after the last step.
    func instances(_ index: Int) -> [ParticleGPUInstance] {
        simulator.instances(runtimes[index], queue: queue)
    }

    /// How many particles system `index` has spawned so far (the next serial).
    func spawned(_ index: Int) -> UInt32 {
        guard let gpu = runtimes[index].gpu else { return 0 }
        return gpu.control.contents().load(fromByteOffset: ParticleGPUSystem.Control.serial * 4, as: UInt32.self)
    }
}
