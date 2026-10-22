import Foundation

/// A deliberately bounded, lossless container adapter. Only a single, unencrypted
/// VP9 profile-0 video track is accepted. Audio, alpha, lacing and track transforms
/// are never silently discarded: those files remain on WebKit's original path.
/// References: matroska.org/technical/elements.html and webmproject.org/vp9/mp4/.
enum WebMVP9Container {
    enum Failure: Error { case unsupported, invalid }
    struct Sample {
        let offset: Int64
        let size: Int
        let time: Int64
        let duration: Int64?
        let sync: Bool
    }
    struct Movie {
        let width: Int
        let height: Int
        let samples: [Sample]
        let durations: [UInt32]
        let configuration: Data
        var duration: UInt64 { durations.reduce(0) { $0 + UInt64($1) } }
    }
    static let timescale: UInt32 = 1_000_000
    static let maximumSamples = 1_000_000

    static func inspect(_ file: LocalWallpaperFileResource, cancelled: @escaping () -> Bool = { false }) throws -> Movie {
        try Parser(file: file, cancelled: cancelled).parse()
    }

    private struct Element {
        let id: UInt64
        let start: Int64
        let end: Int64
        let unknown: Bool
    }

    private final class Parser {
        let file: LocalWallpaperFileResource
        let cancelled: () -> Bool
        var inspected = 0
        var scale: Int64 = 1_000_000
        var declaredDuration: Double?
        var defaultDuration: Int64?
        var track: UInt64 = 0
        var width = 0, height = 0
        var primaries: UInt8 = 2, transfer: UInt8 = 2, matrix: UInt8 = 2
        var range: UInt8?
        var samples: [Sample] = []
        var clusters: [Element] = []

        init(file: LocalWallpaperFileResource, cancelled: @escaping () -> Bool) {
            self.file = file; self.cancelled = cancelled
        }

        func vint(_ offset: Int64, identifier: Bool = false) throws -> (UInt64, Int, Bool) {
            guard offset >= 0, offset < file.size else { throw Failure.invalid }
            let data = try file.read(offset: offset, count: Int(min(8, file.size - offset)))
            let first = data[0]
            guard first != 0 else { throw Failure.invalid }
            let count = first.leadingZeroBitCount + 1
            guard count <= (identifier ? 4 : 8), data.count >= count else { throw Failure.invalid }
            var value = UInt64(identifier ? first : first & (0xff >> count))
            for i in 1..<count { value = value << 8 | UInt64(data[i]) }
            return (value, count, !identifier && value == (UInt64(1) << (count * 7)) - 1)
        }

        func element(_ offset: Int64, limit: Int64) throws -> Element {
            inspected += 1
            guard inspected <= 4_000_000 else { throw Failure.unsupported }
            if inspected % 128 == 0, cancelled() { throw CancellationError() }
            let (id, idBytes, _) = try vint(offset, identifier: true)
            let (size, sizeBytes, unknown) = try vint(offset + Int64(idBytes))
            let start = offset + Int64(idBytes + sizeBytes)
            guard start <= limit, unknown || size <= UInt64(limit - start) else { throw Failure.invalid }
            return Element(id: id, start: start, end: unknown ? limit : start + Int64(size), unknown: unknown)
        }

        func children(_ parent: Element, _ body: (Element) throws -> Void) throws {
            var position = parent.start
            while position < parent.end {
                let child = try element(position, limit: parent.end)
                guard !child.unknown else { throw Failure.unsupported }
                try body(child)
                position = child.end
            }
        }

