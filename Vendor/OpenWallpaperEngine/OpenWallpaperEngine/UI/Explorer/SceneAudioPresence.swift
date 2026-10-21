import Foundation

/// Whether a scene wallpaper ships sound files, loose or inside its `.pkg`, so the Details panel
/// shows its music controls.
enum SceneAudioPresence {
    private static let audioExtensions: Set<String> = ["mp3", "ogg", "wav", "m4a", "flac"]

    /// Walks the wallpaper's folder and reads its packages' file lists: file IO, so never on the
    /// main thread.
    static func hasAudio(in directory: URL) -> Bool {
        ThreadGuards.assertBackground("scene audio detection")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator {
            let fileExtension = url.pathExtension.lowercased()
            if audioExtensions.contains(fileExtension) { return true }
            guard fileExtension == "pkg" else { continue }
            do {
                // Mapped: only the package's header and file list are read.
                let parser = try PKGParser(url: url)
                if parser.fileList.contains(where: { audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                    return true
                }
            } catch {
                OWELog.error(.library, "Can't read \(url.path) to look for sounds: \(error)")
            }
        }
        return false
    }
}
