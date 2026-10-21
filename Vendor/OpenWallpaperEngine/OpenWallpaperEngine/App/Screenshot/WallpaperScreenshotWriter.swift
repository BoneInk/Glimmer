import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves screenshots (`WallpaperScreenshotService`) as PNG files named after the wallpaper and the
/// time, never replacing a file.
enum WallpaperScreenshotWriter {
    enum Failure: LocalizedError {
        case encode(URL)

        var errorDescription: String? {
            switch self {
            case let .encode(url): return String(localized: "The screenshot couldn't be encoded as \(url.lastPathComponent).")
            }
        }
    }

    /// Pictures › Open Wallpaper Engine: where screenshots go unless the user chose a folder.
    static var defaultFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures")
        return pictures.appending(path: "Open Wallpaper Engine", directoryHint: .isDirectory)
    }

    /// The folder `setting` names (`GlobalSettings.screenshotFolder`), or the default one.
    static func folder(setting: String) -> URL {
        setting.isEmpty ? defaultFolder : URL(fileURLWithPath: setting, isDirectory: true)
    }

    /// "<title> <date> at <time>.png" without characters Finder can't show in a name.
    static func fileName(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "Wallpaper" : String(cleaned.prefix(120))
        return "\(name) \(formatter.string(from: date)).png"
    }

    /// Writes `image` as a PNG into `folder` (made if missing) and returns the file. A name
    /// already taken gets " 2", " 3"….
    @discardableResult
    static func write(_ image: CGImage, title: String, to folder: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileName(title: title, date: date)
        var url = folder.appending(path: base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: (base as NSString).deletingPathExtension + " \(counter).png")
            counter += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encode(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encode(url) }
        return url
    }
}
