/// Hex text of digests, the one spelling every cache key, file name and stamp uses: two lower-case
/// hex digits per byte, in order, with no separator (what `String(format: "%02x", byte)` joined
/// gives). Callers pick the algorithm and how many bytes to keep (`SHA256.hash(data:).prefix(8)`).
public enum Digest {
    private static let digits = Array("0123456789abcdef".utf8)

    /// `bytes` as lower-case hex, two digits per byte.
    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var text: [UInt8] = []
        text.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
