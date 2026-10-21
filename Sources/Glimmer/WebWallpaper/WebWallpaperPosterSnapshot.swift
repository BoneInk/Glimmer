import AppKit
import WebKit

@MainActor
private final class WebWallpaperPosterRequest {
    var continuation: CheckedContinuation<CGImage, Error>?
    private var cancelled = false
    var isPending: Bool { continuation != nil }
    func install(_ continuation: CheckedContinuation<CGImage, Error>) -> Bool {
        if cancelled { continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation
        return true
    }
    func finish(_ result: Result<CGImage, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
    func cancel() { cancelled = true; finish(.failure(CancellationError())) }
}

extension WebWallpaperRuntime {
    /// A one-shot image of this existing host. The caller owns caching and retry policy.
    /// WebKit may fail while a host is detached/occluded; no replacement host is created.
    @MainActor
    func captureStaticPoster() async throws -> CGImage {
        try Task.checkCancellation()
        guard state == .ready || state == .paused else {
            throw WebWallpaperFailure(message: "Web wallpaper is not ready for a poster snapshot.")
        }
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw WebWallpaperFailure(message: "Web wallpaper has no snapshot bounds.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        configuration.snapshotWidth = NSNumber(value: Double(bounds.width * min(1, 960 / max(bounds.width, bounds.height))))
        let request = WebWallpaperPosterRequest()
        let result: CGImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                webView.takeSnapshot(with: configuration) { image, error in
                    guard request.isPending else { return }
                    if let error { request.finish(.failure(error)); return }
                    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        request.finish(.failure(WebWallpaperFailure(message: "WebKit returned no poster image.")))
                        return
                    }
                    let ratio = min(1, 960 / CGFloat(max(cgImage.width, cgImage.height)))
                    if ratio < 1 {
                        let width = max(1, Int(CGFloat(cgImage.width) * ratio))
                        let height = max(1, Int(CGFloat(cgImage.height) * ratio))
                        guard let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                            request.finish(.failure(WebWallpaperFailure(message: "Cannot allocate poster image.")))
                            return
                        }
                        context.interpolationQuality = .high
                        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                        guard let bounded = context.makeImage() else {
                            request.finish(.failure(WebWallpaperFailure(message: "Cannot produce poster image.")))
                            return
                        }
                        request.finish(.success(bounded))
                    } else { request.finish(.success(cgImage)) }
                }
            }
        } onCancel: {
            // WebKit has no public cancelSnapshot. Release our waiter immediately and ignore
            // its eventual callback; generation guards independently prevent publication.
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard state == .ready || state == .paused else {
            throw WebWallpaperFailure(message: "Web wallpaper changed state during its snapshot.")
        }
        return result
    }
}
