//
//  PKGParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine PKGV archive files (scene.pkg), and WE's mobile packages (`.mpkg`,
//  "PKGM0014", written by `MobilePackageWriter`), which use the same layout.
//  Format: length-prefixed "PKGVxxxx" header, entry count,
//  then per entry: length-prefixed path + offset + length.
//  File data follows contiguously after the header table.
//

import Foundation

struct PKGEntry: Equatable {
    let path: String
    let offset: UInt32
    let length: UInt32
}

class PKGParser {
    private let data: Data
    private let entries: [PKGEntry]
    private let entriesByPath: [String: PKGEntry]
    private let dataBaseOffset: Int
    /// The header's magic and version (`PKGV0019`, `PKGM0014`).
    let header: String

    /// `magic` is the header's prefix: `PKGV` for a scene.pkg, `PKGM` for a mobile package.
    init(data: Data, magic: String = "PKGV") throws {
        self.data = data
        let (parsedEntries, parsedHeader, baseOffset): ([PKGEntry], String, Int) = try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var cursor = 0

            func readUInt32() throws -> UInt32 {
                guard cursor + 4 <= bytes.count else { throw PKGError.unexpectedEndOfFile }
                defer { cursor += 4 }
                return UInt32(bytes[cursor])
                    | (UInt32(bytes[cursor + 1]) << 8)
                    | (UInt32(bytes[cursor + 2]) << 16)
                    | (UInt32(bytes[cursor + 3]) << 24)
            }

            func readString(length: Int) throws -> String {
                guard length >= 0, cursor + length <= bytes.count else { throw PKGError.unexpectedEndOfFile }
                defer { cursor += length }
                let slice = bytes[cursor..<(cursor + length)]
                return String(bytes: slice, encoding: .utf8)
                    ?? String(bytes: slice, encoding: .isoLatin1)
                    ?? ""
            }

            let headerLength = try readUInt32()
            guard headerLength < 100 else {
                throw PKGError.invalidMagic("(header too long: \(headerLength))", expected: magic)
            }
            let header = try readString(length: Int(headerLength))
            guard header.hasPrefix(magic) else { throw PKGError.invalidMagic(header, expected: magic) }

            let entryCount = try readUInt32()
            guard entryCount < 100_000 else { throw PKGError.unexpectedEndOfFile }
            var entries: [PKGEntry] = []
            entries.reserveCapacity(Int(entryCount))
            for _ in 0..<entryCount {
                let pathLength = try readUInt32()
                guard pathLength < 10_000 else { throw PKGError.unexpectedEndOfFile }
                entries.append(PKGEntry(path: try readString(length: Int(pathLength)),
                                        offset: try readUInt32(), length: try readUInt32()))
            }
            return (entries, header, cursor)
        }
        self.entries = parsedEntries
        self.header = parsedHeader
        self.entriesByPath = Dictionary(parsedEntries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.dataBaseOffset = baseOffset
    }

    convenience init(url: URL, magic: String = "PKGV") throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data, magic: magic)
    }

    var fileList: [String] {
        entries.map(\.path)
    }

    func extractFile(named name: String) -> Data? {
        guard let entry = entriesByPath[name] else { return nil }
        let start = dataBaseOffset + Int(entry.offset)
        let end = start + Int(entry.length)
        guard end <= data.count else { return nil }
        return data[start..<end]
    }

    func extractJSON<T: Decodable>(named name: String, as type: T.Type) throws -> T? {
        guard let fileData = extractFile(named: name) else { return nil }
        return try JSONDecoder().decode(type, from: fileData)
    }
}

enum PKGError: Error, LocalizedError {
    case invalidMagic(String, expected: String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .invalidMagic(let got, let expected):
            return "Invalid PKG header: expected \(expected)*, got '\(got)'"
        case .unexpectedEndOfFile:
            return "Unexpected end of PKG file"
        }
    }
}
