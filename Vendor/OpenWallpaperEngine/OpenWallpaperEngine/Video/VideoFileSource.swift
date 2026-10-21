import AVFoundation
import UniformTypeIdentifiers

/// The file a video wallpaper plays, read as WE's "Video loading" setting says (`GSVideoReadMode`).
///
/// From disk, each player item opens the file. AVFoundation reads it past the buffer cache, so
/// every loop reads the whole file from its disk again: a 137 MB 4K loop of 27.6 s read 143 MB per
/// loop, about 5 MB/s for as long as it plays, keeping a hard disk spinning or a network volume
/// busy. In memory, the file is read once and the items read it from memory through a resource
/// loader (`MemoryVideoLoader`): nothing is read from the disk after that, for the cost of the
/// file's size in memory (about 200 MB for that video, against 18 MB from disk).
///
/// The source must outlive its items: an asset holds its resource loader's delegate weakly.
final class VideoFileSource {
    let url: URL
    private let loader: MemoryVideoLoader?

    /// Opens `url`. In memory, the whole file is read now, so call it off the main thread. A file
    /// that can't be read plays from disk, which then reports the error itself.
    init(url: URL, mode: GSVideoReadMode) {
        self.url = url
        guard mode == .inMemory else {
            loader = nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            OWELog.error(.library, "Video \(url.lastPathComponent) could not be read into memory, playing it from disk: \(error)")
            loader = nil
            return
        }
        OWELog.info(.library, "Video \(url.lastPathComponent) loaded into memory (\(data.count) bytes)")
        loader = MemoryVideoLoader(data: data, contentType: Self.contentType(of: url))
    }

    /// Whether the items read from memory.
    var isInMemory: Bool { loader != nil }

    /// A new player item of the video.
    func makeItem() -> AVPlayerItem {
        guard let loader else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: loader.assetURL(named: url.lastPathComponent))
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return AVPlayerItem(asset: asset)
    }

    /// The file's type as AVFoundation wants it (a UTI); MPEG-4 when the extension says nothing.
    static func contentType(of url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) else {
            return UTType.mpeg4Movie.identifier
        }
        return type.identifier
    }
}

/// Serves a video's bytes from memory to AVFoundation (`VideoFileSource`, in memory). Answers
/// each request at once and in full, so no request is ever pending; the bytes handed out share
/// the file's memory instead of copying it, and keep it alive while AVFoundation holds them.
final class MemoryVideoLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "owe-memory-video"
    /// Responses are at most this long, so AVFoundation can start on a large request early.
    static let chunkLength = 1 << 20

    let queue = DispatchQueue(label: "com.owe.video.memory-loader", qos: .userInitiated)
    private let storage: Storage
    private let contentType: String
    private let identifier = UUID()

    /// Owns the file's bytes; every response points into them and holds it.
    private final class Storage {
        let data: Data
        let base: UnsafeMutableRawPointer?

        init(data: Data) {
            self.data = data
            base = data.withUnsafeBytes { $0.baseAddress.map(UnsafeMutableRawPointer.init(mutating:)) }
        }
    }

    init(data: Data, contentType: String) {
        storage = Storage(data: data)
        self.contentType = contentType
    }

    var byteCount: Int { storage.data.count }

    /// The URL an asset reads this video through; its scheme sends every read to this loader.
    func assetURL(named name: String) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = identifier.uuidString
        components.path = "/" + name
        // A scheme, a UUID host and a path always make a URL.
        return components.url!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = Int64(byteCount)
            information.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            guard let range = Self.range(of: dataRequest, length: byteCount) else {
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorDataLengthExceedsMaximum))
                return true
            }
            var offset = range.lowerBound
            while offset < range.upperBound {
                let end = min(range.upperBound, offset + Self.chunkLength)
                dataRequest.respond(with: bytes(offset..<end))
                offset = end
            }
        }
        loadingRequest.finishLoading()
        return true
    }

    /// The bytes a data request asks for, clamped to the file; nil when it starts past the end.
    static func range(of request: AVAssetResourceLoadingDataRequest, length: Int) -> Range<Int>? {
        range(offset: request.requestedOffset, length: request.requestedLength,
              toEnd: request.requestsAllDataToEndOfResource, fileLength: length)
    }

    static func range(offset: Int64, length: Int, toEnd: Bool, fileLength: Int) -> Range<Int>? {
        guard offset >= 0, offset <= Int64(fileLength) else { return nil }
        let start = Int(offset)
        let end = toEnd ? fileLength : min(fileLength, start + max(length, 0))
        return start..<end
    }

    /// `range` of the file without copying it.
    func bytes(_ range: Range<Int>) -> Data {
        guard let base = storage.base, !range.isEmpty else { return Data() }
        let storage = self.storage
        return Data(bytesNoCopy: base + range.lowerBound, count: range.count,
                    deallocator: .custom { _, _ in withExtendedLifetime(storage) {} })
    }
}
