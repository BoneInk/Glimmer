import Accelerate
import simd
import Foundation

/// BC7 compression of colour textures (`TexturePreparation`), with the downsampling that builds
/// their mipmaps and the check that decides whether a compressed texture looks like its source.
///
/// The encoder writes two of BC7's modes. Mode 6: one RGBA line per 4×4 block with 7-bit
/// endpoints, a shared bit each, and 4-bit indices; it fits a line through the block's colours
/// along their principal axis (alpha weighted, `alphaWeight`), then refines the endpoints by least
/// squares from the chosen indices. Mode 1, for opaque blocks mode 6 fits badly: two RGB lines
/// over one of 64 partitions (the four partitions closest to two lines are tried in full). That is
/// 8 bits per texel, a quarter of RGBA8, and Apple GPUs sample it natively. It is weaker than a
/// full BC7 search on semi-transparent edges, so every texture is decoded again and checked
/// (`quality`) before it is used; one that fails stays uncompressed.
enum TextureCompressor {
    /// Changes whenever the encoder's output changes, so older cached blobs are rebuilt.
    static let revision = 2

    /// Error weight per channel: alpha counts more, since an alpha step multiplies the whole
    /// colour (a texel at alpha 0 turning 4/255 shows over dark content, a colour step of 4 barely does).
    private static let errorWeights = SIMD4<Int32>(1, 1, 1, alphaWeight)
    static let alphaWeight: Int32 = 4

