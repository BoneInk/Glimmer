import XCTest
@testable import OpenWallpaperEngine

/// The shader compile helper's protocol, its crash recovery and the failed-shader path, with an
/// in-memory helper (`FakeChannel`) that runs `ShaderCompileHelperServer.handle` like the real one.
final class HelperShaderCompilerTests: XCTestCase {
    /// Echoes its input, tagged, so a test can tell which step produced what.
    private struct StubCompiler: ShaderCompiler {
        var cacheFingerprint: String { "stub" }
        func preprocess(_ source: String, stage: ShaderStage) throws -> String { "pre(\(stage.rawValue)):" + source }
        func compilePairToMSL(vertex: String, fragment: String) throws -> CompiledShaderPair {
            CompiledShaderPair(vertex: try compile(vertex, stage: .vertex), fragment: try compile(fragment, stage: .fragment))
        }
        private func compile(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data) {
            if source.contains("BROKEN") { throw ShaderCompilerError.failed(step: "glslang", output: "ERROR: broken") }
            return ("msl(\(stage.rawValue)):" + source, Data("{}".utf8))
        }
    }

    /// A helper that serves requests in memory, or dies on the requests `crashes` says.
    private final class FakeChannel: ShaderCompileHelperChannel {
        let compiler: ShaderCompiler
        let crashes: (ShaderCompileHelperMessage.Request) -> Bool
        var closed = false

        init(compiler: ShaderCompiler, crashes: @escaping (ShaderCompileHelperMessage.Request) -> Bool) {
            self.compiler = compiler
            self.crashes = crashes
        }

        func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
            XCTAssertFalse(closed, "a closed helper was reused")
            var buffer = request
            let payload = try XCTUnwrap(ShaderCompileHelperFrame.take(from: &buffer))
            XCTAssertTrue(buffer.isEmpty)
            let decoded = try JSONDecoder().decode(ShaderCompileHelperMessage.Request.self, from: payload)
            if crashes(decoded) { throw ShaderCompileHelperChannelError.exited("signal 11") }
            var frame = try ShaderCompileHelperFrame.encode(ShaderCompileHelperServer.handle(decoded, compiler: compiler))
            return try XCTUnwrap(ShaderCompileHelperFrame.take(from: &frame))
        }

