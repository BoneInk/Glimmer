import Foundation
import Darwin
import UniformTypeIdentifiers
import WebKit

/// Every scheme read is re-resolved against the canonical root. No arbitrary path bridge
/// is exported to JavaScript. This limits resources, not malicious browser-engine exploits.
final class LocalWallpaperSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let maximumDocumentBytes = 32 * 1024 * 1024
    let location: WebWallpaperProjectLocation
    private let allowHTTPS: Bool
    private let lock = NSLock()
    nonisolated(unsafe) private var tasks: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private var disposed = false
    nonisolated(unsafe) private var resourceRoot: URL?
    nonisolated(unsafe) private var grants: [String: URL] = [:]
    nonisolated(unsafe) private var documentToken = ""
    nonisolated(unsafe) private var resourceEpoch = 0
    private let reader = DispatchQueue(label: "com.boneinkzhong.glimmer.web-assets", qos: .userInitiated)
    // Owned exclusively by `reader`, including its in-memory cache index.
    nonisolated(unsafe) private let mediaResolver = WebWallpaperMediaResolver()

    init(location: WebWallpaperProjectLocation, allowHTTPS: Bool = false) {
        self.location = location; self.allowHTTPS = allowHTTPS
    }
    private final class TaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(_ task: any WKURLSchemeTask) { self.task = task }
    }
    private enum Delivery: @unchecked Sendable {
        case response(URLResponse), bytes(Data), finished, failed(Error)
    }

    func configureResources(root: URL?, grants: [String: URL]) {
        lock.lock()
        if resourceRoot != root || self.grants != grants { resourceRoot = root; self.grants = grants; resourceEpoch += 1 }
        lock.unlock()
    }
    func beginDocument(token: String) { lock.lock(); documentToken = token; resourceEpoch += 1; lock.unlock() }

    nonisolated private func resolve(_ url: URL) throws -> (URL, URL, Int, String) {
        lock.lock(); defer { lock.unlock() }
        guard !disposed else { throw URLError(.cancelled) }
        if url.path.hasPrefix("/__gw_grants__/") {
            let prefix = "/__gw_grants__/" + documentToken + "/"
            guard url.scheme == WebWallpaperProjectLocation.scheme, url.host == WebWallpaperProjectLocation.host,
                  url.user == nil, url.password == nil, url.port == nil, url.path.hasPrefix(prefix),
                  let root = resourceRoot, let file = grants[String(url.path.dropFirst(prefix.count))] else {
                throw WebWallpaperFailure(message: "Blocked an ungranted wallpaper resource.")
            }
            let virtualPath = String(url.path.dropFirst(prefix.count))
            return (file, root, resourceEpoch, (virtualPath as NSString).pathExtension)
        }
        let file = try location.localURL(for: url)
        return (file, location.rootURL, resourceEpoch, file.pathExtension)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let allowed = !disposed && tasks.count < 16
        if allowed { tasks.insert(id) }
        lock.unlock()
        guard allowed else { urlSchemeTask.didFailWithError(URLError(.cancelled)); return }
        let box = TaskBox(urlSchemeTask)
        let request = urlSchemeTask.request
        reader.async { [weak self] in
            guard let self else { return }
            do {
                let method = request.httpMethod ?? "GET"
                guard let url = request.url, ["GET", "HEAD"].contains(method) else {
                    throw WebWallpaperFailure(message: "Unsupported wallpaper resource request.")
                }
                let (local, root, epoch, fileExtension) = try self.resolve(url)
                var file = try LocalWallpaperFileResource(file: local, root: root)
                guard self.isCurrentEpoch(epoch) else { throw URLError(.cancelled) }
                var mime = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
                if let media = try self.mediaResolver.resolve(file, extension: fileExtension,
                    cancelled: { !self.isActive(id) || !self.isCurrentEpoch(epoch) }) {
                    file = media.file; mime = media.mime
                }
                if mime.hasPrefix("text/") || mime.contains("javascript") { mime += "; charset=utf-8" }
                var document: Data?
                if ["html", "htm"].contains(fileExtension.lowercased()) {
                    let bytes = try file.readDocument(maximumBytes: Self.maximumDocumentBytes)
                    guard let text = String(data: bytes, encoding: .utf8) else {
                        throw WebWallpaperFailure(message: "Wallpaper HTML must be UTF-8.")
                    }
                    document = Data(Self.secureHTML(text, allowHTTPS: self.allowHTTPS).utf8)
                }
                let plan = LocalWallpaperResourceResponse(size: document.map { Int64($0.count) } ?? file.size,
                    range: request.value(forHTTPHeaderField: "Range"), method: method)
                guard let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1",
                    headerFields: plan.headers(mimeType: mime)) else { throw URLError(.badServerResponse) }
                guard self.deliver(.response(response), box: box, id: id, epoch: epoch) else { return }
                if method != "HEAD" {
                    var offset = plan.offset, remaining = plan.length
                    while remaining > 0 {
                        guard self.isActive(id), self.isCurrentEpoch(epoch) else { throw URLError(.cancelled) }
                        let count = Int(min(Int64(LocalWallpaperFileResource.chunkBytes), remaining))
                        let chunk: Data
                        if let document { chunk = document.subdata(in: Int(offset)..<(Int(offset) + count)) }
                        else { chunk = try file.read(offset: offset, count: count) }
                        guard self.deliver(.bytes(chunk), box: box, id: id, epoch: epoch) else { return }
                        offset += Int64(count); remaining -= Int64(count)
                    }
                }
                _ = self.deliver(.finished, box: box, id: id, epoch: epoch)
            } catch { _ = self.deliver(.failed(error), box: box, id: id, epoch: nil) }
        }
    }

    /// One chunk is handed to WebKit before the reader allocates the next one.
    /// All task callbacks and stop/dispose checks run on the main queue.
    nonisolated private func deliver(_ event: Delivery, box: TaskBox, id: ObjectIdentifier, epoch: Int?) -> Bool {
        DispatchQueue.main.sync {
            guard self.isActive(id) else { return false }
            if let epoch, !self.isCurrentEpoch(epoch) {
                box.task.didFailWithError(URLError(.cancelled)); self.finish(id); return false
            }
            switch event {
            case .response(let response): box.task.didReceive(response)
            case .bytes(let bytes): box.task.didReceive(bytes)
            case .finished: box.task.didFinish(); self.finish(id)
            case .failed(let error): box.task.didFailWithError(error); self.finish(id)
            }
            return self.isActive(id)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { finish(ObjectIdentifier(urlSchemeTask)) }
    func dispose() { lock.lock(); disposed = true; tasks.removeAll(); grants.removeAll(); resourceRoot = nil; resourceEpoch += 1; lock.unlock() }
    nonisolated private func isCurrentEpoch(_ epoch: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return !disposed && resourceEpoch == epoch }
    nonisolated private func isActive(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return !disposed && tasks.contains(id) }
    nonisolated private func finish(_ id: ObjectIdentifier) { lock.lock(); tasks.remove(id); lock.unlock() }

    nonisolated private static func secureHTML(_ text: String, allowHTTPS: Bool) -> String {
        let remote = allowHTTPS ? " https:" : ""
        let policy = "default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:\(remote); style-src 'self' 'unsafe-inline'\(remote); img-src 'self' data: blob:\(remote); media-src 'self' data: blob:\(remote); font-src 'self' data:\(remote); connect-src 'self'\(remote); worker-src 'self' blob:; frame-src 'none'; child-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        if let range = text.range(of: #"^\s*(?:\uFEFF)?\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[..<range.upperBound]) + meta + String(text[range.upperBound...])
        }
        return meta + text
    }
}
