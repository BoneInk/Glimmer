import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WEFormat

/// Makes a new wallpaper folder in the library, as Wallpaper Engine's editor makes a project from
/// its welcome page (`createNewProject`): a scene from a picture (resized to a display size when
/// chosen), an empty 2D scene of a size, a scene from one of WE's templates with its pictures
/// replaced, or a web wallpaper from a folder with an `index.html`. Each gets a project.json with
/// its title, type and scheme colour (WE's `schemecolor` property), and a preview when it has a
/// picture. The folder is new (`name`, `name 2`, …); nothing is written outside it.
public struct NewWallpaperBuilder {
    /// Why a wallpaper wasn't made (the editor's sheet says it in the user's language).
    public enum Failure: Error, Equatable {
        /// The file (its name) isn't a picture ImageIO reads.
        case unreadableImage(String)
        /// A web folder without its page.
        case noIndexPage
        /// A template option (its name) has no picture.
        case missingPicture(String)
    }

    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The picture the welcome page offers to resize: its size and first frame.
    public struct Picture {
        public let url: URL
        public let image: CGImage
        public let frameCount: Int

        public var width: Int { image.width }
        public var height: Int { image.height }

        public init(url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure.unreadableImage(url.lastPathComponent)
            }
            self.url = url
            self.image = image
            frameCount = CGImageSourceGetCount(source)
        }
    }

    // MARK: Scene from a picture

    /// A scene the picture fills: at the picture's own size, or resized to `resize` (scaled to
    /// cover it and cropped to its centre, as a wallpaper fills a display).
    public func scene(from picture: Picture, title: String, schemeColor: String? = nil,
                      resize: NewWallpaperResolution? = nil, in library: URL) throws -> URL {
        let folder = try newFolder(title, in: library)
        let name = Self.assetName(picture.url.deletingPathExtension().lastPathComponent)
        let size: (width: Int, height: Int)
        let texture: (data: Data, fileExtension: String)
        if let resize {
            size = (resize.width, resize.height)
            guard let scaled = Self.covering(picture.image, width: resize.width, height: resize.height),
                  let png = EditorAssetStore.pngData(scaled) else { throw Failure.unreadableImage(picture.url.lastPathComponent) }
            texture = (png, "png")
        } else {
            size = (picture.width, picture.height)
            let (data, fileExtension, _) = try EditorAssetStore.textureData(from: picture.url)
            texture = (data, fileExtension)
        }
        try write(texture.data, "materials/\(name).\(texture.fileExtension)", in: folder)
        try writeJSON(Self.imageMaterial(texture: name), "materials/\(name).json", in: folder)
        try writeJSON(["autosize": true, "material": "materials/\(name).json"], "models/\(name).json", in: folder)
        let object: [String: Any] = [
            "id": 1, "name": picture.url.deletingPathExtension().lastPathComponent, "image": "models/\(name).json",
            "origin": "\(Double(size.width) / 2) \(Double(size.height) / 2) 0", "scale": "1 1 1", "angles": "0 0 0",
            "size": "\(size.width) \(size.height)", "visible": true,
        ]
        try writeJSON(Self.scene(width: size.width, height: size.height, objects: [object]), "scene.json", in: folder)
        try writeJSON(Self.project(title: title, type: "scene", file: "scene.json",
                                   schemeColor: schemeColor ?? Self.dominantColor(of: picture.image)),
                      WEProjectFile.fileName, in: folder)
        try writePreview(picture.image, in: folder)
        return folder
    }

    // MARK: Empty scene

    /// An empty 2D scene of `width` × `height` (WE's Empty template).
    public func emptyScene(title: String, width: Int, height: Int, schemeColor: String = "0 0 0",
                           in library: URL) throws -> URL {
        let folder = try newFolder(title, in: library)
        try writeJSON(Self.scene(width: max(1, width), height: max(1, height), objects: []), "scene.json", in: folder)
        try writeJSON(Self.project(title: title, type: "scene", file: "scene.json", schemeColor: schemeColor),
                      WEProjectFile.fileName, in: folder)
        return folder
    }

    // MARK: From a template

    /// A copy of `template` (without its template.json) with each option's picture in place: a GIF
    /// for a `.gif` destination is copied as it is, anything else is written in the destination's
    /// format. An option that adjusts the projection sets the scene's size to its picture's.
    public func scene(from template: WallpaperTemplate, title: String, pictures: [String: Picture],
                      in library: URL) throws -> URL {
        for option in template.options where pictures[option.destination] == nil {
            throw Failure.missingPicture(option.name)
        }
        let folder = try newFolder(title, in: library)
        for item in try fileManager.contentsOfDirectory(at: template.folder, includingPropertiesForKeys: nil,
                                                        options: .skipsHiddenFiles)
        where item.lastPathComponent != "template.json" {
            try fileManager.copyItem(at: item, to: folder.appending(path: item.lastPathComponent))
        }
        var sceneSize: (width: Int, height: Int)?
        var previewImage: CGImage?
        for option in template.options {
            guard let picture = pictures[option.destination] else { continue }
            let destination = try LocalWallpaperWriter.contained(option.destination, in: folder)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoded(picture, as: destination.pathExtension).write(to: destination, options: .atomic)
            if option.adjustsProjection { sceneSize = (picture.width, picture.height) }
            previewImage = previewImage ?? picture.image
        }
        let sceneURL = try LocalWallpaperWriter.contained(template.sceneFile, in: folder)
        if let sceneSize, var scene = try TolerantJSON.object(from: Data(contentsOf: sceneURL)) as? [String: Any] {
            var general = scene["general"] as? [String: Any] ?? [:]
            general["orthogonalprojection"] = ["width": sceneSize.width, "height": sceneSize.height]
            scene["general"] = general
            try JSONSerialization.data(withJSONObject: scene, options: [.prettyPrinted, .sortedKeys])
                .write(to: sceneURL, options: .atomic)
        }
        let projectURL = WEProjectFile.url(in: folder)
        var project = try TolerantJSON.object(from: Data(contentsOf: projectURL)) as? [String: Any] ?? [:]
        project.removeValue(forKey: "templateoptions")
        for key in LocalWallpaperWriter.workshopKeys { project.removeValue(forKey: key) }
        project["title"] = title
        project["type"] = "scene"
        project["file"] = template.sceneFile
        // The template's own scheme colour stays; without one, the picture's.
        var general = project["general"] as? [String: Any] ?? [:]
        var properties = general["properties"] as? [String: Any] ?? [:]
        if properties["schemecolor"] == nil {
            let color = previewImage.map(Self.dominantColor) ?? "0 0 0"
            properties["schemecolor"] = (Self.project(title: title, type: "scene", file: "", schemeColor: color)["general"]
                as? [String: Any]).flatMap { ($0["properties"] as? [String: Any])?["schemecolor"] }
        }
        general["properties"] = properties
        project["general"] = general
        try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
            .write(to: projectURL, options: .atomic)
        if let previewImage { try writePreview(previewImage, in: folder) }
        return folder
    }

    // MARK: Web folder

    /// A web wallpaper of `source`'s files (it needs an `index.html`), copied by `copy` (the app
    /// copies without links); project.json names the page.
    public func webWallpaper(from source: URL, title: String, in library: URL,
                             copy: (URL, URL) throws -> Void) throws -> URL {
        guard fileManager.fileExists(atPath: source.appending(path: "index.html").path) else { throw Failure.noIndexPage }
        let folder = try newFolder(title, in: library)
        try fileManager.removeItem(at: folder)
        try copy(source, folder)
        try writeJSON(Self.project(title: title, type: "web", file: "index.html", schemeColor: "0 0 0"),
                      WEProjectFile.fileName, in: folder)
        return folder
    }

    // MARK: Documents

    static func scene(width: Int, height: Int, objects: [[String: Any]]) -> [String: Any] {
        [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": [
                "clearcolor": "0 0 0", "bloom": false,
                "orthogonalprojection": ["width": width, "height": height],
            ] as [String: Any],
            "objects": objects,
        ]
    }

    static func project(title: String, type: String, file: String, schemeColor: String) -> [String: Any] {
        [
            "title": title, "type": type, "file": file,
            "general": ["properties": ["schemecolor": [
                "order": 0, "text": "ui_browse_properties_scheme_color", "type": "color", "value": schemeColor,
            ] as [String: Any]]],
        ]
    }

    static func imageMaterial(texture: String) -> [String: Any] {
        ["passes": [[
            "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
            "shader": "genericimage2", "textures": [texture],
        ] as [String: Any]]]
    }

    /// A file name from the picture's: lower-case letters, digits and underscores.
    static func assetName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let cleaned = String(folded.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "background" : String(cleaned.prefix(64))
    }

    // MARK: Pictures

    /// `image` scaled to cover `width` × `height`, centred and cropped.
    static func covering(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    /// The picture in `fileExtension`'s format: a GIF into a `.gif` as it is, else its first frame.
    static func encoded(_ picture: Picture, as fileExtension: String) throws -> Data {
        let lowered = fileExtension.lowercased()
        if picture.url.pathExtension.lowercased() == lowered, ["gif", "png", "jpg", "jpeg"].contains(lowered) {
            return try Data(contentsOf: picture.url)
        }
        let type: UTType = lowered == "jpg" || lowered == "jpeg" ? .jpeg : lowered == "gif" ? .gif : .png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unreadableImage(picture.url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, picture.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadableImage(picture.url.lastPathComponent) }
        return data as Data
    }

    /// The picture's dominant colour as WE's `schemecolor` writes it (`"r g b"`, 0…1): the most
    /// common of its colours, each channel in 8 steps, over a 32 × 32 sample.
    public static func dominantColor(of image: CGImage) -> String {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return "0 0 0" }
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 127 {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            let key = (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)
            let bucket = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (bucket.count + 1, bucket.red + red, bucket.green + green, bucket.blue + blue)
        }
        guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return "0 0 0" }
        func channel(_ sum: Int) -> String { SceneVector.format((Double(sum) / Double(top.count) / 255 * 1000).rounded() / 1000) }
        return "\(channel(top.red)) \(channel(top.green)) \(channel(top.blue))"
    }

    // MARK: Files

    private func newFolder(_ title: String, in library: URL) throws -> URL {
        let writer = LocalWallpaperWriter(fileManager: fileManager)
        let folder = writer.uniqueFolder(named: LocalWallpaperWriter.folderName(title), in: library)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ data: Data, _ path: String, in folder: URL) throws {
        let url = try LocalWallpaperWriter.contained(path, in: folder)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func writeJSON(_ object: [String: Any], _ path: String, in folder: URL) throws {
        try write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path, in: folder)
    }

    private func writePreview(_ image: CGImage, in folder: URL) throws {
        let side = min(WallpaperThumbnail.snapshotSide, min(image.width, image.height))
        let thumbnail = try ThumbnailEncoder.snapshot(image, side: max(1, side))
        try LocalWallpaperWriter(fileManager: fileManager).writeThumbnail(thumbnail, into: folder)
    }
}
