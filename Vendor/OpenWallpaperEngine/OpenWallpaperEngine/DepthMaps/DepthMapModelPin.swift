import Foundation

/// The depth model the app accepts: Depth Anything V2 **Small** as Apple's own Core ML package
/// (`DepthAnythingV2SmallF16.mlpackage`, Apache-2.0) from Apple's Hugging Face repository
/// `apple/coreml-depth-anything-v2-small`, at one pinned commit, every file pinned by SHA-256.
/// Only Small: the Base and Large models are under a non-commercial licence. A new app release
/// pins a new commit here; the app never installs an unpinned revision or `main`.
///
/// An `.mlpackage` is a folder, so each of its files is downloaded and checked on its own
/// (`https://huggingface.co/<repository>/resolve/<revision>/<package>/<path>`), then the package
/// is assembled and compiled (`DepthMapPluginInstaller`).
///
/// To pin a new revision: list the files with
/// `https://huggingface.co/api/models/apple/coreml-depth-anything-v2-small/tree/<revision>?recursive=1`
/// (LFS files carry their SHA-256 as `lfs.oid`; for the others download the file at that revision
/// and run `shasum -a 256`), and update the table below with the sizes.
struct DepthMapModelPin: Equatable, Sendable {
    struct File: Equatable, Sendable {
        /// Inside the `.mlpackage`.
        let path: String
        /// Lowercase hex SHA-256.
        let sha256: String
        let size: Int64
    }

    static let repository = "apple/coreml-depth-anything-v2-small"
    /// A placeholder SHA-256 a release must never ship (`DepthMapPluginInstallerTests`).
    static let placeholderSHA256 = String(repeating: "0", count: 64)

    /// The commit of the repository.
    let revision: String
    let packageName: String
    let files: [File]

    /// The install folder's name: the model and the commit it came from.
    var version: String { "depth-anything-v2-small-f16-\(revision.prefix(12))" }

    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// About what the compiled model takes (the weights, plus a little).
    var installedSize: Int64 { downloadSize }

    /// Still a placeholder: a revision or a checksum nobody filled in.
    var isPlaceholder: Bool {
        revision.count != 40 || files.isEmpty || files.contains { $0.sha256 == Self.placeholderSHA256 || $0.sha256.count != 64 }
    }

    func downloadURL(for file: File) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let path = "\(packageName)/\(file.path)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(revision)/\(path)")!
    }

    /// Where the repository can be read, for the notice and the credits.
    static let pageURL = URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small")!

    /// The model this app release installs (repository commit of 2024-06-24).
    static let pinned = DepthMapModelPin(
        revision: "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
        packageName: "DepthAnythingV2SmallF16.mlpackage",
        files: [
            File(path: "Manifest.json",
                 sha256: "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7", size: 617),
            File(path: "Data/com.apple.CoreML/model.mlmodel",
                 sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042", size: 399_433),
            File(path: "Data/com.apple.CoreML/weights/weight.bin",
                 sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed", size: 49_419_072),
        ])

    /// The text kept beside the installed model.
    var notice: String {
        """
        Depth Anything V2 Small, Core ML package \(packageName)
        From \(Self.pageURL.absoluteString) at commit \(revision)
        Licensed under the Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0
        Depth Anything V2: Lihe Yang et al., https://arxiv.org/abs/2406.09414
        Core ML conversion: Apple.

        """
    }
}
