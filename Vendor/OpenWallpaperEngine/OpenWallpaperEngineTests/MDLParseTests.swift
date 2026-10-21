import XCTest
import simd
@testable import OpenWallpaperEngine

/// The `.mdl` reader (docs/models-plan.md §1) against `Scripts/mdl-reference.py`: the hand-built
/// fixtures of `Tests/Fixtures/Models` (one model per version and section, every optional block
/// somewhere, and malformed ones; written by `Scripts/mdl-fixtures.py`) and WE's vendored editor
/// camera, decoded field for field as `expected.json` has them. Truncated and corrupted copies
/// fail cleanly.
final class MDLParseTests: XCTestCase {
    struct Entry {
        let file: String
        let inline: Int?
        let model: [String: Any]
    }

    /// The fixtures, and WE's own models (`assets:<path>`) when `OWE_ASSETS` names the assets.
    static func entries() throws -> [Entry] {
        let json = try JSONSerialization.jsonObject(with: Fixtures.data("Models/expected.json")) as? [[String: Any]]
        return try XCTUnwrap(json).map {
            Entry(file: $0["file"] as? String ?? "", inline: $0["inline"] as? Int, model: $0["model"] as? [String: Any] ?? [:])
        }.filter { !$0.file.hasPrefix(assetsPrefix) || WallpaperEngineAssets.directory != nil }
    }

    static let assetsPrefix = "assets:"

    static let repository = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()

    static func data(_ entry: Entry) throws -> Data {
        if entry.file.hasPrefix(assetsPrefix) {
            return try Data(contentsOf: Fixtures.assets().appending(path: String(entry.file.dropFirst(assetsPrefix.count))))
        }
        return try Data(contentsOf: repository.appending(path: entry.file))
    }

    /// Checks one decode against the script's: the same error kind, or the same fields.
    static func check(_ data: Data, expected: [String: Any], inline: Int?, label: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        if let error = expected["error"] as? [String: Any] {
            do {
                _ = try MDLReader.read(data)
                XCTFail("\(label): parsed, the reference rejects it: \(error["message"] ?? "")", file: file, line: line)
            } catch {
                XCTAssertEqual(MDLReferenceDump.kind(of: error), expected["error"].flatMap { ($0 as? [String: Any])?["kind"] as? String },
                               "\(label): \(error)", file: file, line: line)
            }
            return
        }
        do {
            let model = try MDLReader.read(data)
            let differences = MDLReferenceDump.differences(expected, MDLReferenceDump(inline: inline).model(model))
            XCTAssert(differences.isEmpty, "\(label):\n" + differences.joined(separator: "\n"), file: file, line: line)
        } catch {
            XCTFail("\(label): \(error)", file: file, line: line)
        }
    }

