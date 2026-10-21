import AppKit
import ImageIO
import os

/// The Workshop cards' preview images, downloaded once and decoded at card size: paging back and
/// forth shows them from memory instead of downloading and decoding full-size previews again.
/// Owned by `WorkshopViewModel`, so the Workshop and Discover tabs share one cache.
///
/// The cache keeps the most recently used thumbnails up to `memoryLimit` bytes and empties only
/// under critical memory pressure (a thumbnail costs a download and a decode to rebuild). It is
/// not an `NSCache`, which may drop entries whenever the system wants memory, so a card shown a
/// moment ago could flash its placeholder and download again.
///
/// `@unchecked Sendable`: the cache is behind a lock, and nothing else is mutable.
final class WorkshopThumbnailLoader: @unchecked Sendable {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var lastUse: UInt64
    }

    private struct Cache {
        var entries: [URL: Entry] = [:]
        var totalCost = 0
        var clock: UInt64 = 0
    }

    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    private let session: URLSession
    private let memoryLimit: Int
    private var memoryPressure: SceneMemoryPressure?
    /// The longer side of a decoded thumbnail, in pixels: a card at its largest on a Retina display.
    let maxPixelSize: Int

    init(session: URLSession = .shared, maxPixelSize: Int = 640, memoryLimit: Int = 96 * 1024 * 1024) {
        self.session = session
        self.maxPixelSize = maxPixelSize
        self.memoryLimit = memoryLimit
        memoryPressure = SceneMemoryPressure(queue: .global(qos: .utility)) { [weak self] level in
            if level == .critical { self?.removeAll() }
        }
    }

    /// The thumbnail already in memory, for drawing without waiting.
    func cachedImage(for url: URL) -> NSImage? {
        cache.withLock { cache in
            guard var entry = cache.entries[url] else { return nil }
            cache.clock += 1
            entry.lastUse = cache.clock
            cache.entries[url] = entry
            return entry.image
        }
    }

    /// Empties the cache.
    func removeAll() {
        cache.withLock { $0 = Cache() }
    }

    /// Keeps `image`, dropping the least recently used thumbnails while the total is over the limit.
    private func store(_ image: NSImage, cost: Int, for url: URL) {
        cache.withLock { cache in
            cache.clock += 1
            if let old = cache.entries.updateValue(Entry(image: image, cost: cost, lastUse: cache.clock), forKey: url) {
                cache.totalCost -= old.cost
            }
            cache.totalCost += cost
            while cache.totalCost > memoryLimit, cache.entries.count > 1,
                  let oldest = cache.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                cache.entries[oldest.key] = nil
                cache.totalCost -= oldest.value.cost
            }
        }
    }

    /// The thumbnail of the image at `url`; nil (logged) when it can't be downloaded or decoded.
    /// A load the card no longer needs still finishes into the cache.
    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        let task = Task.detached(priority: .utility) { [session, maxPixelSize] () -> CGImage? in
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    OWELog.debug(.workshop, "Workshop preview \(url.absoluteString) answered HTTP \(http.statusCode)")
                    return nil
                }
                return Self.downsample(data, maxPixelSize: maxPixelSize)
            } catch {
                OWELog.debug(.workshop, "Workshop preview \(url.absoluteString) didn't load: \(error.localizedDescription)")
                return nil
            }
        }
        guard let cgImage = await task.value else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, cost: cgImage.bytesPerRow * cgImage.height, for: url)
        return image
    }

    /// `data` decoded with its longer side at most `maxPixelSize` pixels, or nil when it isn't an image.
    static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
