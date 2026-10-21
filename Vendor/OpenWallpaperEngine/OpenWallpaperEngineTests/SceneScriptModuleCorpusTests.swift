import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Every distinct script of the local SceneScript corpus (docs/scenescript-plan.md §2) compiles,
/// keeps its line count, and yields a factory JavaScriptCore accepts. Skipped when the corpus is
/// absent (CI), like `LibrarySweepTests`.
final class SceneScriptModuleCorpusTests: XCTestCase {
    private static let corpus = URL(fileURLWithPath: "/Volumes/980Pro/dd-scenescript/corpus/scripts", isDirectory: true)
    /// 3802509485's text-layer script with a string literal broken across two lines: V8 cannot
    /// compile it either, so WE never runs it.
    private static let brokenScript = "8bb9b9a54120"

    func testEveryCorpusScriptCompiles() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.corpus.path), "SceneScript corpus not present")
        let files = try FileManager.default.contentsOfDirectory(at: Self.corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 281)

        let compiler = SceneScriptModuleTransformer()
        let context = try XCTUnwrap(JSContext())
        let exportPattern = try NSRegularExpression(
            pattern: #"^[ \t]*export[ \t]+(?:async[ \t]+)?(?:function\*?|class|let|var|const)[ \t]+([A-Za-z_$][\w$]*)"#,
            options: [.anchorsMatchLines])
        var compiled = 0
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            if name == Self.brokenScript {
                XCTAssertThrowsError(try compiler.compile(source), name) { error in
                    XCTAssertEqual((error as? SceneScriptCompileError)?.line, 2)
                    XCTAssertEqual((error as? SceneScriptCompileError)?.message, "SyntaxError: Invalid or unexpected token")
                }
                continue
            }
            let module: SceneScriptCompiledModule
            do {
                module = try compiler.compile(source)
            } catch {
                XCTFail("\(name): \(error)")
                continue
            }
            XCTAssertEqual(module.factorySource.components(separatedBy: "\n").count,
                           source.components(separatedBy: "\n").count + 1, "\(name) keeps its lines")

            context.exception = nil
            let factory = context.evaluateScript(module.factorySource, withSourceURL: file)
            if let exception = context.exception {
                XCTFail("\(name): JavaScriptCore rejected the factory: \(exception)")
                continue
            }
            XCTAssertTrue(factory?.isObject == true, name)

            // Every `export <declaration> NAME` at the start of a line is an export.
            let tokens = try SceneScriptTokenizer.tokenize(source)
            var scanner = SceneScriptModuleScanner(tokens: tokens)
            let exported = Set(try scanner.scan().exports.map(\.name))
            let range = NSRange(source.startIndex..., in: source)
            for match in exportPattern.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                XCTAssertTrue(exported.contains(String(source[nameRange])), "\(name) exports \(source[nameRange])")
            }
            compiled += 1
        }
        XCTAssertEqual(compiled, files.count - 1)
    }
}
