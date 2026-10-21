//
//  WebWallpaperSchemeHandler.swift
//  Open Wallpaper Engine
//
//  Serves a local web wallpaper's folder under `owe-wallpaper://local/…`. Every local web
//  wallpaper loads through it, so the page gets an ordinary origin for its own files (XHR, fetch,
//  WebGL textures) without file-URL privileges, and WE's compatibility patches
//  (`WebCompatPatches`) are applied in memory on the way to the page.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

final class WebWallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "owe-wallpaper"
    static let host = "local"

    /// The largest file served; anything bigger is answered with a 404.
    static let maxFileSize: UInt64 = 2 << 30
    /// The largest file read whole to have patches applied; bigger ones are served unpatched.
    static let maxPatchedFileSize: UInt64 = 64 << 20
    /// Files are sent in pieces of this size, so a large one is never held in memory at once.
    static let chunkSize = 4 << 20

    /// Read on the main thread only (WebKit calls the handler there); the view model swaps it
    /// when the wallpaper changes.
    var directory: URL?
    var patches = WebCompatPatches(actions: [])
    /// The files outside the folder the page's `file` and `directory` properties let it read.
    var userFiles: WebUserFiles?

    static func url(forRelativePath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + WebCompatPatches.normalize(path)
        return components.url
    }

    /// The regular file a request names, confined to the wallpaper folder once symlinks are
    /// resolved on both sides; nil for anything else.
    static func fileURL(for requestURL: URL, in directory: URL) -> (url: URL, relativePath: String)? {
        let relative = WebCompatPatches.normalize(requestURL.path(percentEncoded: false))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".."),
              let root = ContainedPath.canonical(directory),
              let file = ContainedPath.canonical(directory.appending(path: relative)),
              file != root, ContainedPath.isInside(file, root: root) else { return nil }
        let url = URL(fileURLWithPath: file)
        // Read fresh: the handler serves whatever is on disk now.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            return nil
        }
        return (url, relative)
    }

    /// What a request is answered with.
    struct Reply {
        enum Body {
            case data(Data)
            /// `range` of the file at `url`, read in chunks as it is sent.
            case file(URL, range: Range<UInt64>)
        }

        let status: Int
        let headers: [String: String]
        let body: Body
    }

    /// The byte range a `Range` header asks for, if it names one satisfiable range.
    enum RangeRequest: Equatable {
        case whole
        case partial(Range<UInt64>)
        case unsatisfiable
    }

    static func rangeRequest(_ header: String?, fileSize: UInt64) -> RangeRequest {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst("bytes=".count)
        // Several ranges would need a multipart reply; the whole file answers them too.
        guard !spec.contains(",") else { return .whole }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .unsatisfiable }
        let first = bounds[0].trimmingCharacters(in: .whitespaces)
        let last = bounds[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            // `bytes=-N`: the last N bytes.
            guard let suffix = UInt64(last), suffix > 0, fileSize > 0 else { return .unsatisfiable }
            return .partial((fileSize - min(suffix, fileSize))..<fileSize)
        }
        guard let start = UInt64(first), start < fileSize else { return .unsatisfiable }
        if last.isEmpty { return .partial(start..<fileSize) }
        guard let end = UInt64(last), end >= start else { return .unsatisfiable }
        return .partial(start..<(min(end, fileSize - 1) + 1))
    }

    static func notFound() -> Reply {
        Reply(status: 404, headers: ["Access-Control-Allow-Origin": "*"], body: .data(Data()))
    }

    /// The reply to `request` from the wallpaper in `directory`, with `patches` applied, or from
    /// the user's files (`WebUserFiles.pathPrefix`) that `userFiles` allows.
    static func reply(to request: URLRequest, directory: URL?, patches: WebCompatPatches,
                      userFiles: WebUserFiles? = nil) -> Reply {
        if let requestURL = request.url {
            let relative = WebCompatPatches.normalize(requestURL.path(percentEncoded: false))
            if relative.hasPrefix(WebUserFiles.pathPrefix + "/") {
                guard let file = userFiles?.file(forServedPath: relative) else {
                    OWELog.debug(.web, "Web wallpaper request for a file the user didn't choose refused")
                    return notFound()
                }
                return userFileReply(file, request: request)
            }
        }
        // Pages probe for optional files; a miss is reported to the page as a 404.
        guard let requestURL = request.url, let directory,
              let target = fileURL(for: requestURL, in: directory) else {
            OWELog.debug(.web, "Web wallpaper request \(request.url?.path ?? "?") refused or not found")
            return notFound()
        }
        let size: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            OWELog.debug(.web, "Web wallpaper file \(target.relativePath) unavailable: \(error)")
            return notFound()
        }
        guard size <= maxFileSize else {
            OWELog.error(.web, "Web wallpaper file \(target.relativePath) is \(size) bytes, over the \(maxFileSize)-byte limit")
            return notFound()
        }
        let mime = UTType(filenameExtension: target.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Content-Type": mime, "Access-Control-Allow-Origin": "*"]

        if patches.hasPatches(for: target.relativePath) {
            guard size <= maxPatchedFileSize else {
                OWELog.error(.web, "zcompat: \(target.relativePath) is too large to patch; served unpatched")
                return fileReply(target.url, size: size, request: request, headers: headers)
            }
            do {
                let data = patches.apply(to: try Data(contentsOf: target.url), relativePath: target.relativePath)
                headers["Content-Length"] = String(data.count)
                return Reply(status: 200, headers: headers, body: .data(data))
            } catch {
                OWELog.debug(.web, "Web wallpaper file \(target.relativePath) unavailable: \(error)")
                return notFound()
            }
        }
        return fileReply(target.url, size: size, request: request, headers: headers)
    }

    private static func userFileReply(_ url: URL, request: URLRequest) -> Reply {
        let size: UInt64
        do {
            size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            OWELog.debug(.web, "User file \(url.lastPathComponent) unavailable: \(error)")
            return notFound()
        }
        guard size <= maxFileSize else {
            OWELog.error(.web, "User file \(url.lastPathComponent) is \(size) bytes, over the \(maxFileSize)-byte limit")
            return notFound()
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return fileReply(url, size: size, request: request, headers: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])
    }

    private static func fileReply(_ url: URL, size: UInt64, request: URLRequest, headers: [String: String]) -> Reply {
        var headers = headers
        headers["Accept-Ranges"] = "bytes"
        switch rangeRequest(request.value(forHTTPHeaderField: "Range"), fileSize: size) {
        case .whole:
            headers["Content-Length"] = String(size)
            return Reply(status: 200, headers: headers, body: .file(url, range: 0..<size))
        case .partial(let range):
            headers["Content-Length"] = String(range.count)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            return Reply(status: 206, headers: headers, body: .file(url, range: range))
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(size)"
            headers["Content-Length"] = "0"
            return Reply(status: 416, headers: headers, body: .data(Data()))
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let reply = Self.reply(to: urlSchemeTask.request, directory: directory, patches: patches, userFiles: userFiles)
        let response = HTTPURLResponse(url: requestURL, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        switch reply.body {
        case .data(let data):
            urlSchemeTask.didReceive(response)
            if !data.isEmpty { urlSchemeTask.didReceive(data) }
            urlSchemeTask.didFinish()
        case .file(let url, let range):
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: range.lowerBound)
            } catch {
                OWELog.debug(.web, "Web wallpaper file \(url.lastPathComponent) unavailable: \(error)")
                urlSchemeTask.didFailWithError(error)
                return
            }
            defer { try? handle.close() } // Closing a read-only handle has nothing to report.
            urlSchemeTask.didReceive(response)
            var remaining = range.count
            while remaining > 0 {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: min(Self.chunkSize, remaining))
                } catch {
                    OWELog.error(.web, "Reading web wallpaper file \(url.lastPathComponent) failed: \(error)")
                    urlSchemeTask.didFailWithError(error)
                    return
                }
                guard let chunk, !chunk.isEmpty else { break }
                urlSchemeTask.didReceive(chunk)
                remaining -= chunk.count
            }
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
