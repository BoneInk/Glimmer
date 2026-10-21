import CryptoKit
import Foundation
import WEFormat

/// What a preview is rendered from, as a fingerprint: a digest of the contents of the WE asset
/// files its scene can read, and of its kind's revision (`EditorPreviewCache.revision(of:)`). Two
/// builds of the assets give a subject the same fingerprint when none of those files changed, so
/// its preview is carried over (`EditorPreviewCache.carryOver`) instead of rendered again.
///
/// The files are the subject's own (an effect's folder, a default system's file, a preset's
/// folder) and the folders its kind shares, which are hashed once per call:
/// - an effect: `shaders/` (the includes) and the textures effects default to (`materials/util`,
///   `materials/gradient`);
/// - a particle system: `shaders/`, `particles/` (children), `materials/particle` and
///   `materials/util`.
/// A change to a shared folder renders the whole kind again. A Workshop effect reads its
/// wallpaper, not the assets, and has no fingerprint.
public enum EditorPreviewInputs {
    static let effectShared = ["shaders", "materials/util", "materials/gradient"]
    static let particleShared = ["shaders", "particles", "materials/particle", "materials/util"]

    /// The fingerprint of each subject that has one, from the asset tree `assets`.
    public static func fingerprints(of subjects: [EditorPreviewSubject], assets: URL,
                                    fileManager: FileManager = .default) -> [EditorPreviewSubject: String] {
        var shared: [String: String] = [:]
        func sharedDigest(_ folders: [String]) -> String {
            let key = folders.joined(separator: "|")
            if let digest = shared[key] { return digest }
            var hasher = SHA256()
            for folder in folders { hash(assets.appending(path: folder, directoryHint: .isDirectory), named: folder, into: &hasher, fileManager) }
            let digest = Digest.hex(hasher.finalize())
            shared[key] = digest
            return digest
        }
        var result: [EditorPreviewSubject: String] = [:]
        for subject in subjects {
            var hasher = SHA256()
            let own: String
            switch subject {
            case .effect(let file, let wallpaper):
                guard wallpaper == nil else { continue }
                own = (file as NSString).deletingLastPathComponent
                hasher.update(data: Data(sharedDigest(effectShared).utf8))
            case .particleSystem(let path, _):
                own = path
                hasher.update(data: Data(sharedDigest(particleShared).utf8))
            case .particlePreset(let directory, _, _):
                own = "presets/" + (directory as NSString).lastPathComponent
                hasher.update(data: Data(sharedDigest(particleShared).utf8))
            }
            hash(assets.appending(path: own), named: own, into: &hasher, fileManager)
            result[subject] = "r\(EditorPreviewCache.revision(of: subject))-" + String(Digest.hex(hasher.finalize()).prefix(24))
        }
        return result
    }

    /// Hashes the file at `url`, or every file under it (by relative path, in order), with their
    /// paths; nothing for a missing one, which still changes the digest when it appears.
    private static func hash(_ url: URL, named name: String, into hasher: inout SHA256, _ fileManager: FileManager) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            hasher.update(data: Data("missing:\(name)\n".utf8))
            return
        }
        guard isDirectory.boolValue else {
            hashFile(url, path: name, into: &hasher)
            return
        }
        let base = url.resolvingSymlinksInPath().path(percentEncoded: false)
        var files: [(String, URL)] = []
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                // Optional: an entry whose type can't be read isn't a file to hash.
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
                files.append((name + "/" + path.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")), file))
            }
        }
        for (path, file) in files.sorted(by: { $0.0 < $1.0 }) { hashFile(file, path: path, into: &hasher) }
    }

    private static func hashFile(_ url: URL, path: String, into hasher: inout SHA256) {
        hasher.update(data: Data("file:\(path)\n".utf8))
        // Optional: a file that can't be read hashes as unreadable; the render reports it.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            hasher.update(data: Data("unreadable\n".utf8))
            return
        }
        hasher.update(data: data)
    }
}
