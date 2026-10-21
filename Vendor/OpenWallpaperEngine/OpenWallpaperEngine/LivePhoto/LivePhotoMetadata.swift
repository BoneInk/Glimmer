import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// What pairs a HEIC still and a QuickTime movie into one Live Photo, and what the Lock Screen
/// also needs before it plays one as a wallpaper.
///
/// Pairing (Photos): the same content identifier in the still's Apple maker note (key "17") and in
/// the movie's metadata (`com.apple.quicktime.content.identifier`), and a timed metadata sample
/// marking the still's moment (`com.apple.quicktime.still-image-time`).
///
/// Wallpaper motion: without more, iOS 17 and later import the pair as a Live Photo but its Lock
/// Screen says "Motion Not Available". The camera's movies carry two timed metadata tracks, which
/// Apple doesn't document, and the Lock Screen wants both, laid out as the camera writes them:
/// - `com.apple.quicktime.live-photo-info`, one sample a video frame (`infoSample`);
/// - `still-image-time` (-1) with `com.apple.quicktime.live-photo-still-image-transform` (an
///   identity 3 × 3 matrix) in one sample at the still's frame, in the 600 timescale (`stillSample`).
/// Both describe the video track (a `cdsc` track reference). The layout and the camera's reference
/// values are LivePaper's measurements on an iPhone (Yuyang Zeng, MIT; notice
/// below), as Glitter Live also writes them (github.com/BuddhaNag12/glitter-live, MIT).
enum LivePhotoMetadata {
    static let makerNoteIdentifierKey = "17"
    static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    static let stillImageTimeIdentifier = "mdta/" + stillImageTimeKey
    static let stillImageTransformKey = "com.apple.quicktime.live-photo-still-image-transform"
    static let infoKey = "com.apple.quicktime.live-photo-info"
    /// The doubled prefix is what the camera writes.
    static let infoDataType = "com.apple.quicktime.com.apple.quicktime.live-photo-info"
    /// The metadata samples' timescale, the camera's. At the video's own (30) timescale the writer
    /// drops the empty edit that delays the still's sample, and the still lands at 0 s.
    static let timescale: CMTimeScale = 600
    /// The still-image-time value the camera writes.
    static let stillImageTimeValue: Int8 = -1
    static let stillQuality = 0.95

    enum Failure: Error { case heicDestination, heicWrite, metadataFormat, sample }

    /// The two metadata inputs of a wallpaper-ready movie and their formats.
    struct Tracks {
        let info: AVAssetWriterInput
        let infoFormat: CMFormatDescription
        let still: AVAssetWriterInput
        let stillFormat: CMFormatDescription
    }

    // MARK: Writing

