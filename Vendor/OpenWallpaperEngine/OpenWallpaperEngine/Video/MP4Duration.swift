import Foundation

/// An MP4's length from its movie header (`moov/mvhd`), without opening it in AVFoundation. Only
/// the box headers on the way and `mvhd`'s fields are read (`MP4Box.Header`); nothing is copied.
enum MP4Duration {
    static func seconds(of data: Data) -> Double? {
        guard let moov = MP4Box.Header.first("moov", in: data, range: 0..<data.count),
              let mvhd = MP4Box.Header.first("mvhd", in: data, range: moov.payload) else { return nil }
        let body = mvhd.payload.lowerBound
        guard body < mvhd.box.upperBound else { return nil }
        let version = data.mp4UInt8(at: body)
        let (scaleAt, durationAt) = version == 1 ? (body + 20, body + 24) : (body + 12, body + 16)
        guard durationAt + (version == 1 ? 8 : 4) <= mvhd.box.upperBound else { return nil }
        let timescale = data.mp4UInt32(at: scaleAt)
        let duration = version == 1 ? data.mp4UInt64(at: durationAt) : UInt64(data.mp4UInt32(at: durationAt))
        guard timescale > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }
}