        func bytes(_ item: Element, maximum: Int = 64) throws -> Data {
            let count = item.end - item.start
            guard count > 0, count <= maximum else { throw Failure.unsupported }
            return try file.read(offset: item.start, count: Int(count))
        }
        func uint(_ item: Element) throws -> UInt64 {
            let data = try bytes(item, maximum: 8)
            return data.reduce(0) { $0 << 8 | UInt64($1) }
        }
        func float(_ item: Element) throws -> Double {
            let data = try bytes(item, maximum: 8)
            let value = data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if data.count == 4 { return Double(Float(bitPattern: UInt32(value))) }
            guard data.count == 8 else { throw Failure.invalid }
            return Double(bitPattern: value)
        }
        func ticks(_ value: Int64) throws -> Int64 {
            let (ns, overflow) = value.multipliedReportingOverflow(by: scale)
            guard !overflow, ns >= 0 else { throw Failure.unsupported }
            return ns / 1_000
        }

        func parse() throws -> Movie {
            guard file.size >= 8 else { throw Failure.unsupported }
            let ebml = try element(0, limit: file.size)
            guard ebml.id == 0x1a45dfa3, !ebml.unknown else { throw Failure.unsupported }
            var webm = false
            try children(ebml) { item in
                if item.id == 0x4282 { webm = try bytes(item) == Data("webm".utf8) }
            }
            guard webm else { throw Failure.unsupported }
            var cursor = ebml.end
            var segment: Element?
            while cursor < file.size {
                let item = try element(cursor, limit: file.size)
                if item.id == 0x18538067 { segment = item; break }
                guard !item.unknown else { throw Failure.unsupported }
                cursor = item.end
            }
            guard let segment else { throw Failure.invalid }
            var tracks = 0
            cursor = segment.start
            while cursor < segment.end {
                let item = try element(cursor, limit: segment.end)
                switch item.id {
                case 0x1549a966:
                    guard !item.unknown else { throw Failure.invalid }
                    try children(item) { child in
                        if child.id == 0x2ad7b1 {
                            let value = try uint(child)
                            guard value > 0, value <= 1_000_000_000 else { throw Failure.unsupported }
                            scale = Int64(value)
                        } else if child.id == 0x4489 { declaredDuration = try float(child) }
                    }
                case 0x1654ae6b:
                    try children(item) { child in
                        if child.id == 0xae { tracks += 1; try parseTrack(child) }
                    }
                case 0x1f43b675:
                    // Unknown-size clusters end at the next level-one element.
                    let end = item.unknown ? try clusterEnd(item) : item.end
                    guard clusters.count < WebMVP9Container.maximumSamples else { throw Failure.unsupported }
                    clusters.append(Element(id: item.id, start: item.start, end: end, unknown: false))
                    cursor = end; continue
                default:
                    guard !item.unknown else { throw Failure.unsupported }
                }
                cursor = item.end
            }
            guard tracks == 1, track > 0, width > 0, height > 0 else { throw Failure.unsupported }
            for cluster in clusters { try parseCluster(cluster) }
            guard !samples.isEmpty, samples[0].time == 0, samples[0].sync else { throw Failure.unsupported }
            let configuration = try vp9Configuration(samples[0])
            for sample in samples.dropFirst() where sample.sync {
                guard try vp9Configuration(sample) == configuration else { throw Failure.unsupported }
            }
            var durations: [UInt32] = []
            durations.reserveCapacity(samples.count)
            for i in samples.indices {
                let current = samples[i]
                let delta: Int64
                if i + 1 < samples.count {
                    delta = samples[i+1].time - current.time
                    if let explicit = current.duration, explicit != delta { throw Failure.unsupported }
                } else if let explicit = current.duration { delta = explicit }
                else if let duration = declaredDuration, duration.isFinite, duration > 0,
                        duration * Double(scale) / 1_000 < Double(Int64.max) {
                    delta = Int64((duration * Double(scale) / 1_000).rounded()) - current.time
                } else if let duration = defaultDuration { delta = duration / 1_000 }
                else if i > 0 { delta = current.time - samples[i-1].time }
                else { throw Failure.unsupported }
                guard delta > 0, delta <= UInt32.max else { throw Failure.unsupported }
                durations.append(UInt32(delta))
            }
            return Movie(width: width, height: height, samples: samples, durations: durations, configuration: configuration)
        }

