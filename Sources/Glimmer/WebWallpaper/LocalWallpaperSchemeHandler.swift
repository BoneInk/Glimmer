import Foundation
import Darwin
import UniformTypeIdentifiers
import WebKit

/// Every scheme read is re-resolved against the canonical root. No arbitrary path bridge
/// is exported to JavaScript. This limits resources, not malicious browser-engine exploits.
final class LocalWallpaperSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let maximumResourceBytes = 32 * 1024 * 1024
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

    init(location: WebWallpaperProjectLocation, allowHTTPS: Bool = false) {
        self.location = location; self.allowHTTPS = allowHTTPS
    }
    private final class TaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(_ task: any WKURLSchemeTask) { self.task = task }
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
        reader.async { [weak self] in
            let result: Result<(Data, String, Int), Error>
            do {
                guard let url = box.task.request.url, ["GET", "HEAD"].contains(box.task.request.httpMethod ?? "GET") else {
                    throw WebWallpaperFailure(message: "Unsupported wallpaper resource request.")
                }
                guard let self else { throw URLError(.cancelled) }
                let (local, root, epoch, fileExtension) = try self.resolve(url)
                var bytes = try Self.readBoundedFile(local, root: root)
                guard self.isCurrentEpoch(epoch) else { throw URLError(.cancelled) }
                let mime = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
                if ["html", "htm"].contains(fileExtension.lowercased()) {
                    guard let text = String(data: bytes, encoding: .utf8) else {
                        throw WebWallpaperFailure(message: "Wallpaper HTML must be UTF-8.")
                    }
                    bytes = Data(Self.secureHTML(text, allowHTTPS: self.allowHTTPS).utf8)
                }
                result = .success((bytes, mime, epoch))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive(id) else { return }
                switch result {
                case let .success((bytes, mime, epoch)):
                    guard self.isCurrentEpoch(epoch) else { box.task.didFailWithError(URLError(.cancelled)); self.finish(id); return }
                    guard let url = box.task.request.url else { self.finish(id); return }
                    let response: URLResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": mime + (mime.hasPrefix("text/") || mime.contains("javascript") ? "; charset=utf-8" : ""),
                        "Content-Length": String(bytes.count), "Cache-Control": "no-store"
                    ]) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil)
                    box.task.didReceive(response)
                    if self.isActive(id), box.task.request.httpMethod != "HEAD" { box.task.didReceive(bytes) }
                    if self.isActive(id) { box.task.didFinish() }
                case let .failure(error): box.task.didFailWithError(error)
                }
                self.finish(id)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { finish(ObjectIdentifier(urlSchemeTask)) }
    func dispose() { lock.lock(); disposed = true; tasks.removeAll(); grants.removeAll(); resourceRoot = nil; resourceEpoch += 1; lock.unlock() }
    nonisolated private func isCurrentEpoch(_ epoch: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return !disposed && resourceEpoch == epoch }
    private func isActive(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return !disposed && tasks.contains(id) }
    private func finish(_ id: ObjectIdentifier) { lock.lock(); tasks.remove(id); lock.unlock() }

    /// Open every component relative to a directory descriptor without following links.
    /// Size is bounded again while reading, so growth cannot bypass the allocation limit.
    nonisolated private static func readBoundedFile(_ file: URL, root: URL) throws -> Data {
        guard WebWallpaperProjectLocation.contains(file, in: root) else { throw URLError(.noPermissionsToReadFile) }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw URLError(.noPermissionsToReadFile) }
        defer { Darwin.close(descriptor) }
        let pieces = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        for (index, component) in pieces.enumerated() {
            guard component != ".", component != ".." else { throw URLError(.noPermissionsToReadFile) }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index < pieces.count - 1 ? O_DIRECTORY : 0)
            let next = Darwin.openat(descriptor, component, flags)
            guard next >= 0 else { throw URLError(.noPermissionsToReadFile) }
            Darwin.close(descriptor); descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumResourceBytes else {
            throw WebWallpaperFailure(message: "Blocked special or oversized wallpaper resource (32 MiB limit).")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw URLError(.cannotOpenFile) }
            if count == 0 { break }
            guard result.count + count <= maximumResourceBytes else { throw WebWallpaperFailure(message: "Wallpaper resource grew beyond 32 MiB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

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
