import Foundation
import OWEModelImport
import OWESceneEditing
import XCTest

/// WE's default projects keep their models' sources beside the `.mdl`s WE's resource compiler
/// wrote from them (`projects/defaultprojects/*/models/**`: an FBX or OBJ, its configuration
/// JSON and the `.mdl`). Compiling each source here must give WE 2.8's meshes: the same formats,
/// vertices and indices as the `MDLV0023` files and WE 2.8's own recompiles (`OWE_WE_RECOMPILED`). These are WE's files, so they aren't in the repository: the tests read
/// them from a Wallpaper Engine install (`OWE_WE_INSTALL`, the `wallpaper_engine` folder) and skip
/// without one.
final class WEDefaultProjectModelTests: XCTestCase {
    static var projects: URL? {
        guard let install = ProcessInfo.processInfo.environment["OWE_WE_INSTALL"], !install.isEmpty else { return nil }
        let url = URL(fileURLWithPath: install).appending(path: "projects/defaultprojects", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every source with a compiled `.mdl` beside it.
    static func pairs() throws -> [(source: URL, mdl: URL)] {
        guard let projects else { throw XCTSkip("OWE_WE_INSTALL isn't set to a Wallpaper Engine install") }
        var pairs: [(URL, URL)] = []
        let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard ModelFileLoader.fileExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let mdl = url.deletingPathExtension().appendingPathExtension("mdl")
            if FileManager.default.fileExists(atPath: mdl.path) { pairs.append((url, mdl)) }
        }
        return pairs.sorted { $0.0.path < $1.0.path }
    }

    static func config(for source: URL) throws -> (ModelImportConfig, [[String: String]]) {
        let url = source.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url) else { return (.missing, []) }
        let config = try ModelImportConfig(json: data)
        var skins: [[String: String]] = []
        if case .array(let list)? = config.other["skins"] {
            for case .object(let skin) in list {
                skins.append(skin.compactMapValues(\.stringValue))
            }
        }
        return (config, skins)
    }

