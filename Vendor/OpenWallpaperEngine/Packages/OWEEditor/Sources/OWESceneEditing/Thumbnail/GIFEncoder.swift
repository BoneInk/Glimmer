import Foundation

/// An animated GIF as WE's encoder (`resourcecompiler -op gifenc`) writes a preview: one global
/// colour table for every frame (median cut over all of them, so colours don't flicker between
/// frames), full frames left in place (disposal 1, no transparency), every frame the same delay,
/// looping forever, optionally Floyd–Steinberg dithered.
public enum GIFEncoder {
    /// A frame's pixels: `width × height` RGBA, 8 bits a channel, rows top to bottom; alpha is ignored.
    public struct Frame: Sendable {
        public var width: Int
        public var height: Int
        public var rgba: [UInt8]

        public init(width: Int, height: Int, rgba: [UInt8]) {
            precondition(rgba.count == width * height * 4, "a frame holds width × height RGBA pixels")
            self.width = width
            self.height = height
            self.rgba = rgba
        }
    }

    /// The GIF of `frames` (all of the first one's size) with a palette of `colors` (a power of
    /// two, 2…256) and `delay` hundredths of a second per frame.
    public static func encode(_ frames: [Frame], colors: Int, delay: Int, dithered: Bool) -> Data {
        guard let first = frames.first else { return Data() }
        let bits = max(1, min(8, Int(log2(Double(max(colors, 2))).rounded(.up))))
        var palette = MedianCutPalette(frames: frames, colors: 1 << bits)
        var out = Data()
        out.append(contentsOf: Array("GIF89a".utf8))
        appendShort(first.width, to: &out)
        appendShort(first.height, to: &out)
        out.append(UInt8(0x80 | (7 << 4) | (bits - 1)))  // global table, 8-bit colour resolution
        out.append(0)  // background index
        out.append(0)  // square pixels
        for index in 0..<(1 << bits) {
            let color = index < palette.colors.count ? palette.colors[index] : SIMD3<UInt8>(0, 0, 0)
            out.append(contentsOf: [color.x, color.y, color.z])
        }
        // NETSCAPE2.0: loop forever.
        out.append(contentsOf: [0x21, 0xFF, 0x0B])
        out.append(contentsOf: Array("NETSCAPE2.0".utf8))
        out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        for frame in frames {
            // Graphic control: disposal 1 (left in place), no transparency.
            out.append(contentsOf: [0x21, 0xF9, 0x04, 0x04])
            appendShort(delay, to: &out)
            out.append(contentsOf: [0x00, 0x00])
            out.append(0x2C)
            appendShort(0, to: &out)
            appendShort(0, to: &out)
            appendShort(frame.width, to: &out)
            appendShort(frame.height, to: &out)
            out.append(0)  // no local table, not interlaced
            let indices = palette.indices(of: frame, dithered: dithered)
            let minimumCodeSize = max(2, bits)
            out.append(UInt8(minimumCodeSize))
            let compressed = LZW.compress(indices, minimumCodeSize: minimumCodeSize)
            var offset = 0
            while offset < compressed.count {
                let count = min(255, compressed.count - offset)
                out.append(UInt8(count))
                out.append(contentsOf: compressed[offset..<(offset + count)])
                offset += count
            }
            out.append(0)
        }
        out.append(0x3B)
        return out
    }

    private static func appendShort(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}

/// A palette by median cut over a 5-bit-per-channel histogram of every frame, and the nearest
/// colour of any 15-bit colour, looked up once.
struct MedianCutPalette {
    private(set) var colors: [SIMD3<UInt8>] = []
    /// The nearest palette index of each 15-bit colour, filled as it is asked for (-1: not yet).
    private var nearest: [Int16]

    private struct Bin {
        var count = 0
        var sum = SIMD3<Int>(0, 0, 0)
    }

    private struct Box {
        var keys: [Int]
        var population: Int
    }

    init(frames: [GIFEncoder.Frame], colors limit: Int) {
        nearest = [Int16](repeating: -1, count: 1 << 15)
        var bins = [Bin](repeating: Bin(), count: 1 << 15)
        for frame in frames {
            var offset = 0
            while offset < frame.rgba.count {
                let r = Int(frame.rgba[offset]), g = Int(frame.rgba[offset + 1]), b = Int(frame.rgba[offset + 2])
                let key = Self.key(r, g, b)
                bins[key].count += 1
                bins[key].sum &+= SIMD3(r, g, b)
                offset += 4
            }
        }
        let used = bins.indices.filter { bins[$0].count > 0 }
        var boxes = [Box(keys: used, population: used.reduce(0) { $0 + bins[$1].count })]
        while boxes.count < limit {
            // Split the most populous box that has more than one colour, along its longest side.
            guard let index = boxes.indices.filter({ boxes[$0].keys.count > 1 }).max(by: { boxes[$0].population < boxes[$1].population })
            else { break }
            let box = boxes.remove(at: index)
            let channel = Self.longestChannel(box.keys)
            let sorted = box.keys.sorted { Self.channel($0, channel) < Self.channel($1, channel) }
            var running = 0
            var split = 1
            for (position, key) in sorted.enumerated() {
                running += bins[key].count
                if running * 2 >= box.population {
                    split = min(max(position + 1, 1), sorted.count - 1)
                    break
                }
            }
            let low = Array(sorted[..<split]), high = Array(sorted[split...])
            boxes.append(Box(keys: low, population: low.reduce(0) { $0 + bins[$1].count }))
            boxes.append(Box(keys: high, population: high.reduce(0) { $0 + bins[$1].count }))
        }
        colors = boxes.map { box in
            let total = box.keys.reduce(SIMD3<Int>(0, 0, 0)) { $0 &+ bins[$1].sum }
            let count = max(box.population, 1)
            return SIMD3(UInt8(total.x / count), UInt8(total.y / count), UInt8(total.z / count))
        }
        if colors.isEmpty { colors = [SIMD3(0, 0, 0)] }
    }