    /// BC7 interpolation weights for 4-bit indices.
    private static let weights: [Int32] = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]

    static func blockCount(width: Int, height: Int) -> Int { ((width + 3) / 4) * ((height + 3) / 4) }

    // MARK: Encoding

    /// `rgba` (straight alpha, `rowBytes` per row) as BC7 blocks, row by row of blocks. Blocks run
    /// serially on the calling thread: callers run on the preparation pool, whose library lane
    /// already bounds how many cores compression may use.
    static func encodeBC7(_ rgba: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int) -> [UInt8] {
        let columns = (width + 3) / 4, rows = (height + 3) / 4
        var output = [UInt8](repeating: 0, count: columns * rows * 16)
        output.withUnsafeMutableBytes { target in
            let base = UInt(bitPattern: target.baseAddress)
            for row in 0..<rows {
                let out = UnsafeMutableRawPointer(bitPattern: base)!
                var block = [Int32](repeating: 0, count: 64)
                for column in 0..<columns {
                    for y in 0..<4 {
                        let sy = min(row * 4 + y, height - 1)
                        for x in 0..<4 {
                            let sx = min(column * 4 + x, width - 1)
                            let offset = sy * rowBytes + sx * 4
                            for channel in 0..<4 {
                                block[(y * 4 + x) * 4 + channel] = Int32(rgba[offset + channel])
                            }
                        }
                    }
                    let encoded = encodeBlock(block)
                    let destination = out + (row * columns + column) * 16
                    destination.storeBytes(of: encoded.0.littleEndian, toByteOffset: 0, as: UInt64.self)
                    destination.storeBytes(of: encoded.1.littleEndian, toByteOffset: 8, as: UInt64.self)
                }
            }
        }
        return output
    }

    /// Below this weighted squared error a mode 6 block isn't worth a partition search.
    static let partitionSearchError: Int64 = 16 * 4

    /// One block (16 texels × RGBA, 0…255): mode 6, or for an opaque block that mode 6 fits badly
    /// (two colour regions, as line art has), mode 1 when that fits better.
    static func encodeBlock(_ texels: [Int32]) -> (UInt64, UInt64) {
        let mode6 = fitMode6(texels)
        let opaque = stride(from: 3, to: 64, by: 4).allSatisfy { texels[$0] == 255 }
        guard opaque, mode6.error > partitionSearchError, let mode1 = fitMode1(texels), mode1.error < mode6.error else {
            return pack(mode6)
        }
        return packMode1(mode1)
    }

    /// One block as a mode 6 block (low, high 64 bits).
    static func encodeMode6(_ texels: [Int32]) -> (UInt64, UInt64) { pack(fitMode6(texels)) }

    private static func fitMode6(_ texels: [Int32]) -> Fit {
        var mean = SIMD4<Float>.zero
        var points = [SIMD4<Float>](repeating: .zero, count: 16)
        for index in 0..<16 {
            let point = SIMD4<Float>(Float(texels[index * 4]), Float(texels[index * 4 + 1]),
                                     Float(texels[index * 4 + 2]), Float(texels[index * 4 + 3]))
            points[index] = point
            mean += point
        }
        mean /= 16
        // Principal axis by power iteration on the covariance.
        var covariance = simd_float4x4()
        // The axis is found in the weighted space the error is measured in.
        let scale = SIMD4<Float>(1, 1, 1, Float(alphaWeight).squareRoot())
        for point in points {
            let d = (point - mean) * scale
            covariance.columns.0 += d * d.x
            covariance.columns.1 += d * d.y
            covariance.columns.2 += d * d.z
            covariance.columns.3 += d * d.w
        }
        var axis = SIMD4<Float>(0.577, 0.577, 0.577, 0.1)
        for _ in 0..<6 {
            let next = covariance * axis
            let length = simd_length(next)
            if length < 1e-6 { break }
            axis = next / length
        }
        axis = axis / scale
        axis /= max(simd_length(axis), 1e-6)
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for point in points {
            let t = simd_dot(point - mean, axis)
            low = min(low, t)
            high = max(high, t)
        }
        if low > high { low = 0; high = 0 }
        var best = quantize(endpoints: (mean + axis * low, mean + axis * high), points: points)
        // Least-squares refinement of the endpoints from the chosen indices.
        for _ in 0..<3 {
            guard let refined = leastSquares(points: points, indices: best.indices) else { break }
            let candidate = quantize(endpoints: refined, points: points)
            if candidate.error < best.error { best = candidate } else { break }
        }
        return best
    }

    private struct Fit {
        var e0: SIMD4<Int32>   // 7-bit
        var e1: SIMD4<Int32>
        var p0: Int32
        var p1: Int32
        var indices: [Int]
        var error: Int64
    }

    /// The endpoints rounded to 7 bits under each of the four shared-bit pairs, keeping the pair
    /// whose indices give the least error. A block that is opaque keeps alpha exactly 255.
    private static func quantize(endpoints: (SIMD4<Float>, SIMD4<Float>), points: [SIMD4<Float>]) -> Fit {
        func rounded(_ value: SIMD4<Float>, _ p: Int32) -> SIMD4<Int32> {
            var q = SIMD4<Int32>.zero
            for c in 0..<4 { q[c] = Int32(min(127, max(0, ((value[c] - Float(p)) / 2).rounded()))) }
            return q
        }
        let opaque = points.allSatisfy { $0.w >= 255 }
        var best: Fit?
        for p0 in Int32(0)...1 {
            for p1 in Int32(0)...1 {
                if opaque && (p0 == 0 || p1 == 0) { continue }
                var fit = Fit(e0: rounded(endpoints.0, p0), e1: rounded(endpoints.1, p1), p0: p0, p1: p1,
                              indices: [Int](repeating: 0, count: 16), error: 0)
                if opaque { fit.e0.w = 127; fit.e1.w = 127 }
                assignIndices(&fit, points: points)
                if best == nil || fit.error < best!.error { best = fit }
            }
        }
        return best!
    }

    private static func palette(_ fit: Fit) -> [SIMD4<Int32>] {
        let a = fit.e0 &<< 1 | SIMD4(repeating: fit.p0)
        let b = fit.e1 &<< 1 | SIMD4(repeating: fit.p1)
        return weights.map { w in ((64 &- w) &* a &+ w &* b &+ 32) &>> 6 }
    }

    private static func assignIndices(_ fit: inout Fit, points: [SIMD4<Float>]) {
        let colours = palette(fit)
        var total: Int64 = 0
        for (index, point) in points.enumerated() {
            let p = SIMD4<Int32>(Int32(point.x), Int32(point.y), Int32(point.z), Int32(point.w))
            var bestIndex = 0
            var bestError = Int32.max
            for (candidate, colour) in colours.enumerated() {
                let d = colour &- p
                let error = (d &* d &* errorWeights).wrappedSum()
                if error < bestError { bestError = error; bestIndex = candidate }
            }
            fit.indices[index] = bestIndex
            total += Int64(bestError)
        }
        fit.error = total
    }

    private static func leastSquares(points: [SIMD4<Float>], indices: [Int]) -> (SIMD4<Float>, SIMD4<Float>)? {
        var aa: Float = 0, bb: Float = 0, ab: Float = 0
        var ax = SIMD4<Float>.zero, bx = SIMD4<Float>.zero
        for (index, point) in points.enumerated() {
            let t = Float(weights[indices[index]]) / 64
            let s = 1 - t
            aa += s * s; bb += t * t; ab += s * t
            ax += point * s; bx += point * t
        }
        let determinant = aa * bb - ab * ab
        guard abs(determinant) > 1e-6 else { return nil }
        let e0 = (ax * bb - bx * ab) / determinant
        let e1 = (bx * aa - ax * ab) / determinant
        return (simd_clamp(e0, .zero, SIMD4(repeating: 255)), simd_clamp(e1, .zero, SIMD4(repeating: 255)))
    }

    /// Mode 6's bit layout: mode (7 bits, 0b1000000), R0 R1 G0 G1 B0 B1 A0 A1 (7 bits each), P0,
    /// P1, then the indices (4 bits, the first 3: its top bit is implied 0).
    private static func pack(_ input: Fit) -> (UInt64, UInt64) {
        var fit = input
        if fit.indices[0] >= 8 {
            swap(&fit.e0, &fit.e1)
            swap(&fit.p0, &fit.p1)
            fit.indices = fit.indices.map { 15 - $0 }
        }
        var writer = BitWriter()
        writer.write(1 << 6, bits: 7)
        for channel in 0..<4 {
            writer.write(UInt64(fit.e0[channel]), bits: 7)
            writer.write(UInt64(fit.e1[channel]), bits: 7)
        }
        writer.write(UInt64(fit.p0), bits: 1)
        writer.write(UInt64(fit.p1), bits: 1)
        for (position, index) in fit.indices.enumerated() {
            writer.write(UInt64(index), bits: position == 0 ? 3 : 4)
        }
        return (writer.low, writer.high)
    }

    private struct BitWriter {
        var low: UInt64 = 0
        var high: UInt64 = 0
        var position = 0

        mutating func write(_ value: UInt64, bits: Int) {
            for bit in 0..<bits where value >> UInt64(bit) & 1 == 1 {
                let at = position + bit
                if at < 64 { low |= 1 << UInt64(at) } else { high |= 1 << UInt64(at - 64) }
            }
            position += bits
        }
    }

    // MARK: Decoding (mode 6, what the encoder writes)

    /// RGBA8 texels of mode 6 BC7 `blocks` for a `width` × `height` image; other modes decode as
    /// zero (the encoder never writes them).
    static func decodeBC7(_ blocks: UnsafeRawBufferPointer, width: Int, height: Int) -> [UInt8] {
        let columns = (width + 3) / 4, rows = (height + 3) / 4
        var output = [UInt8](repeating: 0, count: width * height * 4)
        output.withUnsafeMutableBytes { target in
            let base = UInt(bitPattern: target.baseAddress)
            for row in 0..<rows {
                let out = UnsafeMutableRawPointer(bitPattern: base)!.assumingMemoryBound(to: UInt8.self)
                for column in 0..<columns {
                    let offset = (row * columns + column) * 16
                    let low = UInt64(littleEndian: blocks.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    let high = UInt64(littleEndian: blocks.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
                    guard let texels = decodeBlock(low: low, high: high) else { continue }
                    for texel in 0..<16 {
                        let x = column * 4 + texel % 4, y = row * 4 + texel / 4
                        guard x < width, y < height else { continue }
                        let colour = texels[texel]
                        let at = (y * width + x) * 4
                        for channel in 0..<4 { out[at + channel] = UInt8(clamping: colour[channel]) }
                    }
                }
            }
        }
        return output
    }

    /// The 16 texels of a mode 6 or mode 1 block; nil for other modes.
    static func decodeBlock(low: UInt64, high: UInt64) -> [SIMD4<Int32>]? {
        func bits(_ start: Int, _ count: Int) -> Int32 {
            var value: UInt64 = 0
            for bit in 0..<count {
                let at = start + bit
                let set = at < 64 ? low >> UInt64(at) & 1 : high >> UInt64(at - 64) & 1
                value |= set << UInt64(bit)
            }
            return Int32(value)
        }
        if low & 0x7F == 1 << 6 {
            var e0 = SIMD4<Int32>.zero, e1 = SIMD4<Int32>.zero
            for channel in 0..<4 {
                e0[channel] = bits(7 + channel * 14, 7)
                e1[channel] = bits(14 + channel * 14, 7)
            }
            let colours = palette(Fit(e0: e0, e1: e1, p0: bits(63, 1), p1: bits(64, 1), indices: [], error: 0))
            var cursor = 65
            return (0..<16).map { texel in
                let count = texel == 0 ? 3 : 4
                defer { cursor += count }
                return colours[Int(bits(cursor, count))]
            }
        }
        if low & 0x3 == 0b10 {
            let partition = Int(bits(2, 6))
            var endpoints = [SIMD4<Int32>](repeating: SIMD4(0, 0, 0, 255), count: 4)
            for channel in 0..<3 {
                for endpoint in 0..<4 { endpoints[endpoint][channel] = bits(8 + channel * 24 + endpoint * 6, 6) }
            }
            let shared = [bits(80, 1), bits(81, 1)]
            let colours = (0..<2).map { subset in
                mode1Palette(endpoints[subset * 2], endpoints[subset * 2 + 1], p: shared[subset])
            }
            var cursor = 82
            let anchor = partitionAnchors[partition]
            return (0..<16).map { texel in
                let count = texel == 0 || texel == anchor ? 2 : 3
                defer { cursor += count }
                return colours[subset(of: texel, partition: partition)][Int(bits(cursor, count))]
            }
        }
        return nil
    }

    // MARK: Mode 1 (two subsets, RGB)

    /// BC7's two-subset partitions: bit `i` is texel `i`'s subset.
    static let partitions: [UInt16] = [
        0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80, 0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00,
        0xFFF0, 0xF000, 0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE, 0x088C, 0x3110, 0x6666, 0x366C,
        0x17E8, 0x0FF0, 0x718E, 0x399C, 0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A, 0x73CE, 0x13C8,
        0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660, 0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
        0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22,
    ]

    /// The texel whose index carries one bit less in each partition's second subset.
    static let partitionAnchors: [Int] = [
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
        15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
        6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
    ]

    private static let mode1Weights: [Int32] = [0, 9, 18, 27, 37, 46, 55, 64]

    static func subset(of texel: Int, partition: Int) -> Int { Int(partitions[partition] >> UInt16(texel) & 1) }

    private static func mode1Palette(_ a6: SIMD4<Int32>, _ b6: SIMD4<Int32>, p: Int32) -> [SIMD4<Int32>] {
        func expand(_ c: SIMD4<Int32>) -> SIMD4<Int32> {
            let seven = c &<< 1 | SIMD4(repeating: p)
            var eight = seven &<< 1 | seven &>> 6
            eight.w = 255
            return eight
        }
        let a = expand(a6), b = expand(b6)
        return mode1Weights.map { w in
            var colour = ((64 &- w) &* a &+ w &* b &+ 32) &>> 6
            colour.w = 255
            return colour
        }
    }

    private struct Mode1Fit {
        var partition: Int
        var endpoints: [SIMD4<Int32>]   // 6-bit RGB: subset 0 (e0, e1), subset 1 (e0, e1)
        var shared: [Int32]
        var indices: [Int]
        var error: Int64
    }

    /// The best mode 1 encoding over the partitions whose subsets lie closest to a line each
    /// (the four with the least residual off their principal axes are encoded in full).
    private static func fitMode1(_ texels: [Int32]) -> Mode1Fit? {
        var points = [SIMD3<Float>](repeating: .zero, count: 16)
        for texel in 0..<16 {
            points[texel] = SIMD3<Float>(Float(texels[texel * 4]), Float(texels[texel * 4 + 1]), Float(texels[texel * 4 + 2]))
        }
        var ranked: [(residual: Float, partition: Int)] = []
        ranked.reserveCapacity(64)
        for partition in 0..<64 {
            var residual: Float = 0
            for subsetIndex in 0..<2 {
                let members = (0..<16).filter { subset(of: $0, partition: partition) == subsetIndex }.map { points[$0] }
                residual += lineResidual(members)
            }
            ranked.append((residual, partition))
        }
        ranked.sort { $0.residual < $1.residual }
        var best: Mode1Fit?
        for candidate in ranked.prefix(4) {
            let fit = fitMode1(points, partition: candidate.partition)
            if best == nil || fit.error < best!.error { best = fit }
        }
        return best
    }

    /// The squared distance of `points` from their principal line.
    private static func lineResidual(_ points: [SIMD3<Float>]) -> Float {
        guard points.count > 1 else { return 0 }
        let line = principalLine(points)
        var residual: Float = 0
        for point in points {
            let d = point - line.mean
            let along = simd_dot(d, line.axis)
            residual += simd_length_squared(d) - along * along
        }
        return residual
    }

    private static func principalLine(_ points: [SIMD3<Float>]) -> (mean: SIMD3<Float>, axis: SIMD3<Float>) {
        var mean = SIMD3<Float>.zero
        for point in points { mean += point }
        mean /= Float(max(points.count, 1))
        var covariance = simd_float3x3()
        for point in points {
            let d = point - mean
            covariance.columns.0 += d * d.x
            covariance.columns.1 += d * d.y
            covariance.columns.2 += d * d.z
        }
        var axis = SIMD3<Float>(0.577, 0.577, 0.577)
        for _ in 0..<6 {
            let next = covariance * axis
            let length = simd_length(next)
            if length < 1e-6 { break }
            axis = next / length
        }
        return (mean, axis)
    }

    private static func fitMode1(_ points: [SIMD3<Float>], partition: Int) -> Mode1Fit {
        var fit = Mode1Fit(partition: partition, endpoints: [SIMD4<Int32>](repeating: .zero, count: 4),
                           shared: [0, 0], indices: [Int](repeating: 0, count: 16), error: 0)
        for subsetIndex in 0..<2 {
            let members = (0..<16).filter { subset(of: $0, partition: partition) == subsetIndex }
            let memberPoints = members.map { points[$0] }
            let line = principalLine(memberPoints)
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for point in memberPoints {
                let t = simd_dot(point - line.mean, line.axis)
                low = min(low, t); high = max(high, t)
            }
            if low > high { low = 0; high = 0 }
            var subsetFit = quantizeMode1((line.mean + line.axis * low, line.mean + line.axis * high), points: memberPoints)
            for _ in 0..<2 {
                guard let refined = leastSquaresMode1(memberPoints, indices: subsetFit.indices) else { break }
                let candidate = quantizeMode1(refined, points: memberPoints)
                if candidate.error < subsetFit.error { subsetFit = candidate } else { break }
            }
            fit.endpoints[subsetIndex * 2] = subsetFit.e0
            fit.endpoints[subsetIndex * 2 + 1] = subsetFit.e1
            fit.shared[subsetIndex] = subsetFit.p
            for (position, texel) in members.enumerated() { fit.indices[texel] = subsetFit.indices[position] }
            fit.error += subsetFit.error
        }
        return fit
    }

    private static func quantizeMode1(_ endpoints: (SIMD3<Float>, SIMD3<Float>), points: [SIMD3<Float>])
        -> (e0: SIMD4<Int32>, e1: SIMD4<Int32>, p: Int32, indices: [Int], error: Int64) {
        var best: (e0: SIMD4<Int32>, e1: SIMD4<Int32>, p: Int32, indices: [Int], error: Int64)?
        for p in Int32(0)...1 {
            func rounded(_ value: SIMD3<Float>) -> SIMD4<Int32> {
                // 8-bit ≈ 7-bit value × 2, so the 6-bit field is (v / 2 - p) / 2.
                var q = SIMD4<Int32>.zero
                for c in 0..<3 { q[c] = Int32(min(63, max(0, ((value[c] / 2 - Float(p)) / 2).rounded()))) }
                return q
            }
            let e0 = rounded(endpoints.0), e1 = rounded(endpoints.1)
            let colours = mode1Palette(e0, e1, p: p)
            var indices = [Int](repeating: 0, count: points.count)
            var error: Int64 = 0
            for (position, point) in points.enumerated() {
                let q = SIMD4<Int32>(Int32(point.x), Int32(point.y), Int32(point.z), 255)
                var bestIndex = 0, bestError = Int32.max
                for (index, colour) in colours.enumerated() {
                    let d = colour &- q
                    let e = (d &* d).wrappedSum()
                    if e < bestError { bestError = e; bestIndex = index }
                }
                indices[position] = bestIndex
                error += Int64(bestError)
            }
            if best == nil || error < best!.error { best = (e0, e1, p, indices, error) }
        }
        return best!
    }

    private static func leastSquaresMode1(_ points: [SIMD3<Float>], indices: [Int]) -> (SIMD3<Float>, SIMD3<Float>)? {
        var aa: Float = 0, bb: Float = 0, ab: Float = 0
        var ax = SIMD3<Float>.zero, bx = SIMD3<Float>.zero
        for (position, point) in points.enumerated() {
            let t = Float(mode1Weights[indices[position]]) / 64, s = 1 - t
            aa += s * s; bb += t * t; ab += s * t
            ax += point * s; bx += point * t
        }
        let determinant = aa * bb - ab * ab
        guard abs(determinant) > 1e-6 else { return nil }
        let e0 = (ax * bb - bx * ab) / determinant, e1 = (bx * aa - ax * ab) / determinant
        return (simd_clamp(e0, .zero, SIMD3(repeating: 255)), simd_clamp(e1, .zero, SIMD3(repeating: 255)))
    }

    /// Mode 1's layout: mode (2 bits, 0b10), partition (6), R G B of the four endpoints (6 bits
    /// each, channel by channel), the two subsets' shared bits, then 3-bit indices (2 bits for
    /// texel 0 and the partition's anchor, whose top bit is implied 0).
    private static func packMode1(_ input: Mode1Fit) -> (UInt64, UInt64) {
        var fit = input
        let anchors = [0, partitionAnchors[fit.partition]]
        for subsetIndex in 0..<2 where fit.indices[anchors[subsetIndex]] >= 4 {
            fit.endpoints.swapAt(subsetIndex * 2, subsetIndex * 2 + 1)
            for texel in 0..<16 where subset(of: texel, partition: fit.partition) == subsetIndex {
                fit.indices[texel] = 7 - fit.indices[texel]
            }
        }
        var writer = BitWriter()
        writer.write(0b10, bits: 2)
        writer.write(UInt64(fit.partition), bits: 6)
        for channel in 0..<3 {
            for endpoint in 0..<4 { writer.write(UInt64(fit.endpoints[endpoint][channel]), bits: 6) }
        }
        writer.write(UInt64(fit.shared[0]), bits: 1)
        writer.write(UInt64(fit.shared[1]), bits: 1)
        for texel in 0..<16 {
            writer.write(UInt64(fit.indices[texel]), bits: anchors.contains(texel) ? 2 : 3)
        }
        return (writer.low, writer.high)
    }

    // MARK: Mipmaps

    /// The next mipmap of straight-alpha RGBA8 `rgba`: half the size (rounded down, at least 1),
    /// resampled with a Lanczos filter in linear light on premultiplied colour, so transparent
    /// texels don't bleed their colour into the edges.
    static func halfSize(_ rgba: [UInt8], width: Int, height: Int) -> (texels: [UInt8], width: Int, height: Int) {
        let newWidth = max(1, width / 2), newHeight = max(1, height / 2)
        let count = width * height
        var linear = [Float](repeating: 0, count: count * 4)
        for index in 0..<count {
            let alpha = Float(rgba[index * 4 + 3]) / 255
            for channel in 0..<3 {
                linear[index * 4 + channel] = Self.linearTable[Int(rgba[index * 4 + channel])] * alpha
            }
            linear[index * 4 + 3] = alpha
        }
        var scaled = [Float](repeating: 0, count: newWidth * newHeight * 4)
        linear.withUnsafeMutableBytes { source in
            scaled.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 16)
                var output = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(newHeight),
                                           width: vImagePixelCount(newWidth), rowBytes: newWidth * 16)
                _ = vImageScale_ARGBFFFF(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        var texels = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for index in 0..<(newWidth * newHeight) {
            let alpha = min(1, max(0, scaled[index * 4 + 3]))
            for channel in 0..<3 {
                let value = alpha > 0 ? scaled[index * 4 + channel] / alpha : 0
                texels[index * 4 + channel] = encodeSRGB(value)
            }
            texels[index * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        return (texels, newWidth, newHeight)
    }

    private static let linearTable: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static func encodeSRGB(_ linear: Float) -> UInt8 {
        let c = min(1, max(0, linear))
        let encoded = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }

    // MARK: Quality

    struct Quality: Equatable {
        /// Mean SSIM (8×8 windows) of luma over black.
        var lumaSSIM: Double
        /// Mean SSIM of alpha.
        var alphaSSIM: Double
        /// 99th percentile CIEDE2000 over sampled texels, composited over black.
        var deltaE99: Double
        /// Mean luma SSIM over the windows holding hard edges (line art, text, outlines), where
        /// the eye and the plan's text bar look hardest; 1 without any.
        var edgeSSIM: Double = 1
    }

    /// How `candidate` compares with `reference` (both straight RGBA8, same size).
    static func quality(reference: [UInt8], candidate: [UInt8], width: Int, height: Int) -> Quality {
        let count = width * height
        var lumaA = [Float](repeating: 0, count: count), lumaB = lumaA
        var alphaA = lumaA, alphaB = lumaA
        for index in 0..<count {
            let o = index * 4
            let a = Float(reference[o + 3]) / 255, b = Float(candidate[o + 3]) / 255
            lumaA[index] = (0.2126 * Float(reference[o]) + 0.7152 * Float(reference[o + 1]) + 0.0722 * Float(reference[o + 2])) / 255 * a
            lumaB[index] = (0.2126 * Float(candidate[o]) + 0.7152 * Float(candidate[o + 1]) + 0.0722 * Float(candidate[o + 2])) / 255 * b
            alphaA[index] = a
            alphaB[index] = b
        }
        let step = max(1, Int((Double(count) / 250_000).squareRoot()))
        var differences: [Double] = []
        differences.reserveCapacity((width / step + 1) * (height / step + 1))
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let o = (y * width + x) * 4
                differences.append(ciede2000(lab(reference, o), lab(candidate, o)))
            }
        }
        differences.sort()
        let p99 = differences.isEmpty ? 0 : differences[min(differences.count - 1, Int(Double(differences.count) * 0.99))]
        return Quality(lumaSSIM: ssim(lumaA, lumaB, width: width, height: height),
                       alphaSSIM: ssim(alphaA, alphaB, width: width, height: height), deltaE99: p99,
                       edgeSSIM: ssim(lumaA, lumaB, width: width, height: height, minimumDeviation: 0.12))
    }

    /// Mean SSIM over non-overlapping 8×8 windows (K1 = 0.01, K2 = 0.03, L = 1).
    /// `minimumDeviation`: only windows whose reference luma deviates at least this much (edges).
    static func ssim(_ a: [Float], _ b: [Float], width: Int, height: Int, minimumDeviation: Double = 0) -> Double {
        let c1 = 0.0001, c2 = 0.0009
        var total = 0.0
        var windows = 0
        for top in stride(from: 0, to: max(1, height - 7), by: 8) {
            for left in stride(from: 0, to: max(1, width - 7), by: 8) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
                for y in top..<min(height, top + 8) {
                    for x in left..<min(width, left + 8) {
                        let va = Double(a[y * width + x]), vb = Double(b[y * width + x])
                        sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb; n += 1
                    }
                }
                let ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                if minimumDeviation > 0, va < minimumDeviation * minimumDeviation { continue }
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                windows += 1
            }
        }
        return windows > 0 ? total / Double(windows) : 1
    }

    private static func lab(_ texels: [UInt8], _ offset: Int) -> SIMD3<Double> {
        let alpha = Double(texels[offset + 3]) / 255
        func linear(_ v: UInt8) -> Double { Double(linearTable[Int(v)]) * alpha }
        let r = linear(texels[offset]), g = linear(texels[offset + 1]), b = linear(texels[offset + 2])
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIEDE2000 (Sharma, Wu & Dalal 2005), kL = kC = kH = 1.
    static func ciede2000(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double {
        let c1 = (p.y * p.y + p.z * p.z).squareRoot(), c2 = (q.y * q.y + q.z * q.z).squareRoot()
        let cMean = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(cMean, 7) / (pow(cMean, 7) + pow(25, 7))).squareRoot())
        let a1 = p.y * (1 + g), a2 = q.y * (1 + g)
        let cp1 = (a1 * a1 + p.z * p.z).squareRoot(), cp2 = (a2 * a2 + q.z * q.z).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.z, a1), h2 = hue(q.z, a2)
        let dL = q.x - p.x, dC = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(dh * .pi / 360)
        let lMean = (p.x + q.x) / 2, cpMean = (cp1 + cp2) / 2
        var hMean = h1 + h2
        if cp1 * cp2 != 0 {
            if abs(h1 - h2) <= 180 { hMean /= 2 } else { hMean = (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2 }
        }
        let t = 1 - 0.17 * cos((hMean - 30) * .pi / 180) + 0.24 * cos(2 * hMean * .pi / 180)
            + 0.32 * cos((3 * hMean + 6) * .pi / 180) - 0.2 * cos((4 * hMean - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let rc = 2 * (pow(cpMean, 7) / (pow(cpMean, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lMean - 50, 2) / (20 + pow(lMean - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cpMean, sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let terms = pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh)
        return max(0, terms).squareRoot()
    }
}
