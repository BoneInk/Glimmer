import XCTest
@testable import OpenWallpaperEngine

/// Whether an update's shaders are prewarmed: only when the new build's cache key differs.
final class ShaderPrewarmDecisionTests: XCTestCase {
    private let current = ShaderCacheKey(translatorRevision: 10, variantGeneration: "r10-aaaaaa",
                                         pipelineEnvironment: "Version_15--t10-abc--r3")

    private func output(_ key: ShaderCacheKey, logBefore: String = "") throws -> Result<Data, Error> {
        .success(Data(logBefore.utf8) + (try key.encoded()) + Data("\n".utf8))
    }

    func testSameKeyNeedsNoPrewarm() throws {
        XCTAssertEqual(ShaderPrewarmDecision.decide(current: current, newBuildOutput: try output(current)), .notNeeded)
    }

    func testNewTranslatorRevisionNeedsPrewarm() throws {
        let new = ShaderCacheKey(translatorRevision: 11, variantGeneration: "r11-aaaaaa",
                                 pipelineEnvironment: "Version_15--t11-abc--r3")
        XCTAssertEqual(ShaderPrewarmDecision.decide(current: current, newBuildOutput: try output(new)), .needed(new))
    }

    func testNewToolchainNeedsPrewarm() throws {
        let new = ShaderCacheKey(translatorRevision: 10, variantGeneration: "r10-bbbbbb",
                                 pipelineEnvironment: "Version_15--t10-def--r3")
        XCTAssertEqual(ShaderPrewarmDecision.decide(current: current, newBuildOutput: try output(new)), .needed(new))
    }

    func testKeyAfterLogLinesIsRead() throws {
        XCTAssertEqual(ShaderPrewarmDecision.decide(current: current, newBuildOutput: try output(current, logBefore: "starting\n{not json\n")),
                       .notNeeded)
    }

    func testUnreadableOrMissingKeyIsUnknown() {
        for output in [Result<Data, Error>.success(Data("garbage".utf8)), .success(Data()),
                       .success(Data("{\"translatorRevision\":1}".utf8)),
                       .failure(FoundationPrewarmProcessRunner.RunError.exited(status: 1))] {
            guard case .unknown = ShaderPrewarmDecision.decide(current: current, newBuildOutput: output) else {
                return XCTFail("\(output) should be unknown")
            }
        }
    }

    func testCurrentKeyNamesThisBuildsCaches() throws {
        let key = ShaderCacheKey.current
        XCTAssertEqual(key.translatorRevision, ShaderVariantTranslator.revision)
        XCTAssertEqual(key.pipelineEnvironment, EffectPipelineArchive.environmentKey)
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: cleanup of a temp folder.
        let translator = ShaderVariantTranslator(compiler: ShaderCompilerFactory.makeDefault(stateDirectory: nil),
                                                 cacheDirectory: directory, failureDirectory: nil)
        XCTAssertEqual(key.variantGeneration, translator.generationDirectory?.lastPathComponent)
        XCTAssertEqual(try ShaderCacheKey.parse(try key.encoded()), key)
    }
}
