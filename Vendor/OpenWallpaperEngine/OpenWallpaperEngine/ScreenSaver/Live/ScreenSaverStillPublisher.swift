import AVFoundation
import CoreGraphics
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Keeps the savers' still pictures (`ScreenSaverStills`) the lock screen's: each time a display's
/// desktop picture is written (`DesktopPictureSync.onPictureWritten`), it is hard-linked into the
/// shared folder (copied when the folders are on different volumes) under the display's name,
/// replacing the earlier one in one rename, and listed in `stills.json`. Only the user's own copy
/// writes them (an isolated copy never installs the saver). Main thread.
@MainActor
final class ScreenSaverStillPublisher {
    let folder: URL
    private let fileManager = FileManager.default

    init(folder: URL) {
        self.folder = folder
    }

    static var current: ScreenSaverStillPublisher {
        ScreenSaverStillPublisher(folder: ScreenSaverVideoStore.current.directory)
    }

    nonisolated static let pickFileName = "still-pick.jpg"

    /// `image` is the picked wallpaper's picture (its preview when it is picked, then a frame of
    /// its live draw): shown on every display while it is picked. Encoded off the main thread.
    func publishPick(_ image: CGImage) {
        let folder = folder
        DispatchQueue.global(qos: .utility).async {
            let staging = folder.appending(path: ".\(UUID().uuidString)-\(Self.pickFileName)", directoryHint: .notDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination),
                      rename(staging.path(percentEncoded: false),
                             folder.appending(path: Self.pickFileName).path(percentEncoded: false)) == 0
                else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                try? FileManager.default.removeItem(at: staging) // Optional: the failed attempt's leftover.
                OWELog.error(.app, "Screen saver: can't keep the picked wallpaper's still: \(error)")
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.list(pick: Self.pickFileName) }
            }
        }
    }

    /// Back to the desktop's stills.
    func clearPick() {
        list(pick: nil)
        try? FileManager.default.removeItem(at: folder.appending(path: Self.pickFileName)) // Optional: may not exist.
    }

    /// The picked wallpaper's first picture, until a frame of it is drawn
    /// (`ScreenSaverLiveController.renderPickStill`): its preview's first frame filling `pixels`
    /// (aspect kept, centred) and softly blurred, since a small preview stretched over a screen
    /// shows its pixels.
    func publishPreview(of wallpaper: WEWallpaper, filling pixels: SIMD2<Int>) {
        guard let name = wallpaper.project.preview, !name.isEmpty else { return }
        let preview = wallpaper.wallpaperDirectory.appending(path: name)
        DispatchQueue.global(qos: .utility).async {
            guard let source = CGImageSourceCreateWithURL(preview as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let filled = Self.filledAndBlurred(image, pixels: pixels) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.publishPick(filled) }
            }
        }
    }

    /// A video wallpaper's picture: its first frame filling `pixels` (aspect kept, centred), read
    /// by the hardware decoder from its file (a file that keeps its parameter sets in band from
    /// its repaired copy, `RepairedVideoCache`); its preview when the frame can't be read. Nothing
    /// is kept once `isCurrent` says another wallpaper was picked meanwhile.
    func publishFirstFrame(of wallpaper: WEWallpaper, filling pixels: SIMD2<Int>,
                           isCurrent: @escaping @MainActor () -> Bool = { true }) {
        let source = wallpaper.mediaURL
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                let url = RepairedVideoCache.current.playableURL(for: source)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .positiveInfinity
                guard let frame = try? await generator.image(at: .zero).image else { return nil } // Optional: falls back to the preview.
                return Self.filled(frame, pixels: pixels)
            }.value
            guard let self, isCurrent() else { return }
            if let image {
                self.publishPick(image)
                OWELog.info(.app, "Screen saver: kept the first frame of \(wallpaper.wallpaperDirectory.lastPathComponent) as its still")
            } else {
                OWELog.info(.app, "Screen saver: can't read the first frame of \(wallpaper.wallpaperDirectory.lastPathComponent); its preview is the still")
                self.publishPreview(of: wallpaper, filling: pixels)
            }
        }
    }

    /// `image` covering `pixels`, centred.
    nonisolated static func filled(_ image: CGImage, pixels: SIMD2<Int>) -> CGImage? {
        guard pixels.x > 0, pixels.y > 0, image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: pixels.x, height: pixels.y, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: WallpaperTransitionCapture.placedRect(imageSize: CGSize(width: image.width, height: image.height),
                                                                      in: CGSize(width: pixels.x, height: pixels.y), placement: .fill))
        return context.makeImage()
    }

    /// `image` covering `pixels`, centred, blurred by about a 200th of the larger side.
    nonisolated static func filledAndBlurred(_ image: CGImage, pixels: SIMD2<Int>) -> CGImage? {
        guard pixels.x > 0, pixels.y > 0, image.width > 0, image.height > 0 else { return nil }
        let size = CGSize(width: pixels.x, height: pixels.y)
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let input = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offset = CGPoint(x: (input.extent.width - size.width) / 2, y: (input.extent.height - size.height) / 2)
        let radius = max(size.width, size.height) / 200
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: CGRect(origin: offset, size: size))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: blurred.extent,
                                                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func list(pick: String?) {
        var stills = ScreenSaverStills.read(folder.appending(path: ScreenSaverStills.fileName)) ?? ScreenSaverStills()
        guard stills.pick != pick else { return }
        stills.pick = pick
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(stills).write(to: folder.appending(path: ScreenSaverStills.fileName), options: .atomic)
        } catch {
            OWELog.error(.app, "Screen saver: can't list the picked wallpaper's still: \(error)")
        }
    }

    /// `picture` is what display `display` (its identity) shows now.
    func publish(_ picture: URL, display: String) {
        let name = ScreenSaverStills.fileName(display: display, fileExtension: picture.pathExtension.lowercased())
        let target = folder.appending(path: name, directoryHint: .notDirectory)
        let staging = folder.appending(path: ".\(UUID().uuidString)-\(name)", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try fileManager.linkItem(at: picture, to: staging)
            } catch {
                try fileManager.copyItem(at: picture, to: staging)
            }
            // rename(2) replaces the earlier still at once: a saver never finds it missing.
            guard rename(staging.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            var stills = ScreenSaverStills.read(folder.appending(path: ScreenSaverStills.fileName)) ?? ScreenSaverStills()
            let previous = stills.stills[display]
            stills.stills[display] = name
            try JSONEncoder().encode(stills).write(to: folder.appending(path: ScreenSaverStills.fileName), options: .atomic)
            // Another format's earlier still (a .jpg after a .heic) is no longer listed.
            if let previous, previous != name {
                try? fileManager.removeItem(at: folder.appending(path: previous)) // Optional: a stale file.
            }
        } catch {
            try? fileManager.removeItem(at: staging) // Optional: the failed attempt's leftover.
            OWELog.error(.app, "Screen saver: can't keep the still of display \(display): \(error)")
        }
    }

    /// `picture` is what the display with id `display` shows now.
    func publish(_ picture: URL, display: CGDirectDisplayID) {
        publish(picture, display: DisplayIdentity.identity(of: display))
    }
}
