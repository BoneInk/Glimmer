import Foundation

/// Compresses bytes as one raw LZ4 block, the compression WE's `.tex` mipmaps use (`TEXParser`
/// decodes them). A greedy matcher over a hash of 4-byte sequences, within LZ4's 64 KiB window,
/// keeping the block format's end rules (the last 5 bytes are literals, and no match starts in
/// the last 12), so any LZ4 decoder, the strict ones included, accepts the block.
public enum LZ4BlockEncoder {
    public static let minimumMatch = 4
    public static let lastLiterals = 5
    public static let matchSafeDistance = 12
    public static let window = 65_535
    private static let hashBits = 16

    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count / 2 + 16)
        let count = input.count
        guard count > matchSafeDistance else {
            appendSequence(&output, literals: input[...], match: nil)
            return output
        }
        var table = [Int](repeating: -1, count: 1 << hashBits)
        let matchLimit = count - matchSafeDistance
        var anchor = 0
        var position = 0
        input.withUnsafeBufferPointer { bytes in
            func read32(_ index: Int) -> UInt32 {
                UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            }
            func hash(_ value: UInt32) -> Int { Int((value &* 2_654_435_761) >> UInt32(32 - hashBits)) }
            while position < matchLimit {
                let value = read32(position)
                let slot = hash(value)
                let candidate = table[slot]
                table[slot] = position
                guard candidate >= 0, position - candidate <= window, read32(candidate) == value else {
                    position += 1
                    continue
                }
                var length = minimumMatch
                let end = count - lastLiterals
                while position + length < end, bytes[candidate + length] == bytes[position + length] { length += 1 }
                appendSequence(&output, literals: input[anchor..<position], match: (offset: position - candidate, length: length))
                position += length
                anchor = position
            }
        }
        appendSequence(&output, literals: input[anchor...], match: nil)
        return output
    }

    private static func appendLength(_ output: inout [UInt8], _ value: Int) {
        var remaining = value
        while remaining >= 255 {
            output.append(255)
            remaining -= 255
        }
        output.append(UInt8(remaining))
    }

    private static func appendSequence(_ output: inout [UInt8], literals: ArraySlice<UInt8>, match: (offset: Int, length: Int)?) {
        let literalCount = literals.count
        let matchCode = match.map { $0.length - minimumMatch } ?? 0
        output.append(UInt8(min(literalCount, 15) << 4 | min(matchCode, 15)))
        if literalCount >= 15 { appendLength(&output, literalCount - 15) }
        output.append(contentsOf: literals)
        guard let match else { return }
        output.append(UInt8(match.offset & 0xFF))
        output.append(UInt8(match.offset >> 8))
        if matchCode >= 15 { appendLength(&output, matchCode - 15) }
    }
}
