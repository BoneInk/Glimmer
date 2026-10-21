import Foundation

/// Fetches Valve's SteamCMD package; tests stand in a fake that writes a local archive.
protocol SteamCmdPackageDownloading: Sendable {
    /// Downloads `url` to `destination`, reporting the fraction done (nil while the size is
    /// unknown). Throws `CancellationError` when the calling task is cancelled.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws
}

/// Downloads over HTTPS with URLSession; nothing else is accepted.
struct URLSessionSteamCmdDownloader: SteamCmdPackageDownloading {
    enum Failure: LocalizedError {
        case insecureURL
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                return String(localized: "SteamCMD is only downloaded over HTTPS.", comment: "SteamCMD install error")
            case .httpStatus(let code):
                return String(localized: "Valve's server answered with HTTP status \(code).",
                              comment: "SteamCMD install error; %lld is an HTTP status code")
            }
        }
    }

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard url.scheme == "https" else { throw Failure.insecureURL }
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Moves the finished file into place and resumes the caller once. `lock` owns `continuation`
/// and `moveError`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it moves now.
        do {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw URLSessionSteamCmdDownloader.Failure.httpStatus(response.statusCode)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }
        if let moveError = lock.withLock({ moveError }) {
            finish(.failure(moveError))
        } else {
            finish(.success(()))
        }
    }
}
