import CoreGraphics
import ImageIO
import XCTest
@testable import OWESceneEditing

/// WE 2.8.0.42 capture 544: Normal map › Generate at the defaults on 509's bars picture
/// (`Tests/Fixtures/NormalMap544`, 512 × 256, a red and a blue bar with black ticks on
/// transparency), and the map WE wrote (`variant_a_normal.png`).
final class NormalMapCapture544Tests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/NormalMap544", directoryHint: .isDirectory)

    static func image(_ name: String) throws -> RGBAImage {
        let url = folder.appending(path: name)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(RGBAImage(cgImage))
    }

    struct Errors {
        var mean = SIMD3<Double>(repeating: 0)
        var max = SIMD3<Int>(repeating: 0)
        var count = 0
        var worst = (x: 0, y: 0)
    }

    /// Per-channel errors over the picture's opaque pixels.
    static func errors(_ ours: RGBAImage, _ theirs: RGBAImage, source: RGBAImage) -> Errors {
        var result = Errors()
        var sum = SIMD3<Double>(repeating: 0)
        var worstSum = -1
        for y in 0..<ours.height {
            for x in 0..<ours.width {
                let index = (y * ours.width + x) * 4
                guard source.pixels[index + 3] == 255 else { continue }
                var total = 0
                for channel in 0..<3 {
                    let error = abs(Int(ours.pixels[index + channel]) - Int(theirs.pixels[index + channel]))
                    sum[channel] += Double(error)
                    result.max[channel] = Swift.max(result.max[channel], error)
                    total += error
                }
                if total > worstSum { worstSum = total; result.worst = (x, y) }
                result.count += 1
            }
        }
        result.mean = sum / Double(Swift.max(result.count, 1))
        return result
    }

    /// OWE's map at the defaults against WE's, over the picture's opaque pixels (21 600). Red and
    /// green are what the RG88 texture keeps (blue is rebuilt in the shader). They agree to well
    /// under a step on average; what differs is a 2–3 px line where a bar's colour meets its
    /// black tick (the details' edge, up to 19 in red and 43 in green there).
    func testTheDefaultsMakeWEsMap() throws {
        let source = try Self.image("source_bars.png")
        let theirs = try Self.image("variant_a_normal.png")
        let ours = NormalMapGenerator.generate(source, settings: NormalMapGenerator.Settings())
        if let out = ProcessInfo.processInfo.environment["OWE_NORMAL_OUT"], let png = ours.pngData {
            try png.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertEqual(ours.width, theirs.width)
        XCTAssertEqual(ours.height, theirs.height)
        let errors = Self.errors(ours, theirs, source: source)
        XCTAssertEqual(errors.count, 21600)
        XCTAssertLessThan(errors.mean.x, 0.5, "red: \(errors.mean)")
        XCTAssertLessThan(errors.mean.y, 1.0, "green: \(errors.mean)")
        XCTAssertLessThan(errors.mean.z, 1.5, "blue: \(errors.mean)")
        var off = 0
        for index in stride(from: 0, to: ours.pixels.count, by: 4) where source.pixels[index + 3] == 255 {
            if abs(Int(ours.pixels[index]) - Int(theirs.pixels[index])) > 4
                || abs(Int(ours.pixels[index + 1]) - Int(theirs.pixels[index + 1])) > 4 { off += 1 }
            XCTAssertEqual(ours.pixels[index + 3], theirs.pixels[index + 3], "alpha is the picture's")
        }
        XCTAssertLessThan(Double(off) / Double(errors.count), 0.04, "\(off) pixels more than 4 off in red or green")
        // WE's samples: flat (127, 126, 254) in the middle, +x to the right, +y up (OpenGL).
        for (x, y, red, green) in [(130, 128, 127, 126), (218, 128, 229, 127), (130, 99, 127, 229),
                                   (130, 156, 127, 26), (380, 128, 127, 126), (42, 128, 1, 127)] {
            let index = (y * ours.width + x) * 4
            XCTAssertEqual(Double(ours.pixels[index]), Double(red), accuracy: 2, "red at (\(x), \(y))")
            XCTAssertEqual(Double(ours.pixels[index + 1]), Double(green), accuracy: 2, "green at (\(x), \(y))")
        }
    }
}
