import AVFoundation
import Foundation
import os

/// A video wallpaper in the screen saver: drawn live by the app like a scene or a page
/// (`ScreenSaverLiveVideo`), from the desktop's player when a display already plays it, else from
/// a player of its own. Nothing is linked or copied into the saver's folder.
///
/// WebM (VP8/VP9) isn't one: AVFoundation can't play it, so it is drawn as a page through
/// Chromium (`ScreenSaverLiveWeb`).
enum ScreenSaverVideoSource {
    /// Containers AVFoundation plays.
    static let containers: Set<String> = ["mp4", "m4v", "mov"]

    /// Whether `wallpaper` is a video wallpaper whose local file is in a container AVFoundation
    /// plays. Doesn't read the file.
    static func isEligible(_ wallpaper: WEWallpaper) -> Bool {
        guard wallpaper.project != .invalid,
              wallpaper.project.type.caseInsensitiveCompare("video") == .orderedSame else { return false }
        let url = wallpaper.mediaURL
        return url.isFileURL && containers.contains(url.pathExtension.lowercased())
    }

    /// A video's track as the live draw sizes and paces it.
    struct Info: Equatable, Sendable {
        /// The display size (its transform applied), in pixels.
        var size: SIMD2<Int>
        /// The nominal frame rate; 0 when the file doesn't say.
        var frameRate: Double
    }

    private static let infoCache = OSAllocatedUnfairLock(initialState: [String: Info]())

    /// The cache's key for `url` as it is now (path, size, modification date); nil when it can't be read.
    private static func key(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil } // Optional: unreadable has no info.
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(modified)"
    }

    /// `url`'s track info once `loadInfo` read it, nil before. Doesn't read the file's tracks.
    static func cachedInfo(of url: URL) -> Info? {
        guard let key = key(url) else { return nil }
        return infoCache.withLock { $0[key] }
    }

    /// Reads `url`'s video track (`moov` only) and keeps its info for `cachedInfo`.
    static func loadInfo(of url: URL) async -> Info? {
        guard let key = key(url) else { return nil }
        if let cached = infoCache.withLock({ $0[key] }) { return cached }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, // Optional: no track, no info.
              let (natural, transform, rate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = SIMD2(Int(abs(rect.width).rounded()), Int(abs(rect.height).rounded()))
        guard size.x > 0, size.y > 0 else { return nil }
        let info = Info(size: size, frameRate: Double(rate))
        infoCache.withLock { $0[key] = info }
        return info
    }

    /// Reads the info of `urls` in the background, so the next screen saver sizes and paces their
    /// rings right from the start (`ScreenSaverLiveVideo.ringPixels`, `frameRate`).
    static func prefetchInfo(of urls: [URL]) {
        let missing = urls.filter { cachedInfo(of: $0) == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in missing { _ = await loadInfo(of: url) }
        }
    }
}