    func testFixturesDecodeAsTheReferenceDoes() throws {
        let entries = try Self.entries()
        // 18 fixtures, and WE's camera model when `OWE_ASSETS` is set.
        XCTAssertEqual(entries.count, WallpaperEngineAssets.directory == nil ? 18 : 19)
        for entry in entries {
            Self.check(try Self.data(entry), expected: entry.model, inline: entry.inline, label: entry.file)
        }
        // Every version and section of the library, and every rejection, is covered.
        let tags = Set(entries.compactMap { $0.model["tag"] as? String }
            + entries.flatMap { ($0.model["sections"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String } })
        for tag in ["MDLV0004", "MDLV0013", "MDLV0014", "MDLV0016", "MDLV0017", "MDLV0019", "MDLV0021", "MDLV0023",
                    "MDLS0001", "MDLS0002", "MDLS0003", "MDLS0004", "MDLA0001", "MDLA0005", "MDLA0006",
                    "MDAT0001", "MDMP0001", "MDLE0002"] {
            XCTAssert(tags.contains(tag), tag)
        }
        let kinds = Set(entries.compactMap { ($0.model["error"] as? [String: Any])?["kind"] as? String })
        XCTAssertEqual(kinds, ["truncated", "not_mdlv", "too_many_bones", "malformed"])
    }

    func testTheBoneLimitIs128() throws {
        let data = try Fixtures.data("Models/bad-129-bones.mdl")
        XCTAssertThrowsError(try MDLReader.read(data)) { XCTAssertEqual($0 as? MDLError, .tooManyBones(129)) }
    }

    /// Every prefix of every fixture is rejected as truncated, except those that keep the whole
    /// model and drop only fill after the end, which WE never reads.
    func testTruncatedModelsFailCleanly() throws {
        for entry in try Self.entries() where entry.model["error"] == nil {
            let data = try Self.data(entry)
            let end = try XCTUnwrap(entry.model["end"] as? Int)
            for length in 0..<data.count {
                let prefix = data.prefix(length)
                if length >= end {
                    XCTAssertNoThrow(try MDLReader.read(prefix), "\(entry.file) cut to its end + fill")
                    continue
                }
                XCTAssertThrowsError(try MDLReader.read(prefix), "\(entry.file) cut to \(length)") { error in
                    // A cut can land inside a length that then points past the new end.
                    let kind = MDLReferenceDump.kind(of: error)
                    XCTAssert(kind == "truncated" || kind == "malformed", "\(entry.file) cut to \(length): \(error)")
                }
            }
        }
    }

    /// Random corruption never crashes or hangs the reader: it throws or returns a model.
    func testCorruptedModelsNeverCrash() throws {
        var generator = SplitMix64(seed: 0x6d646c)
        for entry in try Self.entries() {
            let original = [UInt8](try Self.data(entry))
            guard !original.isEmpty else { continue }
            for _ in 0..<400 {
                var bytes = original
                for _ in 0..<(1 + Int(generator.next() % 4)) {
                    let index = Int(generator.next() % UInt64(bytes.count))
                    // Big values in count and length fields are the dangerous ones.
                    bytes[index] = generator.next() % 3 == 0 ? 0xff : UInt8(truncatingIfNeeded: generator.next())
                }
                _ = try? MDLReader.read(Data(bytes)) // either outcome is fine; the test is that it returns
            }
        }
    }

    // MARK: - Values

    func testTheAttributeTableIsWEs() {
        XCTAssertEqual(MDLVertexAttribute.all.count, 26)
        XCTAssertEqual(MDLVertexFormat.knownBits, 0x3ff_ffff)
        XCTAssertEqual(Set(MDLVertexAttribute.all.map(\.mask)).count, 26)
        // The library's formats (docs/models-plan.md §1.2) and their strides.
        let formats: [UInt32: (names: [String], stride: Int)] = [
            0xf: (["a_Position", "a_Normal", "a_Tangent4", "a_TexCoord"], 48),
            0x180000f: (["a_Position", "a_Normal", "a_Tangent4", "a_BlendIndices", "a_BlendWeights", "a_TexCoord"], 80),
            0x1800009: (["a_Position", "a_BlendIndices", "a_BlendWeights", "a_TexCoord"], 52),
            0x9: (["a_Position", "a_TexCoord"], 20),
            0xb: (["a_Position", "a_Normal", "a_TexCoord"], 32),
            0x27: (["a_Position", "a_Normal", "a_Tangent4", "a_TexCoordVec4"], 56),
        ]
        for (raw, expected) in formats {
            let format = MDLVertexFormat(rawValue: raw)
            XCTAssertEqual(format.elements.map(\.attribute.name), expected.names, format.description)
            XCTAssertEqual(format.stride, expected.stride, format.description)
        }
        let every = MDLVertexFormat(rawValue: MDLVertexFormat.knownBits)
        XCTAssertEqual(every.elements.last?.attribute, .color, "a_Color is last")
        XCTAssertEqual(every.offset(of: .blendIndices), 12 + 16 + 12 + 12 + 16)
        XCTAssertEqual(MDLVertexAttribute.blendIndices.componentType, .uint32)
    }

    func testVertexAttributesDecode() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        let mesh = try XCTUnwrap(model.meshes.first)
        XCTAssertEqual(mesh.format.rawValue, 0x1800009)
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssert(mesh.isSkinned)
        XCTAssertEqual(mesh.unsignedValues(.blendIndices)?.prefix(8), [0, 1, 0, 1, 1, 2, 0, 1])
        XCTAssertEqual(mesh.floatValues(.blendWeights)?.prefix(4), [0.5, 0.25, 0.125, 0.125])
        XCTAssertEqual(mesh.floatValues(.position)?.count, 12)
        XCTAssertNil(mesh.floatValues(.normal))
        XCTAssertEqual(mesh.indices, [0, 1, 2, 2, 3, 0])
        XCTAssertFalse(mesh.usesUInt32Indices)
        let wide = try MDLModel(contentsOf: Fixtures.url("Models/v17-bounds.mdl")).meshes[0]
        XCTAssert(wide.usesUInt32Indices)
        XCTAssertEqual(wide.indices, [0, 1, 2])
        XCTAssertEqual(wide.flagsExtra, 0xabcd)
    }

