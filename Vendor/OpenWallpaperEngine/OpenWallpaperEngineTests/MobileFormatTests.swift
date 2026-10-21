import Compression
import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// The pieces of WE's mobile export format: its JSON writer, ETC2 textures, LZ4 blocks, the
/// `.tex` conversion and the shader edits.
final class MobileFormatTests: XCTestCase {
    // MARK: JSON

    func testJSONIsWrittenAsWEWritesIt() throws {
        let source = #"{"z": 1, "general": {"fov": 50.0, "nearz": 0.009999999776482582, "bloom": false, "size": [], "projection": {"width": 1920}}, "tags": ["Medieval"], "name": "Über \"x\"\n", "textures": [null, "util/noise", "masks/pulse_mask_c90fdc1ddc49389266e4c73cc937c1a5dcb82f25"], "objects": [{"id": 13}]}"#
        let written = WEJSONWriter.data(try WEJSONDocument(parsing: Data(source.utf8)))
        let expected = [
            "{",
            "\t\"general\" : ",
            "\t{",
            "\t\t\"bloom\" : false,",
            "\t\t\"fov\" : 50.0,",
            "\t\t\"nearz\" : 0.0099999998,",
            "\t\t\"projection\" : ",
            "\t\t{",
            "\t\t\t\"width\" : 1920",
            "\t\t},",
            "\t\t\"size\" : []",
            "\t},",
            "\t\"name\" : \"\\u00dcber \\\"x\\\"\\n\",",
            "\t\"objects\" : ",
            "\t[",
            "\t\t{",
            "\t\t\t\"id\" : 13",
            "\t\t}",
            "\t],",
            "\t\"tags\" : [ \"Medieval\" ],",
            "\t\"textures\" : ",
            "\t[",
            "\t\tnull,",
            "\t\t\"util/noise\",",
            "\t\t\"masks/pulse_mask_c90fdc1ddc49389266e4c73cc937c1a5dcb82f25\"",
            "\t],",
            "\t\"z\" : 1",
            "}",
        ].joined(separator: "\r\n")
        XCTAssertEqual(String(decoding: written, as: UTF8.self), expected)
    }

    func testRealsHaveEightSignificantDigits() {
        XCTAssertEqual(WEJSONWriter.real(Double(Float(0.65))), "0.64999998")
        XCTAssertEqual(WEJSONWriter.real(Double(Float(1.619))), "1.619")
        XCTAssertEqual(WEJSONWriter.real(2), "2.0")
        XCTAssertEqual(WEJSONWriter.real(10_000), "10000.0")
        XCTAssertEqual(WEJSONWriter.real(1e-5), "1e-05")
    }

    // MARK: ETC2

    func testOpaqueAlphaBlockIsWEs() {
        var block = ETC2Encoder.Block()
        block.a = [Int](repeating: 255, count: 16)
        XCTAssertEqual(ETC2Encoder.alphaBlock(block), 0xFF00_0000_0000_0000, "alpha 255, multiplier 0, as WE writes it")
    }

