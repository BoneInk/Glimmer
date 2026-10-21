import Foundation

/// The picture size of an MP4's first video track (`moov/trak/tkhd`, 16.16 fixed point). Only the
/// box headers on the way and `tkhd`'s fields are read (`MP4Box.Header`); nothing is copied.
enum MP4TrackSize {
    static func pictureSize(of movie: Data) -> (width: Int, height: Int)? {
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= movie.count else { return nil }
            return Int(movie.mp4UInt32(at: at))
        }
        guard let moov = MP4Box.Header.first("moov", in: movie, range: 0..<movie.count) else { return nil }
        for trak in MP4Box.Header.sequence(movie, in: moov.payload) where trak.type == "trak" {
            guard let tkhd = MP4Box.Header.first("tkhd", in: movie, range: trak.payload) else { continue }
            let start = tkhd.payload.lowerBound
            // Version 1 has 64-bit times: 12 more bytes before the size.
            let offset = start < movie.count && movie.mp4UInt8(at: start) == 1 ? 88 : 76
            guard let width = u32(start + offset), let height = u32(start + offset + 4), width > 0, height > 0 else { continue }
            return (width >> 16, height >> 16)
        }
        return nil
    }
}
