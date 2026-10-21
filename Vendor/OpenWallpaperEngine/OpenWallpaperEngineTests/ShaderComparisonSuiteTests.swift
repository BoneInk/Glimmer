import XCTest
import Metal
import CryptoKit
@testable import OpenWallpaperEngine

/// The shader comparison suite: a record of what the translator makes of every shader it can
/// reach, and of a list of scenes drawn with it, to compare two builds of the translator
/// (`Scripts/shader-compare.sh` runs both tests and `Scripts/shader-compare-diff.py` diffs two runs).
///
/// Runs only when `OWE_SHADER_COMPARE_OUT` names the run's folder (`TEST_RUNNER_…` through
/// xcodebuild):
/// - `testTranslateCorpus` translates every vert/frag pair in `OWE_ASSETS` and in each wallpaper
///   folder of `OWE_SHADER_COMPARE_LIBRARY` (read only; the wallpaper's own files first, then the
///   assets, as a scene loads them), with the combo sets of `comboSets` (defaults, each declared
///   combo's values, every texture bound, the engine's combos), plus a pair's geometry stage
///   folded into its vertex stage as particle materials build it, and the variants the
///   materials, effects and scenes of each root build (`recordMaterialRequests`), compiles the
///   MSL with Metal (the sources that fail go to `failed/`), and
///   writes `shaders.json`: per shader and combo set, ok or failed, the error class and a hash of
///   the output.
/// - `testRenderScenes` draws each scene folder listed in the file `OWE_SHADER_COMPARE_SCENES`
///   (one per line) at `OWE_SHADER_COMPARE_TIME` seconds (2), the local time of day
///   `OWE_SHADER_COMPARE_LOCAL_TIME` (12:00, for scenes that read the clock) and 960×540 through
///   `WEReferenceRenderer`, writes `renders/<name>.png`, and with `OWE_SHADER_COMPARE_BASELINE`
///   (an earlier run's folder) compares each frame with the baseline's by `WEReferenceMetrics`
///   (mean absolute difference and SSIM, never byte equality) into `renders.json`.
final class ShaderComparisonSuiteTests: XCTestCase {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static func outputFolder() throws -> URL {
        guard let path = environment["OWE_SHADER_COMPARE_OUT"], !path.isEmpty else {
            throw XCTSkip("set OWE_SHADER_COMPARE_OUT to run the shader comparison suite")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Translation

    struct ShaderRecord: Codable {
        var ok: Bool
        /// The failing step and its first error line without paths or line numbers.
        var error: String?
        /// SHA-256 of both stages' MSL, the uniform layout, texture slots and attributes.
        var hash: String?
    }

    struct CorpusSummary: Codable {
        var revision: Int
        var pairs: Int
        var variants: Int
        var ok: Int
        var failed: Int
        var failedByClass: [String: Int]
        var seconds: Double
    }

    struct CorpusFile: Codable {
        var summary: CorpusSummary
        /// `<root>/<pair path>|<combos>` → record.
        var items: [String: ShaderRecord]
    }

    func testTranslateCorpus() throws {
        let output = try Self.outputFolder()
        let assets = try Fixtures.assets()
        let started = Date()
        // The source each failing variant's compiler step saw, by shader and stage (the last one wins).
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil,
                                                 failureDirectory: output.appending(path: "failed", directoryHint: .isDirectory))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var metalVerdicts: [String: String?] = [:]
        var items: [String: ShaderRecord] = [:]
        var pairs = 0
        // Cache keys translated so far: a material request that repeats one adds nothing.
        var translated = Set<String>()

        var corpora: [(label: String, root: URL, roots: [URL])] = [("assets", assets, [assets])]
        if let library = Self.environment["OWE_SHADER_COMPARE_LIBRARY"], !library.isEmpty {
            let root = URL(fileURLWithPath: library, isDirectory: true)
            for id in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where !id.hasPrefix(".") {
                let folder = root.appending(path: id, directoryHint: .isDirectory)
                corpora.append(("library/\(id)", folder, [folder, assets]))
            }
        }
        func record(_ key: String, _ translate: () throws -> TranslatedShaderVariant) {
            let variant: TranslatedShaderVariant
            do {
                variant = try translate()
            } catch {
                items[key] = ShaderRecord(ok: false, error: Self.translationErrorClass(error))
                return
            }
            let hash = Self.hash(variant)
            if metalVerdicts[hash] == nil {
                metalVerdicts[hash] = Self.metalError(variant, device: device)
            }
            if let failure = metalVerdicts[hash] ?? nil {
                items[key] = ShaderRecord(ok: false, error: "metal: " + failure, hash: hash)
            } else {
                items[key] = ShaderRecord(ok: true, hash: hash)
            }
        }
        for corpus in corpora {
            let roots = corpus.roots
            let readFile: (String) -> Data? = { path in
                for root in roots {
                    // Optional: a root without the file falls through to the next.
                    if let data = try? AssetPathResolver.data(path, in: root) { return data }
                }
                return nil
            }
            let loader = ShaderSourceLoader(readFile: readFile)
            for path in Self.shaderPaths(under: corpus.root) {
                pairs += 1
                let key = "\(corpus.label)/\(path)"
                let vertex: ShaderSource, fragment: ShaderSource
                do {
                    vertex = try loader.load(path, stage: .vertex)
                    fragment = try loader.load(path, stage: .fragment)
                } catch {
                    items[key + "|load"] = ShaderRecord(ok: false, error: "load: " + Self.errorClass("\(error)"))
                    continue
                }
                // The format combos of the samplers' default textures, as the loaders set them.
                let samplers = vertex.samplers + fragment.samplers
                let images = ImageMaterialPlanBuilder(translator: translator, readFile: readFile, loadTexture: { _, _ in nil })
                let formats = ImageMaterialPlanBuilder.formatCombos(
                    samplers, headers: images.formatHeaders(samplers, listed: [:], materialPath: "materials/default.json"))
                for combos in Self.comboSets(vertex: vertex, fragment: fragment, base: formats) {
                    translated.insert(ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos))
                    record(key + "|" + Self.label(combos)) {
                        try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                    }
                }
                // A geometry stage is folded into the vertex stage, as particle materials build it
                // (`ParticleMaterialPlanBuilder`, `GS_ENABLED` 1).
                let geometry: GeometryShaderEmulation.Sources?
                do {
                    geometry = try GeometryShaderEmulation.sources(path, readFile: readFile)
                } catch {
                    items[key + "|geom|load"] = ShaderRecord(ok: false, error: "load: " + Self.errorClass("\(error)"))
                    continue
                }
                guard let geometry else { continue }
                func synthetic(_ name: String, _ text: String) throws -> ShaderSource {
                    let data = Data(text.utf8)
                    return try ShaderSourceLoader(readFile: { $0 == name ? data : readFile($0) }).load(name, stage: .vertex)
                }
                let declarations: ShaderSource
                do {
                    declarations = try synthetic("shaders/\(path)+declarations.vert", geometry.declarations)
                } catch {
                    items[key + "|geom|load"] = ShaderRecord(ok: false, error: "load: " + Self.errorClass("\(error)"))
                    continue
                }
                for combos in Self.comboSets(vertex: declarations, fragment: fragment, base: formats.merging(["GS_ENABLED": 1]) { $1 }) {
                    record(key + "|geom|" + Self.label(combos)) {
                        let emulation = try GeometryShaderEmulation.make(geometry, combos: combos, compiler: translator.compiler)
                        let folded = try synthetic("shaders/\(path)+geom.vert", emulation.vertexText)
                        return try translator.variant(vertex: folded, fragment: fragment, combos: combos)
                    }
                }
            }
            recordMaterialRequests(corpus.label, root: corpus.root, readFile: readFile, translator: translator,
                                   translated: &translated, record: record)
        }
        var byClass: [String: Int] = [:]
        for record in items.values where !record.ok { byClass[record.error ?? "?", default: 0] += 1 }
        let ok = items.values.filter(\.ok).count
        let summary = CorpusSummary(revision: ShaderVariantTranslator.revision, pairs: pairs, variants: items.count,
                                    ok: ok, failed: items.count - ok, failedByClass: byClass,
                                    seconds: Date().timeIntervalSince(started))
        try Self.write(CorpusFile(summary: summary, items: items), to: output.appending(path: "shaders.json"))
        print("Shader corpus: \(pairs) pairs, \(items.count) variants, \(ok) ok, \(items.count - ok) failed "
              + "in \(Int(summary.seconds)) s → \(output.path)/shaders.json")
    }