    func testETC2EncodesAPictureClosely() {
        let width = 64, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                pixels[p] = UInt8(x * 4)
                pixels[p + 1] = UInt8(y * 8)
                pixels[p + 2] = x < 40 ? 200 : 30
                pixels[p + 3] = x < 32 ? 255 : UInt8(y * 8)
            }
        }
        let blocks = ETC2Encoder.encode(pixels, width: width, height: height)
        XCTAssertEqual(blocks.count, width * height)
        let decoded = ETC2TestDecoder.decode(blocks, width: width, height: height)
        var error = 0.0
        for index in 0..<pixels.count { error += pow(Double(pixels[index]) - Double(decoded[index]), 2) }
        let psnr = 10 * log10(255 * 255 / (error / Double(pixels.count)))
        XCTAssertGreaterThan(psnr, 32, "PSNR \(psnr)")
    }

    func testPlanarWordsDecodeAsPlanar() {
        var block = ETC2Encoder.Block()
        for k in 0..<16 {
            block.r[k] = (k / 4) * 60; block.g[k] = (k % 4) * 60; block.b[k] = 255 - (k / 4) * 40; block.a[k] = 255
        }
        let word = ETC2Encoder.colorBlock(block)
        XCTAssertTrue(ETC2Encoder.isPlanar(word), "a smooth gradient takes the planar mode")
    }

    // MARK: LZ4

    func testLZ4BlocksDecodeWithTheSystemDecoder() {
        for input in [[UInt8](), [1, 2, 3], [UInt8](repeating: 9, count: 100_000),
                      (0..<200_000).map { UInt8(truncatingIfNeeded: ($0 / 7) &* 13 ^ $0 % 251) }] {
            let compressed = LZ4BlockEncoder.compress(input)
            var output = [UInt8](repeating: 0, count: max(input.count, 1))
            let written = compression_decode_buffer(&output, input.count, compressed, compressed.count, nil, COMPRESSION_LZ4_RAW)
            XCTAssertEqual(written, input.count)
            XCTAssertEqual(Array(output.prefix(input.count)), input)
        }
    }

    // MARK: Textures

    /// WE's sizes: 1931×1772 → mipmap 968×888, texture 1937×1776; 965×886 → 484×444, 969×888.
    func testReducedSizesAreWEs() {
        for (image, mipmap, texture) in [(1931, 968, 1937), (1772, 888, 1776), (965, 484, 969), (886, 444, 888), (1920, 960, 1920), (1080, 540, 1080)] {
            let side = MobileTextureConverter.reducedSide(image, reduction: 2)
            XCTAssertEqual(side.mipmap, mipmap, "\(image)")
            XCTAssertEqual(MobileTextureConverter.textureSide(image: image, mipmap: side.mipmap, reduction: 2), texture, "\(image)")
        }
        XCTAssertEqual(MobileTextureConverter.reducedSide(1931, reduction: 1).mipmap, 1932)
    }

    private static func rawTex(format: UInt32, flags: UInt32, width: Int, height: Int, bytesPerPixel: Int) -> Data {
        var data = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0])
        for value in [format, flags, UInt32(width), UInt32(height), UInt32(width), UInt32(height), 0xFF36_7070] { word(value) }
        data.append(contentsOf: Array("TEXB0003".utf8) + [0])
        word(1); word(UInt32(bitPattern: -1)); word(1)
        let size = width * height * bytesPerPixel
        word(UInt32(width)); word(UInt32(height)); word(0); word(UInt32(size)); word(UInt32(size))
        data.append(Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }))
        return data
    }

    /// Runs `work` off the main thread (the converter's thread guard), and returns what it returns.
    private func offMain<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = Result { try work() }
            done.signal()
        }
        done.wait()
        return try XCTUnwrap(result).get()
    }

    /// A raw RGBA8888 texture keeps its pixels in a TEXB0004 container, flag 0x8 when it is only a
    /// pass's second texture (WE's `waterflowphase.tex`, byte for byte).
    func testRawRGBAIsRecontainered() throws {
        let source = Self.rawTex(format: 0, flags: 0, width: 32, height: 32, bytesPerPixel: 4)
        let converted = try offMain { try MobileTextureConverter.convert(source, path: "phase.tex", reduction: 2, pixelArt: false, secondary: true) }
        var expected = source
        let container = try XCTUnwrap(expected.range(of: Data("TEXB0003".utf8)))
        expected.replaceSubrange(container, with: Data("TEXB0004".utf8))
        expected.insert(contentsOf: [0, 0, 0, 0], at: container.upperBound + 1 + 8)
        expected[22] |= 0x8
        XCTAssertEqual(converted, expected)
    }

    func testChannelReducedTexturesAreCopied() throws {
        for format: UInt32 in [8, 9] {
            let source = Self.rawTex(format: format, flags: 2, width: 64, height: 32, bytesPerPixel: format == 8 ? 2 : 1)
            XCTAssertEqual(try offMain { try MobileTextureConverter.convert(source, path: "mask.tex", reduction: 2, pixelArt: false, secondary: true) }, source)
        }
    }

    // MARK: Shaders

    /// WE's edits to a Workshop scene's shaders, line by line.
    func testShaderEditsAreWEs() {
        let cases = [
            ("\tvec4 sample = texSample2D(g_Texture0, v_TexCoord.xy);", "\tvec4 _sample = texSample2D(g_Texture0, v_TexCoord.xy);"),
            ("\talbedo = mix(sample, albedo, mask);", "\talbedo = mix(_sample, albedo, mask);"),
            ("\tgl_FragColor = vec4(max(CAST3(0), albedo.rgb), albedo.a);", "\tgl_FragColor = vec4(max(CAST3(0.0), albedo.rgb), albedo.a);"),
            ("\tv_Direction = rotateVec2(vec2(0, 1), g_Direction);", "\tv_Direction = rotateVec2(vec2(0.0, 1.0), g_Direction);"),
            ("\tfloat blend = 2 * abs(cycles.x - 0.5);", "\tfloat blend = 2.0 * abs(cycles.x - 0.5);"),
            ("#if MASK == 1", "#if MASK == 1"),
            ("uniform float g_AudioSpectrum16Left[16];", "uniform float g_AudioSpectrum16Left[16];"),
            ("\tfor (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)", "\tfor (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)"),
            ("\tfloat x = values[2] * 3;", "\tfloat x = values[2] * 3.0;"),
            ("uniform sampler2D g_Texture1; // {\"default\":\"util/noise\",\"sample\":1}", "uniform sampler2D g_Texture1; // {\"default\":\"util/noise\",\"sample\":1}"),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(MobileShaderCompatibility.rewriteLine(source), expected)
        }
        XCTAssertEqual(MobileShaderCompatibility.rewrite("a\r\nvec2 v = vec2(1, 2);\r\n"), "a\r\nvec2 v = vec2(1.0, 2.0);\r\n")
    }
}