    static func key(_ r: Int, _ g: Int, _ b: Int) -> Int { (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3) }

    private static func channel(_ key: Int, _ channel: Int) -> Int { (key >> (10 - channel * 5)) & 31 }

    private static func longestChannel(_ keys: [Int]) -> Int {
        var lower = [31, 31, 31], upper = [0, 0, 0]
        for key in keys {
            for c in 0..<3 {
                let value = channel(key, c)
                lower[c] = min(lower[c], value)
                upper[c] = max(upper[c], value)
            }
        }
        let ranges = (0..<3).map { upper[$0] - lower[$0] }
        return ranges.firstIndex(of: ranges.max() ?? 0) ?? 0
    }

    private mutating func index(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let key = Self.key(r, g, b)
        if nearest[key] >= 0 { return Int(nearest[key]) }
        // The bin's centre against every palette colour.
        let cr = (r >> 3) << 3 | 4, cg = (g >> 3) << 3 | 4, cb = (b >> 3) << 3 | 4
        var best = 0, bestDistance = Int.max
        for (index, color) in colors.enumerated() {
            let dr = Int(color.x) - cr, dg = Int(color.y) - cg, db = Int(color.z) - cb
            let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        nearest[key] = Int16(best)
        return best
    }

    /// The frame's palette indices, Floyd–Steinberg dithered when `dithered`.
    mutating func indices(of frame: GIFEncoder.Frame, dithered: Bool) -> [UInt8] {
        let width = frame.width, height = frame.height
        var out = [UInt8](repeating: 0, count: width * height)
        guard dithered else {
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                out[pixel] = UInt8(index(Int(frame.rgba[offset]), Int(frame.rgba[offset + 1]), Int(frame.rgba[offset + 2])))
            }
            return out
        }
        // Error rows in sixteenths: this row's and the next.
        var current = [SIMD3<Int>](repeating: .zero, count: width + 2)
        var next = [SIMD3<Int>](repeating: .zero, count: width + 2)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let source = SIMD3(Int(frame.rgba[offset]), Int(frame.rgba[offset + 1]), Int(frame.rgba[offset + 2]))
                let wanted = Self.clamp(source &+ current[x + 1] / 16)
                let chosen = index(wanted.x, wanted.y, wanted.z)
                out[y * width + x] = UInt8(chosen)
                let color = colors[chosen]
                let error: SIMD3<Int> = wanted &- SIMD3(Int(color.x), Int(color.y), Int(color.z))
                current[x + 2] &+= error &* 7
                next[x] &+= error &* 3
                next[x + 1] &+= error &* 5
                next[x + 2] &+= error
            }
            swap(&current, &next)
            for i in next.indices { next[i] = .zero }
        }
        return out
    }

    private static func clamp(_ value: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3(min(max(value.x, 0), 255), min(max(value.y, 0), 255), min(max(value.z, 0), 255))
    }
}

/// GIF's variable-length LZW, least significant bit first.
enum LZW {
    static func compress(_ indices: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var output: [UInt8] = []
        output.reserveCapacity(indices.count)
        var bitBuffer = 0, bitCount = 0
        var codeSize = minimumCodeSize + 1
        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                output.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }
        // The dictionary: (prefix code << 8 | next index) → code.
        var table: [Int: Int] = [:]
        table.reserveCapacity(4096)
        var nextCode = end + 1
        emit(clear)
        guard var prefix = indices.first.map(Int.init) else {
            emit(end)
            if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
            return output
        }
        for value in indices.dropFirst() {
            let key = prefix << 8 | Int(value)
            if let code = table[key] {
                prefix = code
                continue
            }
            emit(prefix)
            if nextCode < 4096 {
                table[key] = nextCode
                // The decoder widens its codes once it has made the code after this one.
                if nextCode == (1 << codeSize) { codeSize += 1 }
                nextCode += 1
            } else {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                codeSize = minimumCodeSize + 1
                nextCode = end + 1
            }
            prefix = Int(value)
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
        return output
    }
}