        func parseTrack(_ entry: Element) throws {
            var type: UInt64 = 0, codec = "", pixelWidth = 0, pixelHeight = 0
            var displayWidth: UInt64?, displayHeight: UInt64?
            try children(entry) { item in
                switch item.id {
                case 0xd7: track = try uint(item)
                case 0x83: type = try uint(item)
                case 0x86: codec = String(decoding: try bytes(item), as: UTF8.self)
                case 0x23e383:
                    let value = try uint(item)
                    guard value <= Int64.max else { throw Failure.unsupported }
                    defaultDuration = Int64(value)
                case 0x6d80, 0x63a2, 0x6624: throw Failure.unsupported // encryption/codec transforms
                case 0x23314f: // TrackTimestampScale must retain the normal track clock.
                    guard try float(item) == 1 else { throw Failure.unsupported }
                case 0x56aa, 0x56bb, 0x537f:
                    guard try uint(item) == 0 else { throw Failure.unsupported }
                case 0xe0:
                    try children(item) { child in
                        switch child.id {
                        case 0xb0:
                            guard let value = Int(exactly: try uint(child)) else { throw Failure.unsupported }
                            pixelWidth = value
                        case 0xba:
                            guard let value = Int(exactly: try uint(child)) else { throw Failure.unsupported }
                            pixelHeight = value
                        case 0x54b0: displayWidth = try uint(child)
                        case 0x54ba: displayHeight = try uint(child)
                        case 0x54b2, 0x53c0, 0x53b8, 0x54aa, 0x54bb, 0x54cc, 0x54dd:
                            guard try uint(child) == 0 else { throw Failure.unsupported }
                        case 0x7670: throw Failure.unsupported
                        case 0x55b0: try parseColour(child)
                        default: break
                        }
                    }
                default: break
                }
            }
            guard type == 1, codec == "V_VP9", (1...65535).contains(pixelWidth), (1...65535).contains(pixelHeight),
                  displayWidth == nil || displayWidth == UInt64(pixelWidth),
                  displayHeight == nil || displayHeight == UInt64(pixelHeight) else { throw Failure.unsupported }
            width = pixelWidth; height = pixelHeight
        }

        func parseColour(_ colour: Element) throws {
            try children(colour) { item in
                if item.id == 0x55d0 { throw Failure.unsupported } // mastering/HDR data needs a separate mapping
                if [0x55b1, 0x55ba, 0x55bb, 0x55b9].contains(item.id) {
                    let value = try uint(item)
                    guard value <= 255 else { throw Failure.unsupported }
                    switch item.id {
                    case 0x55b1: matrix = UInt8(value)
                    case 0x55ba: transfer = UInt8(value)
                    case 0x55bb: primaries = UInt8(value)
                    case 0x55b9:
                        guard value <= 2 else { throw Failure.unsupported }
                        if value > 0 { range = value == 2 ? 1 : 0 }
                    default: break
                    }
                }
            }
        }

        func clusterEnd(_ cluster: Element) throws -> Int64 {
            let levelOne: Set<UInt64> = [0x114d9b74,0x1549a966,0x1654ae6b,0x1f43b675,0x1c53bb6b,0x1941a469,0x1043a770,0x1254c367]
            var cursor = cluster.start
            while cursor < cluster.end {
                let child = try element(cursor, limit: cluster.end)
                if levelOne.contains(child.id) { return cursor }
                guard !child.unknown else { throw Failure.unsupported }
                cursor = child.end
            }
            return cursor
        }