extension ETC2TestDecoder {
    /// Peak signal-to-noise ratio of `a` against `b`, in dB.
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var error = 0.0
        for index in 0..<min(a.count, b.count) { error += pow(Double(a[index]) - Double(b[index]), 2) }
        return 10 * log10(255 * 255 / max(error / Double(min(a.count, b.count)), 1e-9))
    }
}

/// An ETC2 RGBA8 decoder (every colour mode, EAC alpha), for checking encoded blocks.
enum ETC2TestDecoder {
    static func decode(_ blocks: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let columns = width / 4
        for row in 0..<(height / 4) {
            for column in 0..<columns {
                let offset = (row * columns + column) * 16
                func word(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(blocks[at + $1]) } }
                let alpha = alphaBlock(word(offset)), color = colorBlock(word(offset + 8))
                for k in 0..<16 {
                    let x = column * 4 + k / 4, y = row * 4 + k % 4, p = (y * width + x) * 4
                    output[p] = UInt8(color[k].0); output[p + 1] = UInt8(color[k].1); output[p + 2] = UInt8(color[k].2)
                    output[p + 3] = UInt8(alpha[k])
                }
            }
        }
        return output
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }

    static func alphaBlock(_ word: UInt64) -> [Int] {
        let base = Int(word >> 56), multiplier = Int(word >> 52 & 15), table = ETC2Encoder.alphaModifiers[Int(word >> 48 & 15)]
        return (0..<16).map { k in clamp(base + table[Int(word >> UInt64(45 - 3 * k) & 7)] * multiplier) }
    }

    static func colorBlock(_ word: UInt64) -> [(Int, Int, Int)] {
        func signed3(_ value: UInt64) -> Int { let v = Int(value & 7); return v > 3 ? v - 8 : v }
        func index(_ k: Int) -> Int { Int(word >> UInt64(16 + k) & 1) << 1 | Int(word >> UInt64(k) & 1) }
        let e4 = ETC2Encoder.e4, e5 = ETC2Encoder.e5, e6 = ETC2Encoder.e6, e7 = ETC2Encoder.e7
        let distances = [3, 6, 11, 16, 23, 32, 41, 64]
        let differential = word >> 33 & 1 == 1, flip = word >> 32 & 1 == 1
        var bases: [(Int, Int, Int)]
        if differential {
            let r = Int(word >> 59 & 31), g = Int(word >> 51 & 31), b = Int(word >> 43 & 31)
            let dr = signed3(word >> 56), dg = signed3(word >> 48), db = signed3(word >> 40)
            if !(0...31).contains(r + dr) {
                let c1 = (e4(Int((word >> 59 & 3) << 2 | word >> 56 & 3)), e4(Int(word >> 52 & 15)), e4(Int(word >> 48 & 15)))
                let c2 = (e4(Int(word >> 44 & 15)), e4(Int(word >> 40 & 15)), e4(Int(word >> 36 & 15)))
                let d = distances[Int((word >> 34 & 3) << 1 | word >> 32 & 1)]
                let palette = [c1, (clamp(c2.0 + d), clamp(c2.1 + d), clamp(c2.2 + d)), c2, (clamp(c2.0 - d), clamp(c2.1 - d), clamp(c2.2 - d))]
                return (0..<16).map { palette[index($0)] }
            }
            if !(0...31).contains(g + dg) {
                let c1 = (e4(Int(word >> 59 & 15)), e4(Int((word >> 56 & 7) << 1 | word >> 52 & 1)), e4(Int((word >> 51 & 1) << 3 | word >> 47 & 7)))
                let c2 = (e4(Int(word >> 43 & 15)), e4(Int(word >> 39 & 15)), e4(Int(word >> 35 & 15)))
                let v1 = c1.0 << 16 | c1.1 << 8 | c1.2, v2 = c2.0 << 16 | c2.1 << 8 | c2.2
                let d = distances[Int((word >> 34 & 1) << 2 | (word >> 32 & 1) << 1) | (v1 >= v2 ? 1 : 0)]
                let palette = [(clamp(c1.0 + d), clamp(c1.1 + d), clamp(c1.2 + d)), (clamp(c1.0 - d), clamp(c1.1 - d), clamp(c1.2 - d)),
                               (clamp(c2.0 + d), clamp(c2.1 + d), clamp(c2.2 + d)), (clamp(c2.0 - d), clamp(c2.1 - d), clamp(c2.2 - d))]
                return (0..<16).map { palette[index($0)] }
            }
            if !(0...31).contains(b + db) {
                let ro = e6(Int(word >> 57 & 63)), go = e7(Int((word >> 56 & 1) << 6 | word >> 49 & 63))
                let boHigh: UInt64 = (word >> 48 & 1) << 5, boMiddle: UInt64 = (word >> 43 & 3) << 3
                let bo = e6(Int(boHigh | boMiddle | word >> 39 & 7))
                let rh = e6(Int((word >> 34 & 31) << 1 | word >> 32 & 1)), gh = e7(Int(word >> 25 & 127)), bh = e6(Int(word >> 19 & 63))
                let rv = e6(Int(word >> 13 & 63)), gv = e7(Int(word >> 6 & 127)), bv = e6(Int(word & 63))
                return (0..<16).map { k in
                    let x = k / 4, y = k % 4
                    func value(_ o: Int, _ h: Int, _ v: Int) -> Int { clamp((x * (h - o) + y * (v - o) + 4 * o + 2) >> 2) }
                    return (value(ro, rh, rv), value(go, gh, gv), value(bo, bh, bv))
                }
            }
            bases = [(e5(r), e5(g), e5(b)), (e5(r + dr), e5(g + dg), e5(b + db))]
        } else {
            bases = [(e4(Int(word >> 60 & 15)), e4(Int(word >> 52 & 15)), e4(Int(word >> 44 & 15))),
                     (e4(Int(word >> 56 & 15)), e4(Int(word >> 48 & 15)), e4(Int(word >> 40 & 15)))]
        }
        let tables = [Int(word >> 37 & 7), Int(word >> 34 & 7)]
        return (0..<16).map { k in
            let second = flip ? k % 4 >= 2 : k / 4 >= 2
            let pair = ETC2Encoder.modifiers[tables[second ? 1 : 0]]
            let delta = [pair.0, pair.1, -pair.0, -pair.1][index(k)]
            let base = bases[second ? 1 : 0]
            return (clamp(base.0 + delta), clamp(base.1 + delta), clamp(base.2 + delta))
        }
    }
}