    /// WE 2.8.0.42's own recompiles of default-project sources (capture 546: Import Model wrote
    /// `<name>.mdl` and `<name>.json` for `bars.obj`, `flow.obj` and `pistols.fbx`; they are in
    /// the `we-test-wp-images` branch at `tools/peer/requests/owe-beta7/models-open/546-fbx-import/recompiled`),
    /// from `OWE_WE_RECOMPILED`. They replace the shipped `.mdl` as the reference for their source.
    static var recompiled: URL? {
        guard let path = ProcessInfo.processInfo.environment["OWE_WE_RECOMPILED"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The `.mdl` to compare a source with, its configuration, and whether WE 2.8's compiler
    /// wrote it (`MDLV0023`). The default projects ship most models as `MDLV0004` and
    /// `MDLV0014`, older compilers' output that WE 2.8's editor compiles anew before it uses it
    /// (capture 546): those are held to their formats and triangles only, since WE 2.8 shares a
    /// polygon's corners and computes tangents on the unflipped coordinates where they didn't.
    static func reference(for source: URL, mdl: URL) throws -> (mdl: Data, config: ModelImportConfig, skins: [[String: String]], current: Bool) {
        let name = source.deletingPathExtension().lastPathComponent
        if let recompiled, let data = try? Data(contentsOf: recompiled.appending(path: "\(name).mdl")),
           let json = try? Data(contentsOf: recompiled.appending(path: "\(name).json")) {
            return (data, try ModelImportConfig(json: json), [], true)
        }
        let data = try Data(contentsOf: mdl)
        let (config, skins) = try Self.config(for: source)
        return (data, config, skins, data.starts(with: Array("MDLV0023".utf8)))
    }

    /// Meshes of WE 2.8's own output that differ from it although format and vertices agree
    /// (docs/model-import.md). Capture 546 settled the seven listed before: bars, flow (and dome
    /// and shadow, the same `MDLV0014`-era OBJs) were the old compilers' output, and pistols'
    /// meshes split as WE 2.8 splits them once a polygon's corners are shared and every texture
    /// coordinate set takes part in the joining. What is left is pistols' triangle order: WE's
    /// Assimp reorders a mesh's triangles for the vertex cache (ImproveCacheLocality), and mesh
    /// 0 has a pentagon Assimp's ear clipping splits along other diagonals than ufbx's.
    static let knownDivergences: Set<String> = [
        "arsenal/models/pistols/pistols.fbx#0", "arsenal/models/pistols/pistols.fbx#2",
        "arsenal/models/pistols/pistols.fbx#3", "arsenal/models/pistols/pistols.fbx#4",
    ]

    /// A mesh's triangles, each from its smallest index, in order: the same set however they
    /// are ordered and turned.
    static func triangles(_ indices: Data) -> [[UInt32]] {
        let values: [UInt32] = indices.count % 2 == 0
            ? indices.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map(UInt32.init) } : []
        return Swift.stride(from: 0, to: values.count - 2, by: 3).map { first -> [UInt32] in
            let t = Array(values[first..<(first + 3)])
            let start = t.firstIndex(of: t.min()!)!
            return (0..<3).map { t[(start + $0) % 3] }
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func testEveryDefaultProjectSourceCompilesToWEsMeshes() throws {
        let pairs = try Self.pairs()
        XCTAssertGreaterThan(pairs.count, 20)
        var report: [String] = []
        var exact = 0, identical = 0, current = 0, older = 0, olderExact = 0
        var largest: Float = 0
        for (source, mdl) in pairs {
            let name = source.path.components(separatedBy: "defaultprojects/").last ?? source.lastPathComponent
            let reference = try Self.reference(for: source, mdl: mdl)
            let loaded = try ModelFileLoader.load(contentsOf: source)
            let output = try ModelCompiler.compile(loaded, config: reference.config, folder: "x", skins: reference.skins)
            let ours = try MDLTestReader.read(output.mdl)
            let theirs = try MDLTestReader.read(reference.mdl)
            guard ours.meshes.count == theirs.meshes.count else {
                report.append("\(name): \(ours.meshes.count) meshes, WE \(theirs.meshes.count)")
                continue
            }
            XCTAssertEqual(ours.legacyFormat, theirs.legacyFormat, name)
            for (index, (a, b)) in zip(ours.meshes, theirs.meshes).enumerated() {
                XCTAssertEqual(a.materials.count, b.materials.count, "\(name) mesh \(index)")
                XCTAssertEqual(a.format, b.format, "\(name) mesh \(index): format")
                XCTAssertEqual(a.indices.count, b.indices.count, "\(name) mesh \(index): index count")
                var problems: [String] = []
                if a.vertices.count != b.vertices.count { problems.append("vertex bytes \(a.vertices.count) vs \(b.vertices.count)") }
                if a.indices != b.indices {
                    problems.append(Self.triangles(a.indices) == Self.triangles(b.indices) ? "triangle order" : "indices differ")
                }
                if a.vertices.count == b.vertices.count, a.format == b.format {
                    let difference = Self.largestDifference(a.vertices, b.vertices, stride: Self.stride(a.format), format: a.format)
                    if difference.value > 1e-3 { problems.append("vertex values differ by \(difference.value) at \(difference.attribute)") }
                }
                let key = "\(name)#\(index)"
                guard reference.current else {
                    older += 1
                    if problems.isEmpty { olderExact += 1 }
                    continue
                }
                current += 1
                if problems.isEmpty {
                    exact += 1
                    if a.vertices == b.vertices { identical += 1 }
                    largest = max(largest, Self.largestDifference(a.vertices, b.vertices, stride: Self.stride(a.format), format: a.format).value)
                    XCTAssertFalse(Self.knownDivergences.contains(key), "\(key) now matches WE: drop it from knownDivergences")
                } else if !Self.knownDivergences.contains(key) {
                    report.append("\(key): " + problems.joined(separator: "; "))
                }
            }
        }
        XCTAssert(report.isEmpty, report.joined(separator: "\n"))
        print("WE default projects: \(exact) of \(current) meshes match WE 2.8's (\(identical) byte for byte, the others within \(largest)), "
              + "\(Self.knownDivergences.count) known divergences; \(olderExact) of \(older) older-compiler meshes match too")
        XCTAssertGreaterThanOrEqual(current, Self.recompiled == nil ? 3 : 11)
    }

    static let attributes: [(mask: UInt32, size: Int, name: String)] = [
        (0x1, 12, "position"), (0x10000, 16, "positionVec4"), (0x2000000, 12, "positionC1"), (0x2, 12, "normal"),
        (0x4, 16, "tangent"), (0x800000, 16, "blendIndices"), (0x1000000, 16, "blendWeights"), (0x8, 8, "uv"), (0x10, 12, "uvVec3"),
        (0x20, 16, "uvVec4"),
    ]

    static func stride(_ format: UInt32) -> Int { attributes.reduce(0) { format & $1.mask != 0 ? $0 + $1.size : $0 } }

    /// The largest difference of any float and the attribute it is in.
    static func largestDifference(_ a: Data, _ b: Data, stride: Int, format: UInt32) -> (value: Float, attribute: String) {
        let fa = a.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let fb = b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var worst: Float = 0, attribute = ""
        let names: [String] = attributes.flatMap { format & $0.mask != 0 ? Array(repeating: $0.name, count: $0.size / 4) : [] }
        for index in fa.indices where abs(fa[index] - fb[index]) > worst {
            worst = abs(fa[index] - fb[index])
            attribute = names.isEmpty ? "" : names[index % (stride / 4)] + " of vertex \(index / (stride / 4))"
        }
        return (worst, attribute)
    }
}
