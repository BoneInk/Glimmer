import AVFoundation
import SwiftUI

/// A static frame from an already validated local download. Never starts a player.
struct WorkshopDownloadArtwork: View {
    let remoteURL: URL?
    let localVideoURL: URL?
    var detailSourceKey: String? = nil
    @GlassState private var resolvedImage: NSImage?

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.13, blue: 0.18), Color(red: 0.04, green: 0.05, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let resolvedImage {
                Image(nsImage: resolvedImage).resizable().aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 42, weight: .ultraLight))
                    Text("WORKSHOP")
                        .font(.caption2.weight(.medium))
                        .tracking(2.4)
                }
                .foregroundStyle(.white.opacity(0.18))
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .wallpaperCoverSource(detailSourceKey, image: resolvedImage, remoteURL: remoteURL)
        .accessibilityHidden(true)
        .task(id: [remoteURL, localVideoURL]) {
            resolvedImage = nil
            if let localVideoURL, let frame = await WorkshopDownloadFrameLoader.shared.frame(for: localVideoURL) {
                guard !Task.isCancelled else { return }
                resolvedImage = NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
            } else if let remoteURL, let data = await WorkshopPreviewCache.shared.data(for: remoteURL) {
                guard !Task.isCancelled else { return }
                resolvedImage = NSImage(data: data)
            }
        }
    }
}

/// Generation is isolated from the main actor; memory is bounded by the requested frame size.
private actor WorkshopDownloadFrameLoader {
    static let shared = WorkshopDownloadFrameLoader()

    func frame(for url: URL) async -> CGImage? {
        guard !Task.isCancelled, url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        do {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: .zero)
            try Task.checkCancellation()
            return image
        } catch {
            generator.cancelAllCGImageGeneration()
            return nil
        }
    }
}
