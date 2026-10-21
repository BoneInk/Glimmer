import XCTest
@testable import OpenWallpaperEngine

/// The linked glslang/SPIRV-Cross (`InProcessShaderCompiler`), its watchdog and its crash quarantine.
final class InProcessShaderCompilerTests: XCTestCase {
    private struct Job {
        let vertex: ShaderSource
        let fragment: ShaderSource
        let combos: [String: Int]
        var label: String { "\(vertex.path) \(combos.sorted { $0.key < $1.key })" }
    }

    /// Every vert/frag pair in the bundled WE assets, with default combos plus each declared combo
    /// switched on by itself.
    private static func corpus() throws -> [Job] {
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        guard let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) else { return [] }
        var jobs: [Job] = []
        for case let url as URL in files where url.pathExtension == "vert" {
            let fragmentURL = url.deletingPathExtension().appendingPathExtension("frag")
            guard FileManager.default.fileExists(atPath: fragmentURL.path) else { continue }
            let relative = String(url.deletingPathExtension().path.dropFirst(assets.path.count + 1))
            let vertex = try loader.load(relative, stage: .vertex)
            let fragment = try loader.load(relative, stage: .fragment)
            let defaults = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [],
                                                                 boundTextureSlots: [0])
            jobs.append(Job(vertex: vertex, fragment: fragment, combos: defaults))
            for combo in Set((vertex.combos + fragment.combos).map(\.name)).sorted() where defaults[combo] != 1 {
                var combos = defaults
                combos[combo] = 1
                jobs.append(Job(vertex: vertex, fragment: fragment, combos: combos))
            }
        }
        return jobs.sorted { $0.label < $1.label }
    }

    private enum Outcome: Equatable {
        case translated(vertex: String, fragment: String, uniforms: UniformLayout?)
        case failed
    }

    private static func translate(_ job: Job, with compiler: ShaderCompiler) -> Outcome {
        // No disk cache: every call translates. Pairs expected to fail leave no dump.
        let translator = ShaderVariantTranslator(compiler: compiler, cacheDirectory: nil, failureDirectory: nil)
        do {
            let variant = try translator.variant(vertex: job.vertex, fragment: job.fragment, combos: job.combos)
            return .translated(vertex: variant.vertexMSL, fragment: variant.fragmentMSL, uniforms: variant.uniforms)
        } catch {
            return .failed
        }
    }

    func testFingerprintNamesLibraryVersionsAndOptions() {
        let fingerprint = InProcessShaderCompiler().cacheFingerprint
        XCTAssertTrue(fingerprint.hasPrefix("in-process|glslang 16.6.0|spirv-cross vulkan-sdk-1.4.357.0|"), fingerprint)
        XCTAssertTrue(fingerprint.contains("msl20300"), fingerprint)
        XCTAssertFalse(fingerprint.contains("/Users") || fingerprint.contains("/opt"), "machine-specific: \(fingerprint)")
    }

    func testCompileErrorIsReportedNotFatal() {
        XCTAssertThrowsError(try InProcessShaderCompiler().compilePairToMSL(
            vertex: "#version 450\nvoid main() { gl_Position = vec4(0.0); }\n", fragment: "#version 450\nvoid main() { nope(); }")) { error in
            XCTAssertTrue("\(error)".contains("glslang"), "\(error)")
        }
        XCTAssertThrowsError(try InProcessShaderCompiler().preprocess("#if\n", stage: .vertex))
    }

    /// WE declares constants as loose uniforms, which strict GLSL for SPIR-V rejects. glslang's
    /// relaxed Vulkan rules gather both stages' into one `WEUniforms` block at binding 0, the
    /// vertex stage's first, with the same layout in each stage; an initialiser is ignored.
    func testAPairSharesOneUniformBlock() throws {
        let vertex = "#version 450\nuniform float a;\nuniform vec4 b;\nlayout(location = 0) in vec4 p;\n"
            + "void main() { gl_Position = p * a + b; }\n"
        let fragment = "#version 450\nuniform vec4 b;\nuniform vec2 c = vec2(1.0);\nlayout(location = 0) out vec4 o;\n"
            + "void main() { o = b + vec4(c, 0.0, 0.0); }\n"
        let pair = try InProcessShaderCompiler().compilePairToMSL(vertex: vertex, fragment: fragment)
        let vertexLayout = try XCTUnwrap(ShaderVariantTranslator.uniformLayout(from: pair.vertex.reflection))
        let fragmentLayout = try XCTUnwrap(ShaderVariantTranslator.uniformLayout(from: pair.fragment.reflection))
        XCTAssertEqual(vertexLayout, fragmentLayout)
        XCTAssertEqual(vertexLayout.members["a"]?.offset, 0)
        XCTAssertEqual(vertexLayout.members["b"]?.offset, 16)
        XCTAssertEqual(vertexLayout.members["c"]?.offset, 32)
        XCTAssertTrue(pair.fragment.msl.contains("[[buffer(0)]]"), pair.fragment.msl)
    }

    /// glslang is not thread-safe; the library serializes calls, so parallel output equals serial.
    func testParallelTranslationMatchesSerial() throws {
        let jobs = Array(try Self.corpus().prefix(24))
        let compiler = InProcessShaderCompiler()
        let serial = jobs.map { Self.translate($0, with: compiler) }
        let rounds = 4
        var parallel = [Outcome?](repeating: nil, count: jobs.count * rounds)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count * rounds) { index in
            let outcome = Self.translate(jobs[index % jobs.count], with: compiler)
            lock.lock()
            parallel[index] = outcome
            lock.unlock()
        }
        for index in parallel.indices {
            XCTAssertEqual(parallel[index], serial[index % jobs.count], jobs[index % jobs.count].label)
        }
    }

    // MARK: - Crash quarantine

    private func guardDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-guard-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A guard for the next launch: it picks up what dead processes left behind.
    private func launch(_ directory: URL, fingerprint: String = "libs-1") -> InProcessCompileCrashGuard {
        let crashGuard = InProcessCompileCrashGuard(directory: directory, fingerprint: fingerprint)
        crashGuard.collectDeaths()
        return crashGuard
    }

    /// What a crash while compiling `key` leaves: a marker of a process that is gone.
    private func dieCompiling(_ key: String, in directory: URL) {
        InProcessCompileCrashGuard(directory: directory, fingerprint: "libs-1", pid: Int32.max).begin(key)
    }

    func testShaderThatKilledTheAppTwiceIsQuarantined() throws {
        let directory = try guardDirectory()
        dieCompiling("shader-a", in: directory)
        XCTAssertFalse(launch(directory).isQuarantined("shader-a"), "one death (a force quit looks the same) is not enough")
        XCTAssertFalse(launch(directory).isQuarantined("shader-a"), "a launch without a death doesn't count")
        dieCompiling("shader-a", in: directory)
        let next = launch(directory)
        XCTAssertTrue(next.isQuarantined("shader-a"))
        XCTAssertFalse(next.isQuarantined("shader-b"), "every other shader keeps compiling")
        XCTAssertTrue(launch(directory).isQuarantined("shader-a"), "stays quarantined for the same libraries")
        XCTAssertFalse(launch(directory, fingerprint: "libs-2").isQuarantined("shader-a"), "new libraries get another try")
    }

    func testDeathsCountPerShader() throws {
        let directory = try guardDirectory()
        dieCompiling("shader-a", in: directory)
        _ = launch(directory)
        dieCompiling("shader-b", in: directory)
        let next = launch(directory)
        XCTAssertFalse(next.isQuarantined("shader-a"))
        XCTAssertFalse(next.isQuarantined("shader-b"))
    }

    /// A marker without a shader (an older build's) is logged and pins nothing.
    func testDeathWithoutAShaderQuarantinesNothing() throws {
        let directory = try guardDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<InProcessCompileCrashGuard.quarantineThreshold {
            try Data().write(to: directory.appending(path: "pending-\(Int32.max)"))
            _ = launch(directory)
        }
        XCTAssertFalse(launch(directory).isQuarantined(""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCrashGuardIgnoresLiveProcessesAndCleansUp() throws {
        let directory = try guardDirectory()
        let live = InProcessCompileCrashGuard(directory: directory, fingerprint: "libs-1")
        live.begin("shader-a")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "pending-\(getpid())"), encoding: .utf8), "shader-a",
                       "the marker names the shader in flight")
        for _ in 0..<InProcessCompileCrashGuard.quarantineThreshold { _ = launch(directory) }
        XCTAssertFalse(launch(directory).isQuarantined("shader-a"), "this process is alive")
        live.end()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The key covers the variant: the same shader with other combos (defines) is another shader.
    func testShaderKeyCoversStepStageAndVariant() {
        let base = "#define BLUR 1\nvoid main() {}"
        let key = InProcessShaderCompiler.shaderKey(step: "compile", stage: .fragment, source: base)
        XCTAssertEqual(key, InProcessShaderCompiler.shaderKey(step: "compile", stage: .fragment, source: base))
        XCTAssertNotEqual(key, InProcessShaderCompiler.shaderKey(step: "compile", stage: .fragment,
                                                                 source: "#define BLUR 2\nvoid main() {}"))
        XCTAssertNotEqual(key, InProcessShaderCompiler.shaderKey(step: "compile", stage: .vertex, source: base))
        XCTAssertNotEqual(key, InProcessShaderCompiler.shaderKey(step: "preprocess", stage: .fragment, source: base))
    }

    /// A quarantined shader fails with a reason, through the translator too; the others compile.
    func testQuarantinedShaderIsSkippedAndOthersCompile() throws {
        let directory = try guardDirectory()
        let skipped = "#version 450\nlayout(location = 0) out vec4 color;\nvoid main() { color = vec4(1.0); }\n"
        let other = "#version 450\nlayout(location = 0) out vec4 color;\nvoid main() { color = vec4(0.5); }\n"
        let vertex = "#version 450\nvoid main() { gl_Position = vec4(0.0); }\n"
        InProcessCompileCrashGuard(directory: directory, fingerprint: InProcessShaderCompiler.libraryFingerprint)
            .recordHang(InProcessShaderCompiler.shaderKey(step: "compile-pair", stage: .vertex, source: vertex + "\u{0}" + skipped))
        let crashGuard = InProcessCompileCrashGuard(directory: directory, fingerprint: InProcessShaderCompiler.libraryFingerprint)
        crashGuard.collectDeaths()
        let compiler = InProcessShaderCompiler(crashGuard: crashGuard)
        XCTAssertThrowsError(try compiler.compilePairToMSL(vertex: vertex, fragment: skipped)) { error in
            guard case ShaderCompilerError.quarantined = error else { return XCTFail("\(error)") }
            XCTAssertTrue("\(error)".contains("quarantined"), "\(error)")
        }
        XCTAssertFalse(try compiler.compilePairToMSL(vertex: vertex, fragment: other).fragment.msl.isEmpty)
        XCTAssertFalse(try compiler.preprocess(skipped, stage: .fragment).isEmpty, "only the step that failed is skipped")
        XCTAssertFalse(compiler.isStuck)
    }

    // MARK: - Watchdog

    /// A job that never returns until the test ends (a thread can't be killed).
    private func hang() -> () -> String {
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { release.signal() }
        return { release.wait(); return "late" }
    }

    func testCompileThreadTimesOutAndFailsQueuedJobs() throws {
        let thread = ShaderCompileThread(timeout: 0.2)
        XCTAssertEqual(try thread.run { 42 }, 42)
        let hung = hang()
        let queued = expectation(description: "queued job fails")
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            do {
                _ = try thread.run { "never" }
                XCTFail("a job queued behind the hung one must fail")
            } catch ShaderCompileThread.Failure.stuck {
                queued.fulfill()
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try thread.run(hung)) { error in
            guard case ShaderCompileThread.Failure.timedOut = error else { return XCTFail("\(error)") }
        }
        wait(for: [queued], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "callers are released, not held by the hung job")
        XCTAssertTrue(thread.isStuck)
        XCTAssertThrowsError(try thread.run { 1 }, "the stuck thread is never used again")
    }

    func testTimeoutCountsRunTimeNotQueueTime() throws {
        let thread = ShaderCompileThread(timeout: 0.3)
        let results = DispatchQueue.global()
        let group = DispatchGroup()
        var failures = 0
        let lock = NSLock()
        // Eight 0.1 s jobs queue for up to 0.8 s, longer than the timeout, but none overruns it.
        for _ in 0..<8 {
            results.async(group: group) {
                do {
                    _ = try thread.run { Thread.sleep(forTimeInterval: 0.1) }
                } catch {
                    lock.withLock { failures += 1 }
                }
            }
        }
        group.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertFalse(thread.isStuck)
    }

    /// A hang fails its variant, quarantines its shader for the next launch, and fails every later
    /// call this session at once (the libraries' lock is held by the hung thread).
    func testHungCompileQuarantinesItsShaderAndFailsFast() throws {
        let directory = try guardDirectory()
        let libraries = InProcessShaderCompiler.libraryFingerprint
        let crashGuard = InProcessCompileCrashGuard(directory: directory, fingerprint: libraries)
        let compiler = InProcessShaderCompiler(crashGuard: crashGuard, timeout: 0.2)
        XCTAssertThrowsError(try compiler.dispatch(step: "preprocess", key: "hung-shader", hang())) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertTrue(compiler.isStuck)
        XCTAssertTrue(crashGuard.isQuarantined("hung-shader"), "a hang is certain; once is enough")
        let start = Date()
        XCTAssertThrowsError(try compiler.preprocess("void main() {}", stage: .vertex)) { error in
            XCTAssertTrue("\(error)".contains("stuck"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)

        let next = InProcessCompileCrashGuard(directory: directory, fingerprint: libraries)
        next.collectDeaths()
        XCTAssertTrue(next.isQuarantined("hung-shader"), "skipped on the next launch")
        XCTAssertFalse(next.isQuarantined("other-shader"))
    }
}