    /// WE's model box: the union of the mesh boxes, or ±131072 when it is empty (before MDLV 17
    /// every mesh box is zero).
    func testModelBounds() throws {
        let bounded = try MDLModel(contentsOf: Fixtures.url("Models/v17-bounds.mdl"))
        XCTAssertEqual(bounded.bounds, MDLBounds(min: SIMD3(-7, -2, -3), max: SIMD3(4, 8, 9)))
        XCTAssertEqual(try MDLModel(contentsOf: Fixtures.url("Models/v4-static.mdl")).bounds, .unbounded)
        XCTAssertEqual(MDLBounds.union(of: []), .unbounded)
        let flat = MDLBounds(min: SIMD3(1, 0, 0), max: SIMD3(1, 5, 5))
        XCTAssertEqual(MDLBounds.union(of: [flat]), .unbounded, "valid only when max.x > min.x")
    }

    /// A pose's rotation is q = qz·qy·qx: it rotates like Rz·Ry·Rx, X first.
    func testPoseRotationIsZYX() {
        let euler = SIMD3<Float>(-0.111, 1.175, 0.971)
        let pose = MDLBonePose(position: .zero, euler: euler, scale: .one)
        let expected = simd_quatf(angle: euler.z, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: euler.y, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: euler.x, axis: SIMD3(1, 0, 0))
        XCTAssertEqual(simd_dot(pose.rotation.vector, expected.vector), 1, accuracy: 1e-6)
        let vector = SIMD3<Float>(0.3, -0.2, 0.9)
        let x = simd_quatf(angle: euler.x, axis: SIMD3(1, 0, 0)).act(vector)
        let xy = simd_quatf(angle: euler.y, axis: SIMD3(0, 1, 0)).act(x)
        let xyz = simd_quatf(angle: euler.z, axis: SIMD3(0, 0, 1)).act(xy)
        XCTAssertLessThan(simd_distance(pose.rotation.act(vector), xyz), 1e-5)
    }

    func testClipsSkeletonAndSections() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v19-skeleton.mdl"))
        let skeleton = try XCTUnwrap(model.skeleton)
        XCTAssertEqual(skeleton.bones.map(\.name), ["root", "arm", "hand"])
        XCTAssertEqual(skeleton.bones.map(\.parentIndex), [nil, 0, 1])
        XCTAssertEqual(skeleton.bones[1].matrix.columns.3, SIMD4(1, 2, 0, 1), "translation in elements 12…14")
        let world = skeleton.bindPoseWorldMatrices
        XCTAssertEqual(world[2].columns.3.x, 1 + cos(0.5) * 0.5, accuracy: 1e-6)
        XCTAssertEqual(world[2].columns.3.y, 2 + sin(0.5) * 0.5, accuracy: 1e-6)

        let clips = try XCTUnwrap(model.animations)
        XCTAssertEqual(clips.map(\.mode), [.loop, .single])
        XCTAssertEqual(clips[0].duration, 0.1, accuracy: 1e-7)
        XCTAssertEqual(clips[0].boneTracks.count, 3)
        XCTAssertEqual(clips[0].boneTracks[1].samples.count, 9 * 4)
        let pose = clips[0].boneTracks[1].pose(at: 2)
        XCTAssertEqual(pose.position, SIMD3(3, 1.5, -3))
        XCTAssertLessThan(simd_distance(pose.euler, SIMD3(0.3, -0.6, 0.9)), 1e-6)
        XCTAssertLessThan(simd_distance(pose.scale, SIMD3(1.03, 1, 0.97)), 1e-6)
        XCTAssertEqual(clips[1].boneTracks.map(\.isDisabled), [true, false, false])
        XCTAssertEqual(clips[1].reference?.animation, 0)
        XCTAssertEqual(clips[0].events, [.init(frame: 1.5, name: "step")])
        XCTAssertEqual(model.animation(id: 2)?.name, "wave")
        XCTAssertEqual(MDLAnimation.Mode(name: "pingpong"), .loop, "an unknown mode loops")

