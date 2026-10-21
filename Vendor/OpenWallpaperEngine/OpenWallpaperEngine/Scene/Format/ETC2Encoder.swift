import Foundation

/// Encodes RGBA8 pixels as ETC2 RGBA8 (EAC alpha), WE's `.tex` format 5: what WE's mobile export
/// stores its colour textures as (its sample decodes as ETC2 with an EAC alpha block before each
/// colour block, opaque blocks as alpha 255 with multiplier 0). Each 4×4 block is 16 bytes: the
/// EAC alpha block, then the ETC2 colour block, both big-endian, pixels column by column.
///
/// The colour block is the best of ETC1's individual and differential modes (both subblock
/// orientations, every modifier table) and ETC2's planar mode (a least-squares gradient, which
/// WE's encoder uses for most smooth blocks); T and H modes aren't tried. Errors are summed
/// squared differences per channel.
enum ETC2Encoder {
    /// The `.tex` format number of ETC2 RGBA8 (`TEXImageFormat`).
    static let texFormat: UInt32 = 5
    static let bytesPerBlock = 16

    /// ETC1's modifier tables (a, b): a pixel adds +a, +b, −a or −b.
    static let modifiers: [(Int, Int)] = [(2, 8), (5, 17), (9, 29), (13, 42), (18, 60), (24, 80), (33, 106), (47, 183)]
    /// EAC's modifier tables.
    static let alphaModifiers: [[Int]] = [
        [-3, -6, -9, -15, 2, 5, 8, 14], [-3, -7, -10, -13, 2, 6, 9, 12], [-2, -5, -8, -13, 1, 4, 7, 12],
        [-2, -4, -6, -13, 1, 3, 5, 12], [-3, -6, -8, -12, 2, 5, 7, 11], [-3, -7, -9, -11, 2, 6, 8, 10],
        [-4, -7, -8, -11, 3, 6, 7, 10], [-3, -5, -8, -11, 2, 4, 7, 10], [-2, -6, -8, -10, 1, 5, 7, 9],
        [-2, -5, -8, -10, 1, 4, 7, 9], [-2, -4, -8, -10, 1, 3, 7, 9], [-2, -5, -7, -10, 1, 4, 6, 9],
        [-3, -4, -7, -10, 2, 3, 6, 9], [-1, -2, -3, -10, 0, 1, 2, 9], [-4, -6, -8, -9, 3, 5, 7, 8],
        [-3, -5, -7, -9, 2, 4, 6, 8],
    ]