    /// Writes `image` as a HEIC carrying `identifier` in its maker note.
    static func writeStill(_ image: CGImage, to url: URL, identifier: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure.heicDestination
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: [makerNoteIdentifierKey: identifier],
            kCGImageDestinationLossyCompressionQuality: stillQuality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.heicWrite }
    }

    /// The movie-level item naming the Live Photo.
    static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = contentIdentifierKey as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// Adds the `live-photo-info` and still-image-time tracks to `writer`, before it starts, each
    /// referring to its video input.
    static func addTracks(to writer: AVAssetWriter) throws -> Tracks {
        let infoFormat = try infoFormatDescription(), stillFormat = try stillFormatDescription()
        let info = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: infoFormat)
        let still = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillFormat)
        let video = writer.inputs.first { $0.mediaType == .video }
        let referent = AVAssetTrack.AssociationType.metadataReferent.rawValue
        for input in [info, still] {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.metadataFormat }
            writer.add(input)
            if let video, input.canAddTrackAssociation(withTrackOf: video, type: referent) {
                input.addTrackAssociation(withTrackOf: video, type: referent)
            }
        }
        return Tracks(info: info, infoFormat: infoFormat, still: still, stillFormat: stillFormat)
    }

    /// The movie time of frame `index`, in `timescale`.
    static func time(ofFrame index: Int, frameRate: Int) -> CMTime {
        CMTimeConvertScale(CMTime(value: CMTimeValue(index), timescale: CMTimeScale(max(frameRate, 1))), timescale: timescale,
                           method: .roundHalfAwayFromZero)
    }

    /// The still-image-time sample at `time`: -1 and an identity transform, 1/600 s long.
    static func stillSample(format: CMFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
        var identity = Data()
        for value in [1.0, 0, 0, 0, 1, 0, 0, 0, 1] { identity.appendBigEndian(value.bitPattern) }
        let payload = Atom.make(keyID: 1, Data([UInt8(bitPattern: stillImageTimeValue)])) + Atom.make(keyID: 2, identity)
        return try sample(payload, format: format, time: time, duration: CMTime(value: 1, timescale: timescale))
    }

    /// The `live-photo-info` sample of the frame at `time`, `duration` long: the camera's record.
    static func infoSample(format: CMFormatDescription, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        try sample(Atom.make(keyID: 1, cameraInfoPayload), format: format, time: time, duration: duration)
    }

    // MARK: Formats

    /// `live-photo-info`'s sample description: its key, its reverse-DNS data type, the camera's
    /// setup (a version plist and its capture size) and raw samples.
    static func infoFormatDescription() throws -> CMFormatDescription {
        var dimensions = Data()
        dimensions.appendBigEndian(cameraDimensions.width)
        dimensions.appendBigEndian(cameraDimensions.height)
        let setup = Atom.make("cfgv", cameraSetupPlist) + Atom.make("dims", dimensions)
        let key = keyDeclaration(infoKey)
            + Atom.make("dtyp", reverseDNSType(infoDataType))
            + Atom.make("setu", setup)
            + Atom.make("ctps", Atom.make("dtyp", wellKnownType(rawDataType)))
        return try formatDescription(keys: Atom.make(keyID: 1, key))
    }

    /// The still sample's description: still-image-time (int8) and the still's transform (a 3 × 3
    /// float64 matrix).
    static func stillFormatDescription() throws -> CMFormatDescription {
        let time = keyDeclaration(stillImageTimeKey) + Atom.make("dtyp", wellKnownType(int8DataType))
        let transform = keyDeclaration(stillImageTransformKey) + Atom.make("dtyp", wellKnownType(float64MatrixDataType))
        return try formatDescription(keys: Atom.make(keyID: 1, time) + Atom.make(keyID: 2, transform))
    }

    /// QuickTime well-known data types.
    private static let rawDataType: UInt32 = 0
    private static let int8DataType: UInt32 = 0x41
    private static let float64MatrixDataType: UInt32 = 0x53

    private static func keyDeclaration(_ key: String) -> Data {
        Atom.make("keyd", Data("mdta".utf8) + Data(key.utf8))
    }

    private static func wellKnownType(_ type: UInt32) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(type)
        return data
    }

    private static func reverseDNSType(_ type: String) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(1))
        data.append(Data(type.utf8))
        return data
    }

    /// A `mebx` sample description: 6 reserved bytes, data reference index 1, the key table.
    private static func formatDescription(keys: Data) throws -> CMFormatDescription {
        var body = Data(count: 6)
        body.appendBigEndian(UInt16(1))
        body.append(Atom.make("keys", keys))
        let data = Atom.make("mebx", body)
        var description: CMFormatDescription?
        let status = data.withUnsafeBytes { buffer in
            CMMetadataFormatDescriptionCreateFromBigEndianMetadataDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianMetadataDescriptionData: buffer.bindMemory(to: UInt8.self).baseAddress!,
                size: data.count, flavor: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw Failure.metadataFormat }
        return description
    }

    private static func sample(_ bytes: Data, format: CMFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.sample }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw Failure.sample }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.sample }
        return sample
    }

    // MARK: Camera reference values

    /// The camera's capture size in `live-photo-info`'s setup, kept whatever the movie's size.
    private static let cameraDimensions = (width: UInt32(1920), height: UInt32(1440))

    /// A binary plist naming iPhone OS 17.0 (21A5277h) and the capture frameworks' versions.
    private static let cameraSetupPlist = Data(hex:
        "62706c6973743030d301020304050c5f10214c69766550686f746f4d65746164"
        + "61746153657475704461746156657273696f6e5d53797374656d56657273696f"
        + "6e5f10114672616d65776f726b56657273696f6e731001d3060708090a0b5f10"
        + "1350726f647563744275696c6456657273696f6e5b50726f647563744e616d65"
        + "5e50726f6475637456657273696f6e583231413532373768596950686f6e6520"
        + "4f535431372e30d40d0e0f10111213145a436f72654d6f74696f6e5d434d4361"
        + "7074757265436f72655e483130495350536572766963657359436f72654d6564"
        + "696158323836382e302e32573434362e352e335432302e325e333034352e3639"
        + "2e322e31312e340008000f0033004100550057005e00740080008f009800a200"
        + "a700b000bb00c900d800e200eb00f300f8000000000000020100000000000000"
        + "1500000000000000000000000000000107")

    /// One camera-info record (136 bytes; 144 with its key header, as in the camera's samples),
    /// repeated in every frame.
    static let cameraInfoPayload = Data(hex:
        "03000000bdc36d3ce3b5eb6d800000007b80ad425a2d64410a08cb3e7feea6bd"
        + "79e9f63f000080400400ff000000000000000000000000000000000000000000"
        + "07000000525e873ee66e52bf1b2a6ac4d37862bf761ed23dde3f8ec313f52f39"
        + "b2f04439ff309dbf1a17f1ed1b070000206796ed1b0700000000000000000000"
        + "0000000000000000")

    // MARK: Reading

    /// The identifier in a still's maker note.
    static func stillIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        return maker[makerNoteIdentifierKey] as? String
    }

    /// The identifier in a movie's metadata.
    static func movieIdentifier(at url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let items = try await asset.loadMetadata(for: .quickTimeMetadata)
        for item in items where item.identifier?.rawValue == "mdta/" + contentIdentifierKey {
            return try await item.load(.stringValue)
        }
        return nil
    }

    /// The time the movie's still-image-time sample marks.
    static func movieStillImageTime(at url: URL) async throws -> CMTime? {
        let asset = AVURLAsset(url: url)
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let formats = try await track.load(.formatDescriptions)
            guard formats.contains(where: { identifiers(of: $0).contains(stillImageTimeIdentifier) }) else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                if group.items.contains(where: { $0.identifier?.rawValue == stillImageTimeIdentifier }) {
                    reader.cancelReading()
                    return group.timeRange.start
                }
            }
        }
        return nil
    }

    /// The metadata identifiers a track's format declares.
    static func identifiers(of format: CMFormatDescription) -> [String] {
        (CMMetadataFormatDescriptionGetIdentifiers(format) as? [String]) ?? []
    }
}

/// QuickTime atoms: `[size: UInt32][type: 4 bytes][payload]`.
private enum Atom {
    static func make(_ fourCC: String, _ payload: Data) -> Data {
        var atom = Data()
        atom.appendBigEndian(UInt32(8 + payload.count))
        atom.append(Data(fourCC.utf8))
        atom.append(payload)
        return atom
    }

    /// Key tables and metadata samples put the local key ID in place of the type.
    static func make(keyID: UInt32, _ payload: Data) -> Data {
        var atom = Data()
        atom.appendBigEndian(UInt32(8 + payload.count))
        atom.appendBigEndian(keyID)
        atom.append(payload)
        return atom
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

// LivePaper's notice, for the metadata layout and camera reference values above:
//
// MIT License
//
// Copyright (c) 2026 Yuyang Zeng
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