        func parseCluster(_ cluster: Element) throws {
            var time: Int64?
            try children(cluster) { item in
                if item.id == 0xe7 {
                    let value = try uint(item)
                    guard value <= Int64.max else { throw Failure.unsupported }
                    time = Int64(value)
                } else if item.id == 0xa3 {
                    guard let time else { throw Failure.unsupported }
                    try block(item, clusterTime: time, simple: true, sync: false, duration: nil)
                } else if item.id == 0xa0 {
                    guard let time else { throw Failure.unsupported }
                    var data: Element?, sync = true, duration: Int64?
                    try children(item) { child in
                        if child.id == 0xa1 { guard data == nil else { throw Failure.invalid }; data = child }
                        else if child.id == 0xfb { sync = false }
                        else if child.id == 0x9b {
                            let value = try uint(child)
                            guard value <= Int64.max else { throw Failure.unsupported }
                            duration = try ticks(Int64(value))
                        } else if child.id == 0x75a1 || child.id == 0x75a2 { throw Failure.unsupported }
                    }
                    guard let data else { throw Failure.invalid }
                    try block(data, clusterTime: time, simple: false, sync: sync, duration: duration)
                }
            }
        }

        func block(_ item: Element, clusterTime: Int64, simple: Bool, sync: Bool, duration: Int64?) throws {
            let (number, count, unknown) = try vint(item.start)
            guard !unknown, number == track, item.end - item.start > count + 3 else { throw Failure.unsupported }
            let header = try file.read(offset: item.start + Int64(count), count: 3)
            let relative = Int64(Int16(bitPattern: UInt16(header[0]) << 8 | UInt16(header[1])))
            let flags = header[2]
            guard flags & 0x0e == 0 else { throw Failure.unsupported } // no laced/invisible blocks
            let (timestamp, overflow) = clusterTime.addingReportingOverflow(relative)
            guard !overflow else { throw Failure.unsupported }
            let offset = item.start + Int64(count + 3)
            let size = item.end - offset
            guard size > 0, size <= UInt32.max, samples.count < WebMVP9Container.maximumSamples else { throw Failure.unsupported }
            samples.append(Sample(offset: offset, size: Int(size), time: try ticks(timestamp),
                duration: duration, sync: simple ? flags & 0x80 != 0 : sync))
        }

        func vp9Configuration(_ sample: Sample) throws -> Data {
            let data = try file.read(offset: sample.offset, count: min(16, sample.size))
            var bit = 0
            func bits(_ count: Int) throws -> UInt32 {
                guard bit + count <= data.count * 8 else { throw Failure.invalid }
                var value: UInt32 = 0
                for _ in 0..<count { value = value << 1 | UInt32((data[bit/8] >> (7-bit%8)) & 1); bit += 1 }
                return value
            }
            guard try bits(2) == 2 else { throw Failure.unsupported }
            let low = try bits(1), high = try bits(1)
            guard low == 0, high == 0, try bits(1) == 0, try bits(1) == 0 else { throw Failure.unsupported }
            _ = try bits(1); _ = try bits(1)
            guard try bits(24) == 0x498342 else { throw Failure.unsupported }
            let colourSpace = try bits(3)
            guard colourSpace != 7 else { throw Failure.unsupported }
            let encodedRange = UInt8(try bits(1))
            let fullRange = range ?? encodedRange
            // FullBox v1; profile 0, undefined level, 8-bit 4:2:0; no codec private bytes.
            return Data([1,0,0,0,0,0,0x82 | fullRange,primaries,transfer,matrix,0,0])
        }
    }