    /// Encodes `pixels` (RGBA8, `width`×`height`, both multiples of 4, rows top to bottom) into
    /// blocks row by row.
    static func encode(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        precondition(width % 4 == 0 && height % 4 == 0 && pixels.count >= width * height * 4)
        let columns = width / 4, rows = height / 4
        var output = [UInt8](repeating: 0, count: columns * rows * bytesPerBlock)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                DispatchQueue.concurrentPerform(iterations: rows) { row in
                    var block = Block()
                    for column in 0..<columns {
                        block.load(source, width: width, x: column * 4, y: row * 4)
                        let offset = (row * columns + column) * bytesPerBlock
                        write(alphaBlock(block), to: destination, at: offset)
                        write(colorBlock(block), to: destination, at: offset + 8)
                    }
                }
            }
        }
        return output
    }

    private static func write(_ value: UInt64, to buffer: UnsafeMutableBufferPointer<UInt8>, at offset: Int) {
        for byte in 0..<8 { buffer[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * byte)) }
    }

    /// One 4×4 block, pixel `k = x * 4 + y` (column-major, as ETC indexes them).
    struct Block {
        var r = [Int](repeating: 0, count: 16), g = [Int](repeating: 0, count: 16)
        var b = [Int](repeating: 0, count: 16), a = [Int](repeating: 0, count: 16)

        mutating func load(_ pixels: UnsafeBufferPointer<UInt8>, width: Int, x: Int, y: Int) {
            for dx in 0..<4 {
                for dy in 0..<4 {
                    let p = ((y + dy) * width + x + dx) * 4
                    let k = dx * 4 + dy
                    r[k] = Int(pixels[p]); g[k] = Int(pixels[p + 1]); b[k] = Int(pixels[p + 2]); a[k] = Int(pixels[p + 3])
                }
            }
        }
    }

    // MARK: Alpha (EAC)

    static func alphaBlock(_ block: Block) -> UInt64 {
        let low = block.a.min() ?? 255, high = block.a.max() ?? 255
        if low == high { return UInt64(low) << 56 }
        var best: (error: Int, word: UInt64) = (.max, 0)
        let middle = (low + high + 1) / 2
        for (table, mods) in alphaModifiers.enumerated() {
            let span = (mods.max() ?? 1) - (mods.min() ?? 0)
            let guess = max(1, min(15, Int((Double(high - low) / Double(span)).rounded())))
            for multiplier in max(1, guess - 1)...min(15, guess + 1) {
                let lowBase = low - (mods.min() ?? 0) * multiplier
                for base in Set([middle, lowBase, middle - 1, middle + 1]) where (0...255).contains(base) {
                    var error = 0
                    var indices: UInt64 = 0
                    for k in 0..<16 {
                        var bestIndex = 0, bestError = Int.max
                        for (index, mod) in mods.enumerated() {
                            let value = min(max(base + mod * multiplier, 0), 255)
                            let difference = (value - block.a[k]) * (value - block.a[k])
                            if difference < bestError { bestError = difference; bestIndex = index }
                        }
                        error += bestError
                        indices |= UInt64(bestIndex) << UInt64(45 - 3 * k)
                    }
                    if error < best.error {
                        best = (error, UInt64(base) << 56 | UInt64(multiplier) << 52 | UInt64(table) << 48 | indices)
                    }
                }
            }
        }
        return best.word
    }

    // MARK: Colour

    static func colorBlock(_ block: Block) -> UInt64 {
        var best = etc1(block)
        let planarCandidate = planar(block)
        if planarCandidate.error < best.error { best = planarCandidate }
        return best.word
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }

    /// The best modifier table and pixel indices for one subblock around `base`.
    private static func fit(_ block: Block, pixels: [Int], base: (Int, Int, Int)) -> (error: Int, table: Int, indices: [Int]) {
        var best: (error: Int, table: Int, indices: [Int]) = (.max, 0, [])
        for (table, pair) in modifiers.enumerated() {
            let deltas = [pair.0, pair.1, -pair.0, -pair.1]
            var error = 0
            var indices: [Int] = []
            indices.reserveCapacity(pixels.count)
            for k in pixels {
                var bestIndex = 0, bestError = Int.max
                for (index, delta) in deltas.enumerated() {
                    let dr = clamp(base.0 + delta) - block.r[k], dg = clamp(base.1 + delta) - block.g[k]
                    let db = clamp(base.2 + delta) - block.b[k]
                    let difference = dr * dr + dg * dg + db * db
                    if difference < bestError { bestError = difference; bestIndex = index }
                }
                error += bestError
                indices.append(bestIndex)
                if error >= best.error { break }
            }
            if error < best.error { best = (error, table, indices) }
        }
        return best
    }

    /// The pixels of each subblock: [flip][second].
    private static let subblocks: [[[Int]]] = [false, true].map { flip in
        [false, true].map { second in
            (0..<16).filter { k in (flip ? k % 4 >= 2 : k / 4 >= 2) == second }
        }
    }

    private static func average(_ block: Block, _ pixels: [Int]) -> (Double, Double, Double) {
        let count = Double(pixels.count)
        return (Double(pixels.reduce(0) { $0 + block.r[$1] }) / count, Double(pixels.reduce(0) { $0 + block.g[$1] }) / count,
                Double(pixels.reduce(0) { $0 + block.b[$1] }) / count)
    }

    private static func etc1(_ block: Block) -> (error: Int, word: UInt64) {
        var best: (error: Int, word: UInt64) = (.max, 0)
        for flip in [false, true] {
            let first = subblocks[flip ? 1 : 0][0], second = subblocks[flip ? 1 : 0][1]
            let averages = [average(block, first), average(block, second)]
            // Individual: two 4-bit colours.
            let four = averages.map { (q4($0.0), q4($0.1), q4($0.2)) }
            let fits4 = [fit(block, pixels: first, base: (e4(four[0].0), e4(four[0].1), e4(four[0].2))),
                         fit(block, pixels: second, base: (e4(four[1].0), e4(four[1].1), e4(four[1].2)))]
            let error4 = fits4[0].error + fits4[1].error
            if error4 < best.error {
                var word = UInt64(four[0].0) << 60 | UInt64(four[1].0) << 56 | UInt64(four[0].1) << 52 | UInt64(four[1].1) << 48
                word |= UInt64(four[0].2) << 44 | UInt64(four[1].2) << 40
                best = (error4, word | header(fits4, flip: flip, differential: false)
                    | indexBits(fits4, first: first, second: second))
            }
            // Differential: a 5-bit colour and a 3-bit signed difference.
            let five = averages.map { (q5($0.0), q5($0.1), q5($0.2)) }
            let delta = (five[1].0 - five[0].0, five[1].1 - five[0].1, five[1].2 - five[0].2)
            guard (-4...3).contains(delta.0), (-4...3).contains(delta.1), (-4...3).contains(delta.2) else { continue }
            let fits5 = [fit(block, pixels: first, base: (e5(five[0].0), e5(five[0].1), e5(five[0].2))),
                         fit(block, pixels: second, base: (e5(five[1].0), e5(five[1].1), e5(five[1].2)))]
            let error5 = fits5[0].error + fits5[1].error
            if error5 < best.error {
                var word = UInt64(five[0].0) << 59 | UInt64(delta.0 & 7) << 56 | UInt64(five[0].1) << 51
                word |= UInt64(delta.1 & 7) << 48 | UInt64(five[0].2) << 43 | UInt64(delta.2 & 7) << 40
                best = (error5, word | header(fits5, flip: flip, differential: true)
                    | indexBits(fits5, first: first, second: second))
            }
        }
        return best
    }

    private static func header(_ fits: [(error: Int, table: Int, indices: [Int])], flip: Bool, differential: Bool) -> UInt64 {
        UInt64(fits[0].table) << 37 | UInt64(fits[1].table) << 34 | (differential ? 1 << 33 : 0) | (flip ? 1 << 32 : 0)
    }

    private static func indexBits(_ fits: [(error: Int, table: Int, indices: [Int])], first: [Int], second: [Int]) -> UInt64 {
        var word: UInt64 = 0
        for (pixels, fit) in [(first, fits[0]), (second, fits[1])] {
            for (k, index) in zip(pixels, fit.indices) {
                word |= UInt64(index >> 1) << UInt64(16 + k) | UInt64(index & 1) << UInt64(k)
            }
        }
        return word
    }

    private static func q4(_ value: Double) -> Int { min(max(Int((value / 17).rounded()), 0), 15) }
    private static func q5(_ value: Double) -> Int { min(max(Int((value * 31 / 255).rounded()), 0), 31) }
    static func e4(_ value: Int) -> Int { value << 4 | value }
    static func e5(_ value: Int) -> Int { value << 3 | value >> 2 }
    static func e6(_ value: Int) -> Int { value << 2 | value >> 4 }
    static func e7(_ value: Int) -> Int { value << 1 | value >> 6 }

    // MARK: Planar

    /// ETC2's planar mode: a colour at the block's origin, its right edge and its bottom edge,
    /// fitted by least squares and rounded to the nearest of their neighbours.
    private static func planar(_ block: Block) -> (error: Int, word: UInt64) {
        var channels: [(o: Int, h: Int, v: Int)] = []
        var error = 0
        for (values, bits) in [(block.r, 6), (block.g, 7), (block.b, 6)] {
            let fitted = fitPlane(values, bits: bits)
            channels.append((fitted.o, fitted.h, fitted.v))
            error += fitted.error
        }
        let (ro, rh, rv) = (UInt64(channels[0].o), UInt64(channels[0].h), UInt64(channels[0].v))
        let (go, gh, gv) = (UInt64(channels[1].o), UInt64(channels[1].h), UInt64(channels[1].v))
        let (bo, bh, bv) = (UInt64(channels[2].o), UInt64(channels[2].h), UInt64(channels[2].v))
        var word: UInt64 = ro << 57 | (go >> 6) << 56 | (go & 63) << 49 | (bo >> 5) << 48 | ((bo >> 3) & 3) << 43 | (bo & 7) << 39
        word |= (rh >> 1) << 34 | (rh & 1) << 32 | gh << 25 | bh << 19 | rv << 13 | gv << 6 | bv
        word |= 1 << 33
        // The free bits make the red and green sums fit and the blue sum overflow, which is
        // how a decoder tells planar mode from the others.
        for free in 0..<64 {
            var candidate = word
            if free & 1 != 0 { candidate |= 1 << 63 }
            if free & 2 != 0 { candidate |= 1 << 55 }
            candidate |= UInt64((free >> 2) & 7) << 45
            if free & 32 != 0 { candidate |= 1 << 42 }
            if isPlanar(candidate) { return (error, candidate) }
        }
        return (.max, 0)
    }

    static func isPlanar(_ word: UInt64) -> Bool {
        func signed3(_ value: UInt64) -> Int { let v = Int(value & 7); return v > 3 ? v - 8 : v }
        let red = Int(word >> 59 & 31) + signed3(word >> 56), green = Int(word >> 51 & 31) + signed3(word >> 48)
        let blue = Int(word >> 43 & 31) + signed3(word >> 40)
        return word >> 33 & 1 == 1 && (0...31).contains(red) && (0...31).contains(green) && !(0...31).contains(blue)
    }

    /// One channel's plane: origin, right and bottom colours quantised to `bits`, and its error.
    private static func fitPlane(_ values: [Int], bits: Int) -> (o: Int, h: Int, v: Int, error: Int) {
        var sum = 0.0, sumX = 0.0, sumY = 0.0
        for k in 0..<16 {
            let x = Double(k / 4) - 1.5, y = Double(k % 4) - 1.5, value = Double(values[k])
            sum += value; sumX += x * value; sumY += y * value
        }
        let slopeX = sumX / 20, slopeY = sumY / 20
        let origin = sum / 16 - 1.5 * slopeX - 1.5 * slopeY
        let top = Double((1 << bits) - 1)
        func quantise(_ value: Double) -> Int { min(max(Int((value * top / 255).rounded()), 0), Int(top)) }
        let expand: (Int) -> Int = bits == 7 ? e7 : e6
        let guesses = (quantise(origin), quantise(origin + 4 * slopeX), quantise(origin + 4 * slopeY))
        var best = (o: guesses.0, h: guesses.1, v: guesses.2, error: Int.max)
        for o in guesses.0 - 1...guesses.0 + 1 where o >= 0 && o <= Int(top) {
            for h in guesses.1 - 1...guesses.1 + 1 where h >= 0 && h <= Int(top) {
                for v in guesses.2 - 1...guesses.2 + 1 where v >= 0 && v <= Int(top) {
                    let eo = expand(o), eh = expand(h), ev = expand(v)
                    var error = 0
                    for k in 0..<16 {
                        let x = k / 4, y = k % 4
                        let value = clamp((x * (eh - eo) + y * (ev - eo) + 4 * eo + 2) >> 2)
                        error += (value - values[k]) * (value - values[k])
                    }
                    if error < best.error { best = (o, h, v, error) }
                }
            }
        }
        return best
    }
}
