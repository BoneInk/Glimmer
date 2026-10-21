import Foundation
import OWEEditor
import OWESceneEditing

/// The shader editor's translator (`ShaderChecking`): the edited pair translated as the scene
/// loader translates it (`ShaderSourceLoader`, `ShaderVariantTranslator.variant`, the app's shared
/// translator, so a pair that translates is cached for the canvas's reload), and, when it fails,
/// the steps again one by one (`ShaderPrelude`, the compiler's preprocessor, `HLSLFrontEnd`, the
/// compile) to find the step, the text it was given and each error's line in the edited file.
///
/// The compiler numbers lines of the text a step was given: the prelude and the shader with its
/// includes inlined (`ShaderSourceLoader.inlineIncludes`), glslang's preprocessor keeping every
/// line where it was, then the front end's edits. Each is mapped back by its lines
/// (`ShaderLineMap`); an error on a line the edited file doesn't have (the prelude's, a header's)
/// has no line.
struct EditorShaderChecker: ShaderChecking {
    let translator: ShaderVariantTranslator
    /// A file as the editor's scene loader finds it (on the main actor: the editor's resources).
    let read: @MainActor (String) -> Data?

    func check(_ request: ShaderCheckRequest) async -> ShaderCheckResult {
        let loaded: Result<(ShaderSource, ShaderSource, original: [ShaderDiagnostic.Stage: String]), Error> = await MainActor.run {
            let directory = request.effectDirectory
            let readFile: (String) -> Data? = { path in
                for candidate in directory.isEmpty ? [path] : ["\(directory)/\(path)", path] {
                    if let text = request.files[candidate] { return Data(text.utf8) }
                    if let data = read(candidate) { return data }
                }
                return nil
            }
            let loader = ShaderSourceLoader(readFile: readFile)
            do {
                let vertex = try loader.load(request.shader, stage: .vertex)
                let fragment = try loader.load(request.shader, stage: .fragment)
                var original: [ShaderDiagnostic.Stage: String] = [:]
                for stage in [ShaderDiagnostic.Stage.vertex, .fragment] {
                    let file = "shaders/\(request.shader).\(stage.rawValue)"
                    original[stage] = readFile(file).map { String(decoding: $0, as: UTF8.self) }
                }
                return .success((vertex, fragment, original))
            } catch {
                return .failure(error)
            }
        }
        let sources: (vertex: ShaderSource, fragment: ShaderSource, original: [ShaderDiagnostic.Stage: String])
        switch loaded {
        case .success(let value): sources = (value.0, value.1, value.original)
        case .failure(let error):
            return ShaderCheckResult(diagnostics: [ShaderDiagnostic(stage: .fragment, line: nil, message: "\(error)")],
                                     step: "load", log: "\(error)")
        }
        let translator = self.translator
        return await Task.detached(priority: .userInitiated) {
            Self.translate(sources.vertex, sources.fragment, original: sources.original, combos: request.combos,
                           translator: translator)
        }.value
    }