        let full = try MDLModel(contentsOf: Fixtures.url("Models/v23-full.mdl"))
        XCTAssertEqual(full.sections.map(\.tag), ["MDLS0004", "MDAT0001", "MDLA0006", "MDMP0001", "MDLE0002"])
        XCTAssertEqual(full.attachment(named: "правая рука")?.bone, 2)
        XCTAssertEqual(full.referencePose?.count, 3)
        let morphs = try XCTUnwrap(full.morphTargets?.first)
        XCTAssertEqual(morphs.targets.map(\.name), ["shape0", "shape1"])
        // The fixture's writer stored the halves of −1, −0.5 and 0 (0xBC00, 0xB800, 0); WE reads
        // the bits as signed normalised values.
        let expected: [Float] = [0xBC00, 0xB800, 0].map { MDLMorphTargets.float(snormBits: $0) }
        XCTAssertEqual(Array(morphs.targets[1].positions.prefix(3)), expected)
        XCTAssertEqual(morphs.targets[0].modifier, .init(bone: 1, mode: 2, startDistance: 0.5, endDistance: 4))
        XCTAssertEqual(full.meshes[0].groups?.first?.id, 0x1122_3344_5566_7788)

        let skipped = try MDLModel(contentsOf: Fixtures.url("Models/v14-unknown-section.mdl"))
        XCTAssertEqual(skipped.sections.map(\.skipped), [true])
        let puppet = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        XCTAssertEqual(puppet.trailingByteCount, 64, "fill after the end is kept out of the model")
    }

    /// WE reads a newer version of a known section as the newest it knows and skips the rest, and
    /// never looks past the terminating tag.
    func testSkippedBytesAreWEs() throws {
        var bytes = [UInt8](try Fixtures.data("Models/v14-unknown-section.mdl"))
        bytes += [0x12, 0x34]
        XCTAssertEqual(try MDLReader.read(Data(bytes)).trailingByteCount, 2)
        XCTAssertEqual(MDLReader.version(ofTag: ArraySlice(Array("MDLA0007".utf8))), 7)
        XCTAssertEqual(MDLReader.version(ofTag: ArraySlice(Array("MDLV".utf8))), 0)
        XCTAssertEqual(MDLReader.version(ofTag: ArraySlice(Array("MDLS12x".utf8))), 12)
    }

    /// `MDMP` deltas are 16-bit signed normalised values (WE's RGBA16 SNORM morph textures).
    func testSnormDeltas() {
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0x7fff), 1)
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0x8001), -1)
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0x8000), -1)
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0), 0)
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0x4000), 16384.0 / 32767, accuracy: 1e-7)
    }

    // MARK: - Loading

    /// A model is read from the wallpaper's package first, else from its folder.
    func testLoadsFromThePackageOrTheFolder() throws {
        let fixture = try Fixtures.data("Models/v4-static.mdl")
        let package = try PKGParser(data: Self.package(["models\\mesh.mdl": fixture, "scene.json": Data("{}".utf8)]))
        let fromPackage = try MDLModel.load(path: "models/mesh.mdl", package: package, directory: Fixtures.url("Models"))
        XCTAssertEqual(fromPackage, try MDLModel(data: fixture))
        let loose = try MDLModel.load(path: "v13-puppet.mdl", package: package, directory: Fixtures.url("Models"))
        XCTAssertEqual(loose.version, 13)
        XCTAssertThrowsError(try MDLModel.load(path: "models/none.mdl", package: nil, directory: Fixtures.url("Models"))) {
            XCTAssertEqual($0 as? MDLError, .missing(path: "models/none.mdl"))
        }
    }

    /// A `PKGV0001` archive of `files`.
    static func package(_ files: [String: Data]) -> Data {
        var header = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        u32(8)
        header.append(contentsOf: Array("PKGV0001".utf8))
        u32(files.count)
        var body = Data()
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            u32(name.utf8.count)
            header.append(contentsOf: Array(name.utf8))
            u32(body.count)
            u32(data.count)
            body.append(data)
        }
        return header + body
    }
}

/// A small deterministic generator for the corruption test.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