        func close() { closed = true }
    }

    private final class Launcher {
        var launches = 0
        var channels: [FakeChannel] = []
        let crashes: (Int, ShaderCompileHelperMessage.Request) -> Bool

        init(crashes: @escaping (Int, ShaderCompileHelperMessage.Request) -> Bool = { _, _ in false }) {
            self.crashes = crashes
        }

        func compiler() -> HelperShaderCompiler {
            HelperShaderCompiler { [self] in
                launches += 1
                let launch = launches
                let channel = FakeChannel(compiler: StubCompiler()) { self.crashes(launch, $0) }
                channels.append(channel)
                return channel
            }
        }
    }

    private func onBackground<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = expectation(description: "compile")
        DispatchQueue.global().async {
            result = Result { try body() }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return try result.get()
    }

    func testFrameRoundTripSplitsAndJoins() throws {
        let request = ShaderCompileHelperMessage.Request(id: 7, operation: .compilePairToMSL, stage: .vertex, source: "void main(){}",
                                                         fragmentSource: "void main(){}")
        var stream = try ShaderCompileHelperFrame.encode(request) + ShaderCompileHelperFrame.encode(request)
        var partial = Data(stream.prefix(5))
        XCTAssertNil(try ShaderCompileHelperFrame.take(from: &partial))
        let first = try XCTUnwrap(ShaderCompileHelperFrame.take(from: &stream))
        XCTAssertEqual(try JSONDecoder().decode(ShaderCompileHelperMessage.Request.self, from: first), request)
        XCTAssertNotNil(try ShaderCompileHelperFrame.take(from: &stream))
        XCTAssertTrue(stream.isEmpty)
    }

    func testRequestResponseRoundTrip() throws {
        let launcher = Launcher()
        let compiler = launcher.compiler()
        let pre = try onBackground { try compiler.preprocess("#define A 1", stage: .vertex) }
        XCTAssertEqual(pre, "pre(vert):#define A 1")
        let out = try onBackground { try compiler.compilePairToMSL(vertex: "v", fragment: "void main(){}") }
        XCTAssertEqual(out.fragment.msl, "msl(frag):void main(){}")
        XCTAssertEqual(out.fragment.reflection, Data("{}".utf8))
        XCTAssertEqual(launcher.launches, 1, "one long-lived helper serves every request")
        let statistics = compiler.currentStatistics
        XCTAssertEqual(statistics.requests, 2)
        XCTAssertGreaterThanOrEqual(statistics.overheadMilliseconds, 0)
        XCTAssertEqual(compiler.cacheFingerprint, InProcessShaderCompiler.fingerprint)
    }

    /// A pair goes to the helper as one request and comes back as both stages.
    func testPairRoundTrip() throws {
        let launcher = Launcher()
        let compiler = launcher.compiler()
        let out = try onBackground { try compiler.compilePairToMSL(vertex: "v", fragment: "f") }
        XCTAssertEqual(out.vertex.msl, "msl(vert):v")
        XCTAssertEqual(out.fragment.msl, "msl(frag):f")
        XCTAssertEqual(launcher.launches, 1)
    }

    func testCompileErrorPassesThroughWithoutRestart() throws {
        let launcher = Launcher()
        let compiler = launcher.compiler()
        XCTAssertThrowsError(try onBackground { try compiler.compilePairToMSL(vertex: "BROKEN", fragment: "f") }) { error in
            guard case ShaderCompilerError.failed(let step, let output)? = error as? ShaderCompilerError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(step, "glslang")
            XCTAssertTrue(output.contains("broken"))
        }
        XCTAssertEqual(launcher.launches, 1)
    }

    func testCrashRestartsAndRetriesOnce() throws {
        // The first helper dies on its first request; the second serves it.
        let launcher = Launcher { launch, _ in launch == 1 }
        let compiler = launcher.compiler()
        let out = try onBackground { try compiler.compilePairToMSL(vertex: "void main(){}", fragment: "f") }
        XCTAssertEqual(out.vertex.msl, "msl(vert):void main(){}")
        XCTAssertEqual(launcher.launches, 2)
        XCTAssertTrue(launcher.channels[0].closed)
        XCTAssertFalse(launcher.channels[1].closed)
    }

    func testSecondCrashFailsTheVariantAndDumpsItToFailedShaders() throws {
        // Every helper dies on the pair's compile.
        let launcher = Launcher { _, request in request.operation == .compilePairToMSL }
        let failures = FileManager.default.temporaryDirectory.appending(path: "owe-helper-failed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: failures) } // Optional: test scratch.
        let translator = ShaderVariantTranslator(compiler: launcher.compiler(), cacheDirectory: nil, failureDirectory: failures)
        let vertex = ShaderSource(stage: .vertex, path: "shaders/crashy.vert", text: "void main() { gl_Position = vec4(0.0); }",
                                  combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "shaders/crashy.frag", text: "void main() { gl_FragColor = vec4(1.0); }",
                                    combos: [], uniforms: [])
        XCTAssertThrowsError(try onBackground { try translator.variant(vertex: vertex, fragment: fragment, combos: [:]) }) { error in
            XCTAssertTrue("\(error)".contains("failed twice"), "\(error)")
        }
        // The first helper served the preprocessing, then crashed; the retry's helper crashed too.
        XCTAssertEqual(launcher.launches, 2)
        let dumped = try FileManager.default.contentsOfDirectory(atPath: failures.path)
        XCTAssertEqual(dumped.count, 1, "\(dumped)")
        XCTAssertTrue(dumped[0].contains("crashy"), dumped[0])
        // The next variant starts a new helper.
        _ = try onBackground { try translator.compiler.preprocess("x", stage: .vertex) }
        XCTAssertEqual(launcher.launches, 3)
    }

    func testHelperEnvironmentKeepsIsolationAndDropsTestInjection() {
        let environment = ShaderCompileHelperProcess.environment(
            ["PATH": "/usr/bin", "XCTestConfigurationFilePath": "/x", "DYLD_INSERT_LIBRARIES": "/y"], isolationTag: "dev")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["XCTestConfigurationFilePath"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(environment[AppStorageLocation.environmentKey], "dev")
    }

    func testFactoryTranslatesInProcessUnderTests() {
        XCTAssertTrue(ShaderCompilerFactory.makeIsolated(qos: .background, inProcessStateDirectory: nil,
                                                         environment: ["XCTestConfigurationFilePath": "/x"])
                      is InProcessShaderCompiler)
    }

    /// The real helper: this app's executable run with `--shader-compile-helper`, over real pipes,
    /// so a stream bug (one the in-memory channel can't have) fails here instead of in the app.
    func testRealHelperExecutableTranslatesEndToEnd() throws {
        let executable = try XCTUnwrap(AppRelauncher.helperExecutable)
        let compiler = HelperShaderCompiler(timeout: 20) {
            try ShaderCompileHelperProcess(executable: executable, qos: .userInitiated,
                                           isolationTag: "helper-e2e-test")
        }
        let source = "#version 450\nlayout(location = 0) out vec4 color;\nvoid main() { color = vec4(0.25); }\n"
        let pre = try onBackground { try compiler.preprocess(source, stage: .fragment) }
        XCTAssertTrue(pre.contains("main"), pre)
        let vertex = "#version 450\nvoid main() { gl_Position = vec4(0.0); }\n"
        let out = try onBackground { try compiler.compilePairToMSL(vertex: vertex, fragment: source) }
        XCTAssertTrue(out.fragment.msl.contains("fragment"), out.fragment.msl)
        XCTAssertFalse(out.fragment.reflection.isEmpty)
        XCTAssertEqual(compiler.currentStatistics.launches, 1, "one helper answered both requests")
    }
}
