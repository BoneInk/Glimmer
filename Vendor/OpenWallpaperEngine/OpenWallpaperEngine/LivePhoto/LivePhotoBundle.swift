import Foundation

/// A Live Photo as Apple's Live Photo bundle (`com.apple.private.live-photo-bundle`): a `.pvt`
/// package holding the photo, the movie and a `metadata.plist`. AirDrop sends a bundle as one
/// Live Photo, which Photos on iPhone and iPad imports as such; the photo and the movie sent as two
/// files arrive as a separate photo and video, although their content identifiers match.
enum LivePhotoBundle {
    static let pathExtension = "pvt"
    /// The bundle's `metadata.plist`, as Photos writes it for a Live Photo.
    static let metadata: [String: String] = ["PFVideoComplementMetadataVersionKey": "1"]

    /// The bundle of `files`, made in the export's own folder (so it goes with the export) and
    /// named as its photo; made once. The photo and the movie are hard links when the volume
    /// allows, else copies.
    static func make(_ files: LivePhotoHelper.Files) throws -> URL {
        let fileManager = FileManager.default
        let name = files.still.deletingPathExtension().lastPathComponent
        let bundle = files.directory.appending(path: name, directoryHint: .isDirectory).appendingPathExtension(pathExtension)
        if fileManager.fileExists(atPath: bundle.path(percentEncoded: false)) { return bundle }
        let partial = files.directory.appending(path: ".\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for source in [files.still, files.movie] {
                let destination = partial.appending(path: source.lastPathComponent)
                do {
                    try fileManager.linkItem(at: source, to: destination)
                } catch {
                    try fileManager.copyItem(at: source, to: destination)
                }
            }
            let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            try plist.write(to: partial.appending(path: "metadata.plist"))
            try fileManager.moveItem(at: partial, to: bundle)
        } catch {
            try? fileManager.removeItem(at: partial) // Optional: the half-made bundle.
            throw error
        }
        return bundle
    }

    /// What AirDrop sends for `files`: its bundle, else (the bundle couldn't be made) the photo and
    /// the movie, which still pair in Photos on a Mac.
    static func airDropItems(_ files: LivePhotoHelper.Files) -> [URL] {
        do {
            return [try make(files)]
        } catch {
            OWELog.error(.app, "Live Photo bundle for \(files.still.lastPathComponent) couldn't be made, sending the photo and the movie: \(error)")
            return [files.still, files.movie]
        }
    }
}
