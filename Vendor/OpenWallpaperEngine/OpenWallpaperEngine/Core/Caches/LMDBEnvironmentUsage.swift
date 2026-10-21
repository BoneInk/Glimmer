import Foundation

/// How full an LMDB environment is, read from its data file's meta pages: Metal keeps the usage
/// records of its shader cache in one (`com.apple.metal/archiveUsage.db`) with a 1 MiB map, and
/// once the file reaches the map every commit fails (`MDB_MAP_FULL: Environment mapsize limit
/// reached`) until the cache is deleted.
///
/// LMDB's file starts with two meta pages (`MDB_page` header, 16 bytes, then `MDB_meta`):
/// magic `0xBEEFC0DE`, version, the map address, `mm_mapsize`, the two `MDB_db` records (48 bytes
/// each; the free list's `md_pad` holds the page size), `mm_last_pg` and `mm_txnid`. The meta with
/// the higher transaction id is the current one. Only these 32 KiB at most are read.
struct LMDBEnvironmentUsage: Equatable {
    static let magic: UInt32 = 0xBEEF_C0DE
    /// Full: the used pages reach this share of the map, the point past which Metal's commits fail.
    static let fullShare = 0.9

    var mapSize: Int
    var pageSize: Int
    /// The pages up to the last one used, in bytes.
    var usedBytes: Int

    var isNearlyFull: Bool { mapSize > 0 && Double(usedBytes) >= Double(mapSize) * Self.fullShare }

    /// The usage of the environment whose data file is `url`; nil when it can't be read or isn't LMDB.
    static func read(dataFile url: URL) -> LMDBEnvironmentUsage? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil // Optional: no file, no environment.
        }
        defer { try? handle.close() } // Read-only handle: nothing to flush.
        // Optional: a short or unreadable file is no environment.
        guard let head = try? handle.read(upToCount: 2 * 16384) else { return nil }
        return parse(head)
    }

    /// The usage from the file's first bytes (both meta pages).
    static func parse(_ data: Data) -> LMDBEnvironmentUsage? {
        guard let first = meta(in: data, at: 0) else { return nil }
        var best = first
        if first.pageSize > 0, let second = meta(in: data, at: first.pageSize), second.txnid > first.txnid {
            best = second
        }
        guard best.pageSize > 0, best.mapSize > 0 else { return nil }
        return LMDBEnvironmentUsage(mapSize: best.mapSize, pageSize: best.pageSize,
                                    usedBytes: (best.lastPage + 1) * best.pageSize)
    }

    private struct Meta {
        var mapSize: Int
        var pageSize: Int
        var lastPage: Int
        var txnid: UInt64
    }

    private static func meta(in data: Data, at offset: Int) -> Meta? {
        let start = offset + 16 // past MDB_page's header
        guard data.count >= start + 136 else { return nil }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        func u64(_ at: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) } }
        guard UInt32(littleEndian: u32(start)) == magic else { return nil }
        let mapSize = UInt64(littleEndian: u64(start + 16))
        let pageSize = UInt32(littleEndian: u32(start + 24))
        let lastPage = UInt64(littleEndian: u64(start + 24 + 96))
        let txnid = UInt64(littleEndian: u64(start + 32 + 96))
        guard mapSize < UInt64(Int.max), lastPage < UInt64(Int.max / 65536), pageSize <= 65536 else { return nil }
        return Meta(mapSize: Int(mapSize), pageSize: Int(pageSize), lastPage: Int(lastPage), txnid: txnid)
    }
}
