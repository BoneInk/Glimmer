import Darwin
import CryptoKit
import Foundation

@main enum WebMContainerTests {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--inspect-real" {
            let url = URL(fileURLWithPath:CommandLine.arguments[2]).resolvingSymlinksInPath()
            let cache = URL(fileURLWithPath:CommandLine.arguments[3]).resolvingSymlinksInPath()
            let source = try LocalWallpaperFileResource(file:url,root:url.deletingLastPathComponent())
            let clock = ContinuousClock.now
            let movie = try WebMVP9Container.inspect(source)
            let result = try WebWallpaperMediaResolver(cacheRoot:cache).resolve(source,extension:"webm",cancelled:{false})!
            let elapsed = clock.duration(to:.now)
            var sourceHash = SHA256(), targetHash = SHA256()
            for sample in movie.samples {
                var offset=sample.offset,remaining=sample.size
                while remaining>0 {
                    let n=min(65536,remaining);sourceHash.update(data:try source.read(offset:offset,count:n));offset+=Int64(n);remaining-=n
                }
            }
            var offset=Int64(try WebMVP9Container.header(movie).count)
            while offset<result.file.size {
                let n=Int(min(65536,result.file.size-offset));targetHash.update(data:try result.file.read(offset:offset,count:n));offset+=Int64(n)
            }
            let before=sourceHash.finalize().map{String(format:"%02x",$0)}.joined()
            let after=targetHash.finalize().map{String(format:"%02x",$0)}.joined()
            let report:[String:Any]=["width":movie.width,"height":movie.height,"frames":movie.samples.count,
                "duration":Double(movie.duration)/Double(WebMVP9Container.timescale),"sourcePacketSHA256":before,
                "outputPacketSHA256":after,"encodedVideoByteIdentical":before==after,"prepareSeconds":Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18,
                "sourceBytes":source.size,"outputBytes":result.file.size,"mime":result.mime]
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self));return
        }
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); count += 1; print("PASS \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { check(true, name) }
        }
        func number(_ value: UInt64, bytes: Int = 1) -> Data {
            Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func size(_ value: UInt64) -> Data {
            for n in 1...8 where value < (UInt64(1) << (n * 7)) - 1 {
                return number(value | UInt64(1) << (n * 7), bytes: n)
            }
            preconditionFailure("fixture size")
        }
        func element(_ id: UInt64, _ payload: Data) -> Data {
            let n = max(1, (64 - id.leadingZeroBitCount + 7) / 8)
            return number(id, bytes: n) + size(UInt64(payload.count)) + payload
        }
        let keyframe = Data([0x82,0x49,0x83,0x42,0,31,0,23,0,0xaa])
        let delta = Data([0x86,0x11,0x22,0x33,0x44])
        func fixture(codec: String = "V_VP9", extraTrack: Bool = false, flags: UInt8 = 0,
                     alpha: Bool = false, timestamps: [Int] = [0,17,33,50], hugeWidth: Bool = false,
                     unknownCluster: Bool = false) -> Data {
            let ebml = element(0x1a45dfa3, element(0x4282, Data("webm".utf8)))
            let info = element(0x1549a966, element(0x2ad7b1, number(1_000_000, bytes: 3)))
            var video = element(0xb0, hugeWidth ? number(UInt64.max, bytes: 8) : number(32)) + element(0xba, number(24))
            if alpha { video += element(0x53c0, number(1)) }
            let track = element(0xae, element(0xd7, number(1)) + element(0x83, number(1))
                + element(0x86, Data(codec.utf8)) + element(0x23e383, number(16_666_667, bytes: 4)) + element(0xe0, video))
            let audio = extraTrack ? element(0xae, element(0xd7,number(2)) + element(0x83,number(2)) + element(0x86,Data("A_OPUS".utf8))) : Data()
            let tracks = element(0x1654ae6b, track + audio)
            var blocks = element(0xe7, number(0))
            for (index, time) in timestamps.enumerated() {
                blocks += element(0xa3, Data([0x81]) + number(UInt64(UInt16(bitPattern: Int16(time))), bytes: 2)
                    + Data([index == 0 ? 0x80 | flags : flags]) + (index == 0 ? keyframe : delta))
            }
            let cluster = unknownCluster ? number(0x1f43b675,bytes:4) + Data([0xff]) + blocks : element(0x1f43b675, blocks)
            return ebml + element(0x18538067, info + tracks + cluster)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glimmer-webm-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func resource(_ bytes: Data, name: String = UUID().uuidString) throws -> LocalWallpaperFileResource {
            let url = root.appendingPathComponent(name + ".webm"); try bytes.write(to: url)
            return try LocalWallpaperFileResource(file: url, root: root)
        }
        let original = fixture(), source = try resource(original, name: "source")
        let movie = try WebMVP9Container.inspect(source)
        check(movie.width == 32 && movie.height == 24 && movie.samples.count == 4, "track geometry and sample count are retained")
        check(movie.durations == [17000,16000,17000,16666], "variable timestamps and final sample duration are retained")
        check(try source.read(offset: movie.samples[0].offset, count: movie.samples[0].size) == keyframe, "demux preserves the exact encoded keyframe")
        let cache = root.appendingPathComponent("cache",isDirectory:true)
        let resolver = WebWallpaperMediaResolver(cacheRoot: cache)
        let prepared = try resolver.resolve(source, extension: "webm", cancelled: { false })!
        let output = try prepared.file.readDocument(maximumBytes: 1024 * 1024)
        check(prepared.mime == "video/mp4" && output.subdata(in: 4..<8) == Data("ftyp".utf8), "resource MIME agrees with the new container")
        let marker = output.range(of: Data("mdat".utf8))!
        check(output.subdata(in: marker.upperBound+8..<output.count) == keyframe + delta + delta + delta, "every compressed packet is byte-identical after remux")
        check(try Data(contentsOf:root.appendingPathComponent("source.webm")) == original, "author media is not modified")
        let reused = try resolver.resolve(source, extension: "WEBM", cancelled: { false })!
        check(reused.file.fingerprint == prepared.file.fingerprint, "range requests reuse the prepared inode")
        let entry = try FileManager.default.contentsOfDirectory(at: cache,includingPropertiesForKeys:nil).first!
        try Data([1,2,3]).write(to: entry)
        let rebuilt = try resolver.resolve(source, extension: "webm", cancelled: { false })!
        check(rebuilt.file.size == Int64(output.count), "a truncated cache is atomically rebuilt")
        let fresh = try WebWallpaperMediaResolver(cacheRoot: cache).resolve(source, extension: "webm", cancelled: { false })!
        check(fresh.file.fingerprint == rebuilt.file.fingerprint, "content-addressed output is reused across runtime instances")
        check(try resolver.resolve(source, extension: "mp4", cancelled: { false }) == nil, "existing MP4 media bypasses the adapter")
        for (name, bytes) in [("audio",fixture(extraTrack:true)),("VP8",fixture(codec:"V_VP8")),("alpha",fixture(alpha:true)),
                              ("lacing",fixture(flags:2)),("invisible",fixture(flags:8)),("backwards clock",fixture(timestamps:[0,17,16,50])),
                              ("duplicate clock",fixture(timestamps:[0,17,17,50])),("overflow geometry",fixture(hugeWidth:true))] {
            let unsupported = try resource(bytes)
            check(try resolver.resolve(unsupported, extension: "webm", cancelled: { false }) == nil, "\(name) is never silently dropped or changed")
        }
        let streaming = try WebMVP9Container.inspect(resource(fixture(unknownCluster:true)))
        check(streaming.samples.count == 4, "unknown-sized WebM clusters are bounded correctly")
        rejects("cancellation prevents cache work") { _ = try resolver.resolve(source,extension:"webm",cancelled:{true}) }
        let symlinkRoot = root.appendingPathComponent("unsafe-cache")
        try FileManager.default.createSymbolicLink(at:symlinkRoot,withDestinationURL:cache)
        rejects("cache-root symlinks cannot redirect media writes") {
            _ = try WebWallpaperMediaResolver(cacheRoot:symlinkRoot).resolve(source,extension:"webm",cancelled:{false})
        }
        for length in 0..<original.count {
            let truncated = try resource(Data(original.prefix(length)))
            rejects("truncated container \(length) fails safely") { _ = try WebMVP9Container.inspect(truncated) }
        }
        // A large legal Void is skipped by the parser and hashed in 64-KiB
        // chunks. It must not inherit the old HTML-document allocation limit.
        let large = root.appendingPathComponent("large.webm")
        let segment = original.range(of: Data([0x18,0x53,0x80,0x67]))!
        let prefix = Data(original[..<segment.lowerBound]) + Data([0x18,0x53,0x80,0x67,0xff,0xec]) + size(300*1024*1024)
        FileManager.default.createFile(atPath:large.path,contents:prefix)
        let handle = try FileHandle(forWritingTo:large)
        let offset = UInt64(prefix.count)+300*1024*1024
        try handle.truncate(atOffset:offset); try handle.seek(toOffset:offset)
        // Skip the original Segment header, retaining its Info/Tracks/Cluster.
        let lengthByte = original[segment.upperBound], lengthBytes = lengthByte.leadingZeroBitCount+1
        try handle.write(contentsOf:original.subdata(in:segment.upperBound+lengthBytes..<original.count));try handle.close()
        let largeSource = try LocalWallpaperFileResource(file:large,root:root)
        let largeResult = try resolver.resolve(largeSource,extension:"webm",cancelled:{false})!
        check(largeResult.file.size == Int64(output.count), "a 300-MiB WebM resource remuxes with bounded binary reads")
        try Data([0]).write(to:root.appendingPathComponent("source.webm"))
        rejects("a changed source cannot reuse a stale mapping") { _ = try resolver.resolve(source,extension:"webm",cancelled:{false}) }
        print("RESULT \(count) WebM container/cache checks passed")
    }
}
