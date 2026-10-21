import Foundation
import CryptoKit

/// One member of the `WEUniforms` block, as SPIRV-Cross laid it out (std140).
struct UniformMember: Codable, Equatable {
    let name: String
    let type: String
    let offset: Int
    /// Elements in an array member (1 for scalars/vectors/matrices).
    let count: Int
    /// Bytes between array elements; std140 rounds every element up to 16.
    let arrayStride: Int
    /// Bytes between matrix columns (16 for std140).
    let matrixStride: Int
}

struct UniformLayout: Codable, Equatable {
    let size: Int
    let members: [String: UniformMember]
}

/// A vertex/fragment pair translated to MSL for one resolved combo set.
struct TranslatedShaderVariant: Codable {
    let vertexMSL: String
    let fragmentMSL: String
    /// nil when the pair has no loose uniforms.
    let uniforms: UniformLayout?
    /// `g_TextureN` slots used; texture(N) and sampler(N) in MSL.
    let textureSlots: [Int]
    /// Vertex attribute name → location.
    let attributes: [String: Int]
    /// Combos the variant was compiled with (defaults included).
    let combos: [String: Int]
}

enum ShaderVariantError: Error, CustomStringConvertible {
    case translation(String, underlying: Error)
    case reflection(String)

    var description: String {
        switch self {
        case .translation(let shader, let error): return "\(shader): \(error)"
        case .reflection(let message): return "reflection: \(message)"
        }
    }
}

/// Resolves combos, translates a pair and caches the result on disk.
///
/// Variants are compiled lazily: scenes reference a few hundred (shader, combo) pairs out of
/// hundreds of thousands possible, so nothing is precompiled.
final class ShaderVariantTranslator {
    /// Bump whenever translated output for the same input can change.
    static let revision = 17

    let compiler: ShaderCompiler
    /// Root of the disk cache; variants go into its `generationDirectory`.
    let cacheDirectory: URL?
    /// `<cacheDirectory>/<generation>`: every variant this revision and compiler can produce.
    let generationDirectory: URL?
    /// The compiler's backend, versions and options (`ShaderCompiler.cacheFingerprint`) and the
    /// Metal compiler's OS build (`ShaderToolchainVersions.fingerprint`); names
    /// `generationDirectory` and keys every variant.
    let toolchainFingerprint: String
    /// Where the source a compiler step rejected is written, one file per shader and stage: the
    /// compiler's line numbers refer to it, not to the WE file. nil writes nothing.
    let failureDirectory: URL?
    /// Parsed stages and folded geometry stages, shared by every material planned through this
    /// translator (`ShaderSourceMemo`).
    let sources = ShaderSourceMemo()
    private let lock = NSLock()
    private var memory: [String: TranslatedShaderVariant] = [:]

    /// `FailedShaderDump.defaultDirectory`: a folder in the user's Caches only they can read.
    static var defaultFailureDirectory: URL { FailedShaderDump.defaultDirectory }

    init(compiler: ShaderCompiler, cacheDirectory: URL? = ShaderVariantTranslator.defaultCacheDirectory,
         failureDirectory: URL? = ShaderVariantTranslator.defaultFailureDirectory) {
        self.compiler = compiler
        self.cacheDirectory = cacheDirectory
        self.failureDirectory = failureDirectory
        toolchainFingerprint = ShaderToolchainVersions.fingerprint(compiler: compiler.cacheFingerprint)
        let generation = Self.generation(toolchain: toolchainFingerprint)
        generationDirectory = cacheDirectory?.appending(path: generation, directoryHint: .isDirectory)
        if let cacheDirectory {
            // Off the caller's thread: a stale generation can hold thousands of files.
            DispatchQueue.global(qos: .utility).async {
                Self.pruneStaleGenerations(in: cacheDirectory, keeping: generation)
            }
        }
    }

    static var defaultCacheDirectory: URL? {
        AppStorageLocation.current.appCachesDirectory.appending(path: "shader-variants", directoryHint: .isDirectory)
    }

    /// Names the cache subdirectory of one translator revision and compiler. Variants of any other
    /// can never be read again (their keys include both), so a change starts a new directory and
    /// the old one is deleted (`pruneStaleGenerations`) instead of growing the cache forever.
    static func generation(toolchain: String) -> String {
        let digest = Digest.hex(SHA256.hash(data: Data(toolchain.utf8)).prefix(6))
        return "r\(revision)-\(digest)"
    }