    /// The variants the materials, effects and scenes under `root` build
    /// (`ShaderComparisonMaterialRequests`), resolved as the loaders resolve them: the slots their
    /// textures fill bound (and slot 0, as every layer's is), the format and component combos of
    /// those textures, the engine's combos of an orthographic LDR scene (`SceneEngineCombos()`)
    /// and `engineShaped`. Recorded under `<label>/<pair>|material|<combos>`, each new variant once.
    private func recordMaterialRequests(_ label: String, root: URL, readFile: @escaping (String) -> Data?,
                                        translator: ShaderVariantTranslator, translated: inout Set<String>,
                                        record: (String, () throws -> TranslatedShaderVariant) -> Void) {
        for request in ShaderComparisonMaterialRequests(readFile: readFile).requests(under: root) {
            let directory = request.directory
            let scoped: (String) -> Data? = { path in
                if !directory.isEmpty, let data = readFile("\(directory)/\(path)") { return data }
                return readFile(path)
            }
            let loader = ShaderSourceLoader(readFile: scoped)
            let pair = (directory.isEmpty ? "" : directory + "/") + "shaders/" + request.shader
            let vertex: ShaderSource, fragment: ShaderSource
            do {
                vertex = try loader.load(request.shader, stage: .vertex)
                fragment = try loader.load(request.shader, stage: .fragment)
            } catch {
                continue // a material whose shader isn't there loads nothing in WE either
            }
            let images = ImageMaterialPlanBuilder(translator: translator, readFile: scoped, loadTexture: { _, _ in nil })
            var headers: [Int: Data] = [:]
            for (slot, name) in request.textures where !name.hasPrefix("_rt_") && name != "previous" {
                headers[slot] = images.textureHeader(name, materialPath: request.materialPath)
            }
            let samplers = vertex.samplers + fragment.samplers
            let formats = ImageMaterialPlanBuilder.formatCombos(
                samplers, headers: images.formatHeaders(samplers, listed: headers, materialPath: request.materialPath))
            let resolved = SceneEngineCombos().applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: request.overrides + [formats],
                boundTextureSlots: Set(request.textures.keys).union([0]),
                textureFlags: headers.compactMapValues { TEXHeader.texiWord(1, in: $0) }))
            let combos = Self.engineShaped(resolved, vertex: vertex, fragment: fragment)
            guard translated.insert(ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos)).inserted
            else { continue }
            record("\(label)/\(pair)|material|" + Self.label(combos)) {
                try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
            }
        }
    }

    /// Pair paths (no extension) under `root`: every `.vert` or `.frag` file's, sorted. The other
    /// stage may come from a later root (a wallpaper's fragment over WE's vertex stage).
    /// `shaders/HLSL/` is left out: it holds Direct3D 11 HLSL (`dx11playlisttransition`,
    /// `dx11fallback`), which `wallpaper64.exe` compiles as is for its playlist transitions and
    /// fallback draw (paths at 0x140477c70 and 0x1404868e0), not WE shaders a material names.
    static func shaderPaths(under root: URL) -> [String] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path
        var paths = Set<String>()
        for case let url as URL in files where url.pathExtension == "vert" || url.pathExtension == "frag" {
            guard !url.pathComponents.contains("HLSL") else { continue }
            paths.insert(String(url.deletingPathExtension().standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return paths.sorted()
    }

    /// The combo sets the suite translates a pair with, each shaped as the engine shapes it
    /// (`engineShaped`):
    /// - the default combos (texture slot 0 bound, as every layer's is);
    /// - each declared combo switched to each other value it can take alone: an `options`
    ///   combo's option values, an `imageblending` combo's blend modes (each `BLENDMODE == n` the
    ///   pair tests, 31 included), any other combo 1;
    /// - every sampler's texture bound (`MASK`, `NORMALMAP`, the PBR maps…), alone and with each
    ///   declared combo switched to its first other value;
    /// - every texture bound under the engine's combos of a perspective HDR scene with fog and
    ///   lights of each kind (`SceneEngineCombos`), within WE's budget: the base counts include
    ///   their shadowed and cookie subsets (`WELightConfig`), at most 3 shadow maps and 1 cookie.
    static func comboSets(vertex: ShaderSource, fragment: ShaderSource, base: [String: Int] = [:]) -> [[String: Int]] {
        let defaults = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [base],
                                                             boundTextureSlots: [0])
        let slots = Set((vertex.samplers + fragment.samplers).compactMap(\.textureSlot)).union([0])
        let bound = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [base],
                                                          boundTextureSlots: slots)
        let declared = declaredComboValues(vertex: vertex, fragment: fragment)
        var sets = [defaults]
        for (combo, values) in declared {
            for value in values where defaults[combo] != value {
                var combos = defaults
                combos[combo] = value
                sets.append(combos)
            }
        }
        sets.append(bound)
        for (combo, values) in declared {
            guard let value = values.first(where: { bound[combo] != $0 }) else { continue }
            var combos = bound
            combos[combo] = value
            sets.append(combos)
        }
        let engine = SceneEngineCombos(
            hdr: true, sceneOrtho: false,
            lightBudget: WELightConfig(point: 2, spot: 3, tube: 1, directional: 2, spotShadow: 0, spotCookie: 1,
                                       spotShadowCookie: 0, directionalShadow: 1, pointShadow: 1),
            shadowQuality: 3, fogDistance: true, fogHeight: true)
        sets.append(engine.applied(to: bound))
        var seen = Set<String>()
        return sets.map { engineShaped($0, vertex: vertex, fragment: fragment) }.filter { seen.insert(label($0)).inserted }
    }

    /// Each declared combo (sorted) and the values it can take: an `options` combo's option
    /// values, an `imageblending` combo's blend modes (`BLENDMODE == n` in either stage), else 1.
    static func declaredComboValues(vertex: ShaderSource, fragment: ShaderSource) -> [(String, [Int])] {
        var result: [String: [Int]] = [:]
        let texts = [vertex.text, fragment.text]
        for text in texts {
            for match in comboPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let json = ShaderSourceLoader.annotation(String(text[Range(match.range(at: 1), in: text)!])),
                      let name = (json["combo"] as? String)?.uppercased(), result[name] == nil else { continue }
                if let options = json["options"] as? [String: Any], !options.isEmpty {
                    let values = options.values.compactMap { ($0 as? NSNumber)?.intValue ?? Int($0 as? String ?? "") }
                    result[name] = Array(Set(values)).sorted()
                } else if json["type"] as? String == "imageblending" {
                    var modes = Set<Int>()
                    for text in texts {
                        let pattern = try! NSRegularExpression(pattern: "\\b\(name)\\s*==\\s*(\\d+)")
                        for mode in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                            if let value = Int(text[Range(mode.range(at: 1), in: text)!]) { modes.insert(value) }
                        }
                    }
                    result[name] = modes.isEmpty ? [1] : modes.sorted()
                } else {
                    result[name] = [1]
                }
            }
        }
        return result.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static let comboPattern = try! NSRegularExpression(pattern: #"//\s*\[COMBO\]\s*(\{[^\n]*\})"#)

    /// `combos` with the values the loaders always supply alongside them: `BONECOUNT` with
    /// `SKINNING` (a model's is at least 16, `ModelMeshCombos.boneCount`) and a puppet channel
    /// material's `BLENDROWCOUNT` (`buildPuppetTextureChannels`), which no material declares.
    static func engineShaped(_ combos: [String: Int], vertex: ShaderSource, fragment: ShaderSource) -> [String: Int] {
        var combos = combos
        if (combos["SKINNING"] ?? 0) != 0, (combos["BONECOUNT"] ?? 0) <= 0 {
            combos["BONECOUNT"] = ModelMeshCombos.boneCount(0)
        }
        let names = vertex.preludeAnalysis.identifiers.union(fragment.preludeAnalysis.identifiers)
        if names.contains("BLENDROWCOUNT"), combos["BLENDROWCOUNT"] == nil { combos["BLENDROWCOUNT"] = 1 }
        return combos
    }

    static func label(_ combos: [String: Int]) -> String {
        combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static func hash(_ variant: TranslatedShaderVariant) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(variant.vertexMSL.utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data(variant.fragmentMSL.utf8))
        for (name, member) in (variant.uniforms?.members ?? [:]).sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("\u{0}\(name):\(member.type):\(member.offset):\(member.count)".utf8))
        }
        hasher.update(data: Data("\u{0}\(variant.textureSlots)\(variant.attributes.sorted { $0.key < $1.key })".utf8))
        return Digest.hex(hasher.finalize())
    }

    /// nil when both stages compile with Metal; else the first error's class.
    static func metalError(_ variant: TranslatedShaderVariant, device: MTLDevice) -> String? {
        for source in [variant.vertexMSL, variant.fragmentMSL] {
            do {
                _ = try device.makeLibrary(source: source, options: nil)
            } catch {
                return errorClass("\(error)")
            }
        }
        return nil
    }

    static func translationErrorClass(_ error: Error) -> String {
        if case ShaderVariantError.translation(_, let underlying) = error {
            if case ShaderCompilerError.failed(let step, let output) = underlying { return "\(step): " + errorClass(output) }
            return errorClass("\(underlying)")
        }
        return errorClass("\(error)")
    }

    /// `LibrarySweepTests.cause`, which groups identical problems: no paths or line numbers.
    static func errorClass(_ detail: String) -> String {
        LibrarySweepTests.cause(detail)
    }

    // MARK: - Renders

    struct RenderRecord: Codable {
        var ok: Bool
        var error: String?
        /// Against the baseline's frame: mean absolute RGB difference (0…255) and SSIM.
        var meanAbs: Double?
        var ssim: Double?
    }

    struct RenderFile: Codable {
        var time: Double
        var width: Int
        var height: Int
        var baseline: String?
        /// Scene folder name → record.
        var scenes: [String: RenderRecord]
    }

    static let renderSize = SIMD2(960, 540)

    func testRenderScenes() throws {
        let output = try Self.outputFolder()
        _ = try Fixtures.assets()
        guard let list = Self.environment["OWE_SHADER_COMPARE_SCENES"], !list.isEmpty else {
            throw XCTSkip("set OWE_SHADER_COMPARE_SCENES to a file listing scene folders")
        }
        let scenes = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let time = Double(Self.environment["OWE_SHADER_COMPARE_TIME"] ?? "") ?? 2
        let localTime = Self.environment["OWE_SHADER_COMPARE_LOCAL_TIME"].flatMap { $0.isEmpty ? nil : $0 } ?? "12:00"
        let baseline = Self.environment["OWE_SHADER_COMPARE_BASELINE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let renders = output.appending(path: "renders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-shader-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) } // scratch cleanup

        var records: [String: RenderRecord] = [:]
        for path in scenes {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            // Folder names repeat across roots (a default project and a Workshop copy): keep the parent.
            let name = directory.deletingLastPathComponent().lastPathComponent + "_" + directory.lastPathComponent
            do {
                let image = try Self.render(directory, time: time, localTime: localTime, storage: scratch.appending(path: name))
                let file = renders.appending(path: "\(name).png")
                try image.write(to: file)
                var record = RenderRecord(ok: true)
                if let baseline {
                    let previous = baseline.appending(path: "renders/\(name).png")
                    if FileManager.default.fileExists(atPath: previous.path) {
                        let before = try WEReferenceImage.load(previous)
                        let after = try WEReferenceImage.load(file)
                        let mask = WEReferenceMask(width: before.width, height: before.height, masks: [], taskbar: 0)
                        let metrics = WEReferenceMetrics.compare(we: before, ours: after, mask: mask,
                                                                 grid: WEReferenceConfig.Grid(columns: 4, rows: 4),
                                                                 taskbar: 0, edges: false)
                        record.meanAbs = metrics.meanAbs
                        record.ssim = metrics.ssim
                    }
                }
                records[name] = record
            } catch {
                records[name] = RenderRecord(ok: false, error: Self.errorClass("\(error)"))
            }
            Fixtures.removeStoredSettings(for: directory)
        }
        try Self.write(RenderFile(time: time, width: Self.renderSize.x, height: Self.renderSize.y,
                                  baseline: baseline?.path, scenes: records),
                       to: output.appending(path: "renders.json"))
        print("Shader compare renders: \(records.count) scenes, \(records.values.filter { !$0.ok }.count) failed → \(renders.path)")
    }

    /// The scene at `time` (at `localTime` of day) with the default properties, WE's gallery quality settings and seeded
    /// particles (`WEReferenceRenderer`), at `renderSize`.
    private static func render(_ directory: URL, time: Double, localTime: String, storage: URL) throws -> WEReferenceImage {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.particleBudget = .unlimited
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        var renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings, storage: storage)
        renderer.outputSize = renderSize
        renderer.localTime = localTime
        let centre = SIMD2(Double(renderSize.x) / 2, Double(renderSize.y) / 2)
        let images = try renderer.render([WEReferenceRenderer.Shot(time: time, cursor: centre)])
        return try XCTUnwrap(images.first)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