    /// Fast-start ISO-BMFF. Samples remain byte-for-byte identical to the WebM
    /// packets; only sample tables, timestamps and the container are rewritten.
    static func header(_ movie: Movie) throws -> Data {
        let ftyp = box("ftyp", Data("isom".utf8) + be(UInt32(512)) + Data("isomiso6mp41".utf8))
        let initial = moov(movie, mediaOffset: 0)
        guard initial.count <= 32 * 1024 * 1024 else { throw Failure.unsupported }
        let offset = UInt64(ftyp.count + initial.count + 16)
        let metadata = moov(movie, mediaOffset: offset)
        let mediaSize = movie.samples.reduce(UInt64(16)) { $0 + UInt64($1.size) }
        return ftyp + metadata + be(UInt32(1)) + Data("mdat".utf8) + be(mediaSize)
    }
    private static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func box(_ type: String, _ data: Data) -> Data { be(UInt32(data.count + 8)) + Data(type.utf8) + data }
    private static func full(_ type: String, _ flags: UInt32 = 0, _ data: Data) -> Data { box(type, be(flags) + data) }
    private static var matrix: Data {
        [UInt32(0x10000),0,0,0,0x10000,0,0,0,0x40000000].reduce(Data()) { $0 + be($1) }
    }
    private static func moov(_ movie: Movie, mediaOffset: UInt64) -> Data {
        let clock = be(UInt64(0)) + be(UInt64(0)) + be(timescale) + be(movie.duration)
        let mvhd = full("mvhd", 0x01000000, clock + be(UInt32(0x10000)) + be(UInt16(0x100))
            + Data(repeating: 0, count: 10) + matrix + Data(repeating: 0, count: 24) + be(UInt32(2)))
        let tkhd = full("tkhd", 0x01000003, be(UInt64(0)) + be(UInt64(0)) + be(UInt32(1)) + be(UInt32(0))
            + be(movie.duration) + Data(repeating: 0, count: 16) + matrix
            + be(UInt32(movie.width) << 16) + be(UInt32(movie.height) << 16))
        let mdhd = full("mdhd", 0x01000000, clock + be(UInt16(0x55c4)) + be(UInt16(0)))
        let hdlr = full("hdlr", 0, be(UInt32(0)) + Data("vide".utf8) + Data(repeating: 0, count: 12) + Data("Glimmer VP9\0".utf8))
        let vmhd = full("vmhd", 1, Data(repeating: 0, count: 8))
        let dref = full("dref", 0, be(UInt32(1)) + full("url ", 1, Data()))
        let dinf = box("dinf", dref)
        var entry = Data(repeating: 0, count: 6)
        entry.append(be(UInt16(1))); entry.append(Data(repeating: 0, count: 16))
        entry.append(be(UInt16(movie.width))); entry.append(be(UInt16(movie.height)))
        entry.append(be(UInt32(0x480000))); entry.append(be(UInt32(0x480000)))
        entry.append(be(UInt32(0))); entry.append(be(UInt16(1)))
        entry.append(Data(repeating: 0, count: 32)); entry.append(be(UInt16(24))); entry.append(be(UInt16.max))
        let colour = movie.configuration
        let colr = box("colr", Data("nclx".utf8) + be(UInt16(colour[7])) + be(UInt16(colour[8]))
            + be(UInt16(colour[9])) + Data([(colour[6] & 1) << 7]))
        let stsd = full("stsd", 0, be(UInt32(1)) + box("vp09", entry + box("vpcC", movie.configuration) + colr))
        var runs: [(UInt32, UInt32)] = []
        for duration in movie.durations {
            if let last = runs.last, last.1 == duration { runs[runs.count-1].0 += 1 }
            else { runs.append((1, duration)) }
        }
        var times = be(UInt32(runs.count))
        for (count, delta) in runs { times.append(be(count)); times.append(be(delta)) }
        let stts = full("stts", 0, times)
        let stsc = full("stsc", 0, be(UInt32(1)) + be(UInt32(1)) + be(UInt32(1)) + be(UInt32(1)))
        var sizes = be(UInt32(0)) + be(UInt32(movie.samples.count))
        var offsets = be(UInt32(movie.samples.count)), syncs = Data(), syncCount: UInt32 = 0
        var position = mediaOffset
        for (index, sample) in movie.samples.enumerated() {
            sizes.append(be(UInt32(sample.size))); offsets.append(be(position)); position += UInt64(sample.size)
            if sample.sync { syncCount += 1; syncs.append(be(UInt32(index+1))) }
        }
        let stbl = box("stbl", stsd + stts + stsc + full("stsz", 0, sizes) + full("co64", 0, offsets)
            + full("stss", 0, be(syncCount) + syncs))
        let mdia = box("mdia", mdhd + hdlr + box("minf", vmhd + dinf + stbl))
        return box("moov", mvhd + box("trak", tkhd + mdia))
    }
}