    /// How long another generation is kept after its last use. Two builds used side by side
    /// (a development build next to the installed app) each keep theirs.
    static let staleGenerationAge: TimeInterval = 7 * 24 * 3600

    /// Deletes variants in `root` from before generations (flat `<key>.json` files) and other
    /// generations unused for `staleGenerationAge`, and marks `keeping` as used now.
    static func pruneStaleGenerations(in root: URL, keeping: String, now: Date = Date()) {
        let fileManager = FileManager.default
        // Optional: no directory yet means nothing to prune.
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name != keeping {
            let url = root.appending(path: name)
            if !name.hasSuffix(".json") {
                guard name.hasPrefix("r") else { continue } // not ours
                // Optional: without a date the directory is left alone.
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                guard let modified, now.timeIntervalSince(modified) > staleGenerationAge else { continue }
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                OWELog.error(.shader, "Could not delete the stale shader variant cache \(name): \(error)")
            }
        }
        let current = root.appending(path: keeping).path
        guard fileManager.fileExists(atPath: current) else { return }
        do {
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: current)
        } catch {
            OWELog.error(.shader, "Could not mark the shader variant cache \(keeping) as used: \(error)")
        }
    }

    /// Variants cached in `root`, over every generation.
    static func cachedVariantCount(in root: URL) -> Int {
        let fileManager = FileManager.default
        // Optional: no directory yet means an empty cache.
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.reduce(0) { count, name in
            if name.hasSuffix(".json") { return count + 1 }
            let inner = (try? fileManager.contentsOfDirectory(atPath: root.appending(path: name).path)) ?? [] // not a directory: none
            return count + inner.filter { $0.hasSuffix(".json") }.count
        }
    }

    /// Combo values for a pass: declared defaults < material < effect pass < instance, plus sampler
    /// combos (`"combo":"MASK"`) switched on for bound texture slots, and a bound mask's component
    /// combos (`"components"`) for the channels its `.tex` flags mark painted (`textureFlags`, by
    /// slot; `ShaderUniformDeclaration.componentCombos`).
    static func resolveCombos(vertex: ShaderSource, fragment: ShaderSource, overrides: [[String: Int]],
                              boundTextureSlots: Set<Int>, textureFlags: [Int: UInt32] = [:]) -> [String: Int] {
        var combos: [String: Int] = [:]
        for declaration in vertex.combos + fragment.combos where combos[declaration.name] == nil {
            combos[declaration.name] = declaration.defaultValue
        }
        for sampler in vertex.samplers + fragment.samplers {
            guard let slot = sampler.textureSlot else { continue }
            if let combo = sampler.combo?.uppercased() {
                combos[combo] = boundTextureSlots.contains(slot) ? 1 : (combos[combo] ?? 0)
            }
            guard boundTextureSlots.contains(slot), let flags = textureFlags[slot] else { continue }
            for (component, combo) in sampler.componentCombos.enumerated()
            where !combo.isEmpty && component < 12 && flags & (UInt32(0x100000) << component) != 0 {
                combos[combo.uppercased()] = 1
            }
        }
        for layer in overrides {
            for (name, value) in layer { combos[name.uppercased()] = value }
        }
        return combos
    }

    func variant(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) throws -> TranslatedShaderVariant {
        let toolchain = toolchainFingerprint
        // Combos the shaders never name can't change the translation (the engine's `SCENE_ORTHO`
        // and `HDR` reach every material): one variant serves all their values.
        let combos = Self.effectiveCombos(vertex: vertex, fragment: fragment, combos: combos)
        let key = Self.cacheKey(vertex: vertex, fragment: fragment, combos: combos, toolchain: toolchain)
        lock.lock()
        if let cached = memory[key] { lock.unlock(); return cached }
        lock.unlock()
        if let cached = loadFromDisk(key) {
            store(key, cached, persist: false)
            return cached
        }
        let translated = try OWEPhaseTiming.measure(.shaderTranslate) {
            try translate(vertex: vertex, fragment: fragment, combos: combos)
        }
        store(key, translated, persist: true)
        return translated
    }

    /// The combos of `combos` that can change the translation of `vertex` and `fragment`: those
    /// either stage (includes inlined) or the prelude names as an identifier, which covers every
    /// declared combo (its `// [COMBO]` line names it) and every `#if` on one, plus `LIGHTING` and
    /// the `LIGHTS_*` counts where a stage `#require`s `LightingV1`, whose generated source they
    /// shape (`LightingV1Require`).
    static func effectiveCombos(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) -> [String: Int] {
        let vertexNames = vertex.preludeAnalysis.identifiers, fragmentNames = fragment.preludeAnalysis.identifiers
        let requiresLighting = vertexNames.contains(Substring(LightingV1Require.name))
            || fragmentNames.contains(Substring(LightingV1Require.name))
        return combos.filter { name, _ in
            let token = Substring(name)
            return vertexNames.contains(token) || fragmentNames.contains(token) || ShaderPrelude.commonIdentifiers.contains(token)
                || (requiresLighting && (name == "LIGHTING" || name.hasPrefix("LIGHTS_")))
        }
    }

    /// The combos the prelude `#define`s: `combos` without a sampler's combo (`"combo":"NORMALMAP"`)
    /// at 0 that neither stage declares as a `[COMBO]`. WE defines a sampler's combo only while a
    /// texture is bound to it, which WE's shaders rely on: `genericparticle.frag` lights both sides
    /// under `#ifndef NORMALMAP`, and `generic3.frag` declares `v_WorldNormal` only where
    /// `NORMALMAP` is undefined but reads it wherever `#if NORMALMAP` fails. In an `#if` an
    /// undefined name is 0, so nothing else changes.
    static func definedCombos(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) -> [String: Int] {
        let declared = Set((vertex.combos + fragment.combos).map(\.name))
        let samplerCombos = Set((vertex.samplers + fragment.samplers).compactMap { $0.combo?.uppercased() })
        return combos.filter { name, value in value != 0 || !samplerCombos.contains(name) || declared.contains(name) }
    }

    /// The variant's cache key. Only `effectiveCombos` are hashed, so a combo the shaders never
    /// name doesn't fork the key (test-risks LR17).
    static func cacheKey(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int],
                         toolchain: String = "") -> String {
        let combos = effectiveCombos(vertex: vertex, fragment: fragment, combos: combos)
        var hasher = SHA256()
        hasher.update(data: Data("\(revision)\u{0}\(toolchain)\u{0}".utf8))
        hasher.update(data: Data(vertex.text.utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data(fragment.text.utf8))
        for (name, value) in combos.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("\u{0}\(name)=\(value)".utf8))
        }
        return Digest.hex(hasher.finalize())
    }

    private func translate(vertex: ShaderSource, fragment: ShaderSource,
                           combos: [String: Int]) throws -> TranslatedShaderVariant {
        let label = "\(vertex.path) + \(fragment.path)"
        // The input of the step running now, kept for `recordFailure`.
        var step: (source: ShaderSource, text: String)?
        let defines = Self.definedCombos(vertex: vertex, fragment: fragment, combos: combos)
        do {
            step = (vertex, ShaderPrelude.text(for: .vertex, combos: defines, analysis: vertex.preludeAnalysis) + vertex.text(combos: combos))
            let vertexText = try compiler.preprocess(step!.text, stage: .vertex)
            step = (fragment, ShaderPrelude.text(for: .fragment, combos: defines, analysis: fragment.preludeAnalysis) + fragment.text(combos: combos))
            let fragmentText = try compiler.preprocess(step!.text, stage: .fragment)
            let pair = HLSLFrontEnd.translate(
                vertex: vertexText, fragment: fragmentText,
                stageLocal: ShaderUniformDeclaration.stageLocalNames(vertex: vertex.uniforms, fragment: fragment.uniforms),
                label: label)
            step = (vertex, pair.vertex)
            let compiled: CompiledShaderPair
            do {
                compiled = try compiler.compilePairToMSL(vertex: pair.vertex, fragment: pair.fragment)
            } catch {
                // The compiler names the stage it rejected by its file name.
                if "\(error)".contains("shader.frag") { step = (fragment, pair.fragment) }
                throw error
            }
            let vertexOut = compiled.vertex, fragmentOut = compiled.fragment
            step = nil
            let layout = try Self.uniformLayout(from: fragmentOut.reflection) ?? Self.uniformLayout(from: vertexOut.reflection)
            return TranslatedShaderVariant(vertexMSL: vertexOut.msl, fragmentMSL: fragmentOut.msl, uniforms: layout,
                                           textureSlots: pair.textureSlots, attributes: pair.attributes, combos: combos)
        } catch {
            if let step { recordFailure(step.source, text: step.text, error: error) }
            throw ShaderVariantError.translation(label, underlying: error)
        }
    }

    /// Writes the text a compiler step rejected to `failureDirectory`, with the error after it
    /// (not before, which would shift the line numbers it quotes).
    private func recordFailure(_ source: ShaderSource, text: String, error: Error) {
        guard let failureDirectory else { return }
        let suffix = "." + source.stage.rawValue
        let name = source.path.replacingOccurrences(of: "/", with: "_") + (source.path.hasSuffix(suffix) ? "" : suffix)
        let trailer = "\(error)".split(separator: "\n").map { "// \($0)" }.joined(separator: "\n")
        do {
            let url = try FailedShaderDump(directory: failureDirectory)
                .write(text + (text.hasSuffix("\n") ? "" : "\n") + trailer + "\n", named: name)
            OWELog.error(.shader, "Shader \(source.path) failed to translate; its source is at \(url.path)")
        } catch {
            OWELog.error(.shader, "Could not write the failed shader \(name) to \(failureDirectory.path): \(error)")
        }
    }

    /// Reads the `WEUniforms` block from SPIRV-Cross `--reflect` JSON. Both stages declare the same
    /// block, so either one describes it; a stage that doesn't use any uniform may omit it.
    static func uniformLayout(from reflection: Data) throws -> UniformLayout? {
        guard let root = try JSONSerialization.jsonObject(with: reflection) as? [String: Any] else {
            throw ShaderVariantError.reflection("not a JSON object")
        }
        // The block is found by its type name; the ubo entry's own name is the (empty) instance name.
        guard let ubos = root["ubos"] as? [[String: Any]],
              let types = root["types"] as? [String: [String: Any]],
              let block = ubos.first(where: { ubo in
                  (ubo["type"] as? String).flatMap { types[$0]?["name"] as? String } == HLSLLinkage.uniformBlockName }),
              let typeID = block["type"] as? String,
              let members = types[typeID]?["members"] as? [[String: Any]] else { return nil }
        var result: [String: UniformMember] = [:]
        var alignment = 4
        for member in members {
            // WE's name, a reserved word's too: the toolchain restores it in the SPIR-V (`GLSLReservedWords`).
            guard let name = member["name"] as? String, let offset = member["offset"] as? Int else {
                throw ShaderVariantError.reflection("member without name/offset in \(typeID)")
            }
            let count = (member["array"] as? [Int])?.first ?? 1
            alignment = max(alignment, metalAlignment(ofReflectedType: member["type"] as? String ?? ""))
            result[name] = UniformMember(name: name, type: member["type"] as? String ?? "",
                                         offset: offset, count: max(count, 1),
                                         arrayStride: member["array_stride"] as? Int ?? 0,
                                         matrixStride: member["matrix_stride"] as? Int ?? 0)
        }
        // `block_size` ends at the last member; the MSL struct the shader binds is rounded up to its
        // alignment, and Metal checks the bound length against that.
        let packed = block["block_size"] as? Int ?? 0
        return UniformLayout(size: (packed + alignment - 1) / alignment * alignment, members: result)
    }

    /// Alignment in MSL of a reflected GLSL member type (an array aligns as its element): 8 for a
    /// two-component vector or a matrix of them, 16 for three or four, 4 for a scalar.
    static func metalAlignment(ofReflectedType type: String) -> Int {
        let rows: Int?
        if let range = type.range(of: "vec") {
            rows = Int(type[range.upperBound...])
        } else if type.hasPrefix("mat") {
            // `matN` or `matCxR`: columns are R-component vectors.
            rows = Int(type.split(separator: "x").last.map { String($0.drop(while: { !$0.isNumber })) } ?? "")
        } else {
            rows = nil
        }
        let scalar = type.hasPrefix("d") ? 8 : 4
        guard let rows else { return scalar }
        return scalar * (rows == 2 ? 2 : 4)
    }

    // MARK: - Cache

    private func store(_ key: String, _ variant: TranslatedShaderVariant, persist: Bool) {
        lock.lock()
        memory[key] = variant
        lock.unlock()
        guard persist, let directory = generationDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(variant).write(to: directory.appending(path: "\(key).json"), options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not cache shader variant \(key): \(error)")
        }
    }

    private func loadFromDisk(_ key: String) -> TranslatedShaderVariant? {
        guard let url = generationDirectory?.appending(path: "\(key).json"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(TranslatedShaderVariant.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.shader, "Discarding unreadable cached shader variant \(key): \(error)")
            try? FileManager.default.removeItem(at: url) // corrupt entry; retranslating is the recovery
            return nil
        }
    }
}