    static func translate(_ vertex: ShaderSource, _ fragment: ShaderSource,
                                      original: [ShaderDiagnostic.Stage: String], combos requested: [String: Int],
                                      translator: ShaderVariantTranslator) -> ShaderCheckResult {
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [requested],
                                                           boundTextureSlots: [0])
        do {
            _ = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
            return .success
        } catch {
            return locate(vertex, fragment, original: original, combos: combos, compiler: translator.compiler, failure: error)
        }
    }

    /// The steps of `ShaderVariantTranslator.translate` one by one, to find the one that fails.
    private static func locate(_ vertex: ShaderSource, _ fragment: ShaderSource,
                                           original: [ShaderDiagnostic.Stage: String], combos: [String: Int],
                                           compiler: ShaderCompiler, failure: Error) -> ShaderCheckResult {
        let defines = ShaderVariantTranslator.definedCombos(vertex: vertex, fragment: fragment, combos: combos)
        var inputs: [ShaderDiagnostic.Stage: String] = [:]
        var preprocessed: [ShaderDiagnostic.Stage: String] = [:]
        var preludeLines: [ShaderDiagnostic.Stage: Int] = [:]
        for (source, stage) in [(vertex, ShaderDiagnostic.Stage.vertex), (fragment, .fragment)] {
            let prelude = ShaderPrelude.text(for: source.stage, combos: defines, analysis: source.preludeAnalysis)
            let input = prelude + source.text(combos: combos)
            inputs[stage] = input
            preludeLines[stage] = prelude.components(separatedBy: "\n").count - 1
            do {
                preprocessed[stage] = try compiler.preprocess(input, stage: source.stage)
            } catch {
                return result(step: "preprocess", log: "\(error)", stageText: [stage: input],
                              map: { stage, line in sourceLine(line, stage: stage) })
            }
        }
        func sourceLine(_ line: Int, stage: ShaderDiagnostic.Stage) -> Int? {
            // The prelude's lines, then the source as the loader expanded it, then the file.
            let expandedLine = line - (preludeLines[stage] ?? 0)
            guard expandedLine >= 1, let input = inputs[stage], let file = original[stage] else { return nil }
            let expanded = Array(input.components(separatedBy: "\n").dropFirst(preludeLines[stage] ?? 0))
            let lines = file.components(separatedBy: "\n")
            let map = ShaderLineMap(from: lines, to: expanded)
            guard map.isShared(expandedLine, from: lines, to: expanded) else { return nil }
            return map.line(expandedLine)
        }
        let stageLocal = ShaderUniformDeclaration.stageLocalNames(vertex: vertex.uniforms, fragment: fragment.uniforms)
        let pair = HLSLFrontEnd.translate(vertex: preprocessed[.vertex] ?? "", fragment: preprocessed[.fragment] ?? "",
                                          stageLocal: stageLocal, label: "\(vertex.path) + \(fragment.path)")
        let translated: [ShaderDiagnostic.Stage: String] = [.vertex: pair.vertex, .fragment: pair.fragment]
        do {
            _ = try compiler.compilePairToMSL(vertex: pair.vertex, fragment: pair.fragment)
        } catch {
            return result(step: "compile", log: "\(error)", stageText: translated) { stage, line in
                // The front end's text → the preprocessed text (line for line as the input).
                guard let before = preprocessed[stage], let after = translated[stage] else { return nil }
                let map = ShaderLineMap(from: before.components(separatedBy: "\n"), to: after.components(separatedBy: "\n"))
                return map.line(line).flatMap { sourceLine($0, stage: stage) }
            }
        }
        // Every step passed here: the variant failed past them (reflection), or in a way the
        // steps alone don't show.
        return ShaderCheckResult(diagnostics: [ShaderDiagnostic(stage: .fragment, line: nil, message: "\(failure)")],
                                 step: "translate", log: "\(failure)")
    }

    /// The problems in `log` (glslang's `ERROR: shader.<stage>:<line>: <message>`), each on its
    /// stage's file line through `map`; the failing stage's text for View Errors.
    private static func result(step: String, log: String, stageText: [ShaderDiagnostic.Stage: String],
                                           map: (ShaderDiagnostic.Stage, Int) -> Int?) -> ShaderCheckResult {
        var diagnostics: [ShaderDiagnostic] = []
        var first: (stage: ShaderDiagnostic.Stage, line: Int)?
        for (stage, line, message) in parseErrors(log) {
            let resolvedStage = stage ?? stageText.keys.first ?? .fragment
            if first == nil, let line { first = (resolvedStage, line) }
            let diagnostic = ShaderDiagnostic(stage: resolvedStage, line: line.flatMap { map(resolvedStage, $0) }, message: message)
            if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
        }
        if diagnostics.isEmpty {
            diagnostics = [ShaderDiagnostic(stage: stageText.keys.first ?? .fragment, line: nil, message: log)]
        }
        let failing = first?.stage ?? diagnostics.first?.stage ?? .fragment
        return ShaderCheckResult(diagnostics: diagnostics, translatedSource: stageText[failing] ?? stageText.values.first,
                                 step: step, translatedLine: first?.line, log: log)
    }

    private static let errorPattern = try! NSRegularExpression(pattern: #"ERROR:\s*(?:shader\.(vert|frag)|\d+):(\d+):\s*(.*)"#)

    /// `(stage, line, message)` of each `ERROR:` line, but glslang's closing summary lines.
    static func parseErrors(_ log: String) -> [(ShaderDiagnostic.Stage?, Int?, String)] {
        var errors: [(ShaderDiagnostic.Stage?, Int?, String)] = []
        for line in log.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = errorPattern.firstMatch(in: line, range: range) {
                let stage = Range(match.range(at: 1), in: line).flatMap { ShaderDiagnostic.Stage(rawValue: String(line[$0])) }
                let number = Range(match.range(at: 2), in: line).flatMap { Int(line[$0]) }
                let message = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? line
                if message.contains("compilation terminated") { continue }
                errors.append((stage, number, message.trimmingCharacters(in: .whitespaces)))
            } else if line.contains("ERROR"), !line.contains("compilation errors") {
                errors.append((nil, nil, line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return errors
    }
}
