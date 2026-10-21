import XCTest
import Metal
@testable import OpenWallpaperEngine

final class EffectPipelineArchiveTests: XCTestCase {
    private var device: MTLDevice!
    private var directory: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-archive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func descriptor(red: Int = 1) throws -> MTLRenderPipelineDescriptor {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1), float(id >> 1), 0, 1); }
        fragment float4 f() { return float4(\(red) / 100.0, 0, 0, 1); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v")
        descriptor.fragmentFunction = library.makeFunction(name: "f")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        return descriptor
    }

    func testCompiledPipelinesArePersistedAndHitOnTheNextLaunch() throws {
        let first = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: first, key: "a")
        XCTAssertEqual(first.additions, 1)
        first.flush()
        XCTAssertEqual(first.writeFailures, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "writes go through a temporary file that is renamed")

        let second = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: second, key: "a")
        XCTAssertEqual(second.hits, 1)
        XCTAssertEqual(second.additions, 0)
    }

    /// Pipelines compile on a concurrent queue; lookups and additions must not corrupt the archive.
    func testConcurrentCompilesSerializeCleanly() throws {
        let archive = EffectPipelineArchive(device: device, directory: directory)
        let descriptors = try (0..<24).map { try descriptor(red: $0) }
        let device: MTLDevice = self.device
        DispatchQueue.concurrentPerform(iterations: descriptors.count) { index in
            do {
                _ = try EffectGraphRenderer.makePipeline(descriptors[index], device: device, archive: archive, key: "\(index)")
            } catch {
                XCTFail("\(error)")
            }
        }
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
        let reopened = EffectPipelineArchive(device: device, directory: directory)
        for index in [0, 11, 23] {
            _ = try EffectGraphRenderer.makePipeline(try descriptor(red: index), device: device, archive: reopened, key: "\(index)")
        }
        XCTAssertEqual(reopened.hits, 3)
    }

    /// Translated WE shaders are one library per stage; each pipeline takes its two entry points
    /// from two libraries.
    func testPipelinesFromPerStageLibrariesSerialize() throws {
        for launch in 0..<3 {
            let archive = EffectPipelineArchive(device: device, directory: directory)
            try addPerStagePipelines(range: (launch * 4)..<(launch * 4 + 4), to: archive)
            archive.flush()
            XCTAssertEqual(archive.writeFailures, 0, "launch \(launch)")
        }
    }

    private func addPerStagePipelines(range: Range<Int>, to archive: EffectPipelineArchive) throws {
        for red in range {
            let vertexLibrary = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 main0(uint id [[vertex_id]]) { return float4(float(id & 1) * \(red + 1), float(id >> 1), 0, 1); }
            """, options: nil)
            let fragmentLibrary = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            fragment float4 main0() { return float4(\(red % 2) / 10.0, 0, 0, 1); }
            """, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexLibrary.makeFunction(name: "main0")
            descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            _ = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: "stage\(red)")
        }
    }

    /// One variant is used with several target formats and blend modes.
    func testSameFunctionsWithDifferentTargetsSerialize() throws {
        let archive = EffectPipelineArchive(device: device, directory: directory)
        let base = try descriptor()
        for format in [MTLPixelFormat.rgba8Unorm, .r16Float, .rgba16Float] {
            for blend in [false, true] {
                let descriptor = base.copy() as! MTLRenderPipelineDescriptor // copy() returns its own class
                descriptor.colorAttachments[0].pixelFormat = format
                descriptor.colorAttachments[0].isBlendingEnabled = blend
                _ = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: "\(format.rawValue)|\(blend)")
            }
        }
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
    }

    func testCorruptArchiveIsDiscardedAndReplaced() throws {
        let url = EffectPipelineArchive(device: device, directory: directory).url
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        XCTAssertTrue(archive.archives.isEmpty, "the corrupt archive is not used")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "and it is deleted")
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: archive, key: "a")
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
        XCTAssertNotNil(try? device.makeBinaryArchive(descriptor: {
            let descriptor = MTLBinaryArchiveDescriptor()
            descriptor.url = url
            return descriptor
        }()), "the rewritten archive opens")
    }

    /// A real archive cut short (killed mid-write by a build without the rename, disk full) is
    /// discarded like random bytes, never handed to the driver.
    func testTruncatedArchiveIsDiscarded() throws {
        let first = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: first, key: "a")
        first.flush()
        let url = first.url
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 64)
        try bytes.prefix(bytes.count / 2).write(to: url)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        // Metal may open a cut file and just miss; either way the pipeline must still compile.
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: archive, key: "a")
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
    }

    /// Every GPU gets its own file, named by its registry ID, so a binary built for one GPU is
    /// never handed to another (dGPU/iGPU switching, eGPUs, a display on another GPU).
    func testEachGPUHasItsOwnArchive() throws {
        let devices = MTLCopyAllDevices()
        let urls = devices.map { EffectPipelineArchive(device: $0, directory: directory).url }
        XCTAssertEqual(Set(urls).count, devices.count)
        for (device, url) in zip(devices, urls) {
            XCTAssertTrue(url.lastPathComponent.contains("-\(String(device.registryID, radix: 16))--"), url.lastPathComponent)
            XCTAssertTrue(EffectPipelineArchive.shared(device: device, directory: directory).url == url)
        }
    }

    func testArchivesForAnotherBuildOfThisGPUAreDeleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = EffectPipelineArchive.devicePrefix(device)
        let stale = directory.appending(path: "\(prefix)--old-os--0.1-1--r1.binarchive")
        let otherGPU = directory.appending(path: "Other-GPU-1--old-os--0.1-1--r1.binarchive")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: otherGPU)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherGPU.path), "other GPUs keep their archives")
        XCTAssertTrue(archive.url.lastPathComponent.hasPrefix(prefix))
        XCTAssertTrue(archive.url.lastPathComponent.contains("--r\(EffectPipelineArchive.revision)"))
    }

    /// Renderers of one device share one archive, so they don't overwrite each other's file.
    func testRenderersOfADeviceShareOneArchive() throws {
        let a = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory))
        let b = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory))
        XCTAssertTrue(a.pipelineArchive === b.pipelineArchive)
        let other = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory.appending(path: "other")))
        XCTAssertFalse(a.pipelineArchive === other.pipelineArchive)
    }

    /// Metal fails to serialize an archive that grew after a write for some sets of WE's built-in
    /// pipelines ("missing 'vertex' stage in pipeline no. N"); every write is built afresh, so
    /// frequent writes across two launches keep every pipeline.
    func testBuiltinEffectPipelinesSurviveRepeatedWritesAndLaunches() throws {
        _ = try Fixtures.assets()
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil)
        let effects = try FileManager.default.contentsOfDirectory(atPath: assets.appending(path: "effects").path).sorted()
        var descriptors: [(key: String, descriptor: MTLRenderPipelineDescriptor)] = []
        for effect in effects {
            let shaders = assets.appending(path: "effects/\(effect)/shaders/effects")
            // Optional: an effect without its own shaders uses shared ones.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: shaders.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".vert") {
                let path = "effects/\(effect)/shaders/effects/\(name.dropLast(5))"
                let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
                let base = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
                for combo in [nil] + Set((vertex.combos + fragment.combos).map(\.name)).sorted() {
                    var combos = base
                    if let combo { combos[combo] = 1 }
                    // Optional: a combo that doesn't translate is another test's concern.
                    guard let variant = try? translator.variant(vertex: vertex, fragment: fragment, combos: combos) else { continue }
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = try device.makeLibrary(source: variant.vertexMSL, options: nil).makeFunction(name: "main0")
                    descriptor.fragmentFunction = try device.makeLibrary(source: variant.fragmentMSL, options: nil).makeFunction(name: "main0")
                    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
                    descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: try XCTUnwrap(descriptor.vertexFunction))
                    descriptors.append(("\(path)|\(combos.sorted { $0.key < $1.key })", descriptor))
                }
            }
        }
        XCTAssertGreaterThan(descriptors.count, 100)
        let split = descriptors.count * 2 / 3
        for (launch, range) in [(0, 0..<split), (1, (descriptors.count / 3)..<descriptors.count)] {
            let archive = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 1000)
            for index in range {
                _ = try EffectGraphRenderer.makePipeline(descriptors[index].descriptor.copy() as! MTLRenderPipelineDescriptor, // copy() returns its own class
                                                         device: device, archive: archive, key: descriptors[index].key)
                if index % 5 == 4 { archive.flush() }
            }
            archive.flush()
            XCTAssertEqual(archive.writeFailures, 0, "launch \(launch)")
            if launch == 1 { XCTAssertGreaterThanOrEqual(archive.hits, split - descriptors.count / 3, "the first launch's pipelines are found") }
        }
    }

    // MARK: - Failure and lifetime

    /// A write failing inside Metal can hand back an NSError Metal already freed, which crashes in
    /// `objc_retain`; so a failure is never retried in the same session, and it doesn't drop
    /// pipelines from later launches either.
    func testAFailedWriteIsNotRetried() throws {
        let archive = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 1000, metalScratchDirectory: nil)
        try FileManager.default.removeItem(at: directory) // the move into place fails
        archive.add(try descriptor(red: 1), key: "a")
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 1)
        archive.add(try descriptor(red: 2), key: "b")
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 1, "no second attempt")
        XCTAssertEqual(archive.writes, 0)

        let next = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 1000, metalScratchDirectory: nil)
        next.add(try descriptor(red: 1), key: "a")
        next.flush()
        XCTAssertEqual(next.writes, 1, "the next launch writes the pipeline the failed write had")
    }

    /// Writes wait for the *last* addition, so a burst longer than the delay still writes once.
    func testABurstOfAdditionsWritesOnce() throws {
        // A clock and timer driven by hand: under a loaded machine, real sleeps stretched the
        // burst into two writes, or the write past the test's wait.
        let clock = ManualClock()
        let archive = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 0.5,
                                            metalScratchDirectory: nil, timing: clock.timing)
        let descriptors = try (0..<12).map { try descriptor(red: $0) }
        for (index, descriptor) in descriptors.enumerated() {
            archive.add(descriptor, key: "\(index)")
            clock.advance(by: 0.1)
        }
        XCTAssertEqual(archive.writes, 0, "additions 0.1 s apart keep postponing the write")
        clock.advance(by: 0.5)
        XCTAssertEqual(archive.writes, 1)
        clock.advance(by: 10)
        XCTAssertEqual(archive.writes, 1)
        XCTAssertEqual(archive.writeFailures, 0)
    }

    /// Time that only moves when the test says; scheduled work runs, in deadline order, as it
    /// comes due.
    private final class ManualClock {
        private var now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        private var pending: [(deadline: DispatchTime, work: () -> Void)] = []

        var timing: EffectPipelineArchive.Timing {
            EffectPipelineArchive.Timing(now: { [unowned self] in self.now },
                                         schedule: { [unowned self] deadline, work in self.pending.append((deadline, work)) })
        }

        func advance(by seconds: TimeInterval) {
            now = now + seconds
            while let next = pending.indices.filter({ pending[$0].deadline <= now }).min(by: { pending[$0].deadline < pending[$1].deadline }) {
                pending.remove(at: next).work()
            }
        }
    }

    /// Metal leaves a `gpuarchiver-*` build directory behind for every serialization. Old ones
    /// are deleted; one a write may still be using (recent contents) and anything else stay.
    func testMetalBuildDirectoriesLeftBehindAreDeleted() throws {
        let scratch = directory.appending(path: "gpuarchiver-root")
        let old = scratch.appending(path: "gpuarchiver-0a1b2c"), busy = scratch.appending(path: "gpuarchiver-3d4e5f")
        let other = scratch.appending(path: "PersistentState")
        for folder in [old, busy, other] {
            try FileManager.default.createDirectory(at: folder.appending(path: "air64_v29"), withIntermediateDirectories: true)
        }
        let past = Date().addingTimeInterval(-2 * EffectPipelineArchive.scratchAge)
        for path in [old, old.appending(path: "air64_v29"), busy, other, other.appending(path: "air64_v29")] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path.path)
        }
        EffectPipelineArchive.deleteMetalScratch(in: scratch, olderThan: EffectPipelineArchive.scratchAge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.path), "recently written contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "not a build directory")
    }

    /// Renderers come and go (wallpaper switches, tests) while their compiles still add pipelines
    /// and debounced writes fire; every write must still serialize, and the next archive for the
    /// file must find the pipelines.
    func testArchivesComingAndGoingWhileWritingStaySerializable() throws {
        let device: MTLDevice = self.device
        var hits = 0
        for round in 0..<8 {
            let archive = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 0.01, metalScratchDirectory: nil)
            let descriptors = try (0..<6).map { try descriptor(red: round * 6 + $0) }
            let reused = round > 0 ? [try descriptor(red: (round - 1) * 6)] : []
            DispatchQueue.concurrentPerform(iterations: descriptors.count + reused.count) { index in
                let isReused = index >= descriptors.count
                let red = isReused ? (round - 1) * 6 : round * 6 + index
                let descriptor = isReused ? reused[0] : descriptors[index]
                do {
                    _ = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: "\(red)")
                } catch {
                    XCTFail("\(error)")
                }
                Thread.sleep(forTimeInterval: 0.005 * Double(index))
            }
            // Odd rounds let the timer's write start first; flush waits for it.
            if round % 2 == 1 { Thread.sleep(forTimeInterval: 0.02) }
            archive.flush()
            XCTAssertEqual(archive.writeFailures, 0, "round \(round)")
            hits += archive.hits
        }
        XCTAssertGreaterThan(hits, 0, "later rounds find earlier rounds' pipelines")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    /// Regression: deleting the archive's directory while Metal wrote into it made
    /// `serialize(to:)` return a freed error, and the test host died with SIGSEGV in `objc_retain`
    /// under `-[_MTLBinaryArchive airntSerializeToURL:options:error:]` (the tests delete their
    /// scratch directories; a cache purge does the same to the app). Metal now writes to a
    /// staging file of its own and the move into the directory fails instead.
    func testDeletingTheDirectoryWhileAWriteIsInFlightDoesNotCrash() throws {
        let descriptors = try (0..<12).map { try descriptor(red: $0) }
        for round in 0..<10 {
            let folder = directory.appending(path: "round-\(round)")
            let archive = EffectPipelineArchive(device: device, directory: folder, serializeDelay: 1000, metalScratchDirectory: nil)
            for (index, descriptor) in descriptors.enumerated() { archive.add(descriptor, key: "\(index)") }
            let writing = DispatchGroup()
            DispatchQueue.global(qos: .utility).async(group: writing) { archive.flush() }
            Thread.sleep(forTimeInterval: Double.random(in: 0...0.08))
            try? FileManager.default.removeItem(at: folder) // may race the write; that is the point
            writing.wait()
            XCTAssertEqual(archive.writes + archive.writeFailures, 1, "round \(round)")
        }
    }
}
