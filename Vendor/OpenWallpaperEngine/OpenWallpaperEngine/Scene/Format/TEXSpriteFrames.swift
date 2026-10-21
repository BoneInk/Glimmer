import Foundation

/// The `TEXS000n` block of an animated `.tex`: its frames in file order (docs/timeline-plan.md
/// §1.2). Every frame the block lists is kept, 0 s ones included: WE's texture clock shows a 0 s
/// frame for one engine frame (§2.7), and `ITextureAnimation.frameCount` counts it.
///
/// Layout: the marker, `count`, then for `TEXS0003` the GIF width and height, then `count` frames
/// of 32 bytes: image index (int), frame time (float seconds), and x, y, width, widthY, heightX,
/// height (ints in `TEXS0001`, floats in `TEXS0002` and `TEXS0003`).
enum TEXSpriteFrames {
    private static let marker = Array("TEXS000".utf8)
    /// More frames than any real texture has; a larger count is a misread block.
    private static let maximumCount: UInt32 = 100_000

    /// Parses the block whose marker starts at `cursor`, leaving `cursor` after its last frame.
    /// Nil when the bytes there aren't a TEXS block or end early.
    static func parse(_ bytes: [UInt8], cursor: inout Int) -> [TEXAnimationFrame]? {
        guard cursor >= 0, cursor + marker.count + 2 <= bytes.count,
              Array(bytes[cursor..<(cursor + marker.count)]) == marker,
              bytes[cursor + marker.count + 1] == 0 else { return nil }
        let version = bytes[cursor + marker.count]
        guard version >= UInt8(ascii: "1"), version <= UInt8(ascii: "3") else { return nil }
        var position = cursor + marker.count + 2
        func u32() -> UInt32? {
            guard position + 4 <= bytes.count else { return nil }
            defer { position += 4 }
            return UInt32(bytes[position]) | (UInt32(bytes[position + 1]) << 8)
                | (UInt32(bytes[position + 2]) << 16) | (UInt32(bytes[position + 3]) << 24)
        }
        guard let count = u32(), count <= maximumCount else { return nil }
        if version == UInt8(ascii: "3") {
            guard u32() != nil, u32() != nil else { return nil }
        }
        let integerRects = version == UInt8(ascii: "1")
        var frames: [TEXAnimationFrame] = []
        frames.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let image = u32(), let time = u32() else { return nil }
            var rect = [Float](repeating: 0, count: 6)
            for index in 0..<6 {
                guard let raw = u32() else { return nil }
                rect[index] = integerRects ? Float(Int32(bitPattern: raw)) : Float(bitPattern: raw)
            }
            frames.append(TEXAnimationFrame(imageIndex: Int(Int32(bitPattern: image)), duration: Float(bitPattern: time),
                                            x: rect[0], y: rect[1], width: rect[2], widthY: rect[3],
                                            heightX: rect[4], height: rect[5]))
        }
        cursor = position
        return frames
    }

    /// The frames of the last TEXS block in `bytes`, found without decoding the images. Nil when
    /// the texture has none.
    static func frames(_ bytes: [UInt8]) -> [TEXAnimationFrame]? {
        guard bytes.count > marker.count + 2 else { return nil }
        var index = bytes.count - marker.count - 2
        while index >= 0 {
            if bytes[index] == marker[0], bytes[index + marker.count + 1] == 0,
               Array(bytes[index..<(index + marker.count)]) == marker {
                var cursor = index
                return parse(bytes, cursor: &cursor)
            }
            index -= 1
        }
        return nil
    }

    /// Each frame's time in seconds (what `getTextureAnimation()` describes), or nil when the
    /// texture has no `TEXS` block.
    static func durations(_ bytes: [UInt8]) -> [Double]? {
        guard let frames = frames(bytes), !frames.isEmpty else { return nil }
        return frames.map { Double($0.duration) }
    }
}
