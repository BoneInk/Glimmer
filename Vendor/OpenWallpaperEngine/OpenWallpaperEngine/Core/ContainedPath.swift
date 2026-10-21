import Darwin
import Foundation

/// Path checks for files read from or written into a wallpaper's folder: symbolic links are
/// resolved (or refused) before a path is judged to be inside the folder.
enum ContainedPath {
    /// The canonical path of an existing item, with every symbolic link resolved; nil if it
    /// doesn't exist.
    static func canonical(_ url: URL) -> String? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether canonical `path` is `root` or lies below it.
    static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix)
    }

    /// Whether the item at `url` is itself a symbolic link (not following it). A directory URL's
    /// trailing slash is dropped first: `lstat` follows a link named with one.
    static func isSymbolicLink(_ url: URL) -> Bool {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// The folder a symbolic link at `url` points to (its canonical path), or `url` itself when it
    /// isn't a link or the link is broken. Foundation's URL-based listings
    /// (`contentsOfDirectory(at:)`, `enumerator(at:)`) don't follow a link they start from: listing
    /// a linked folder fails with "Not a directory", or lists nothing.
    static func followingFolderLink(_ url: URL) -> URL {
        guard isSymbolicLink(url), let target = canonical(url) else { return url }
        return URL(filePath: target, directoryHint: .isDirectory)
    }

    /// Whether no existing component of `relativePath` below `root` is a symbolic link, so a
    /// write there stays under `root`. Components that don't exist yet are fine.
    static func hasNoLinks(below root: URL, relativePath: String) -> Bool {
        var current = root
        for component in relativePath.split(separator: "/") {
            current = current.appending(path: String(component))
            var info = stat()
            guard lstat(current.path(percentEncoded: false), &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }
}
