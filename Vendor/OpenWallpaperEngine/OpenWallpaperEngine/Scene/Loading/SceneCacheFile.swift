import Foundation
import CryptoKit
import CoreGraphics
import Metal

/// Everything that feeds a parsed scene: the in-memory parse is only reused for the inputs it
/// was built from.
struct SceneCacheKey: Equatable, Sendable {
    struct SourceFile: Equatable, Sendable {
        var path: String
        var size: Int64
        var modified: Double
    }

    struct Display: Equatable, Sendable, Comparable {
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double

        static func < (lhs: Display, rhs: Display) -> Bool {
            (lhs.pixelWidth, lhs.pixelHeight, lhs.scale) < (rhs.pixelWidth, rhs.pixelHeight, rhs.scale)
        }

        /// The connected displays, through CoreGraphics (safe off the main thread).
        static func connected() -> [Display] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
            return ids.prefix(Int(count)).compactMap { id in
                guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
                return Display(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                               scale: Double(mode.pixelWidth) / Double(mode.width))
            }.sorted()
        }
    }

    /// The project's files (size and modification time), sorted by path.
    var sources: [SourceFile]
    /// The saved Inspector edits (`_owe_scene_object_*`).
    var edits: [String: String]
    /// Stored user property values that can change the content.
    var userProperties: [String: String]
    var displays: [Display]
    /// The settings that affect preparation (`SceneRenderSettings.contentKey`).
    var settings: String
    /// The OS build, the shader toolchain and the cache format (`currentEnvironment`), not the
    /// app's version: an update keeps prepared scenes unless what prepares them changed.
    var environment: String = SceneCacheKey.currentEnvironment
    var shaderRevision: Int = ShaderVariantTranslator.revision
    var gpu: String = SceneCacheKey.currentGPU

    /// Changes whenever what a preparation writes changes, so older files are rebuilt.
    static let contentRevision = 1

    /// As `EffectPipelineArchive.environmentKey` keys compiled pipelines: the OS build, the shader
    /// toolchain and translator revision, plus this cache's content revision.
    static let currentEnvironment: String = environment(os: ProcessInfo.processInfo.operatingSystemVersionString,
                                                        toolchain: InProcessShaderCompiler.libraryFingerprint)

    static func environment(os: String, toolchain: String) -> String {
        "\(EffectPipelineArchive.environmentKey(os: os, toolchain: toolchain))--c\(contentRevision)"
    }

    /// The GPU's name and the newest Apple and Mac families it supports.
    static let currentGPU: String = {
        guard let device = MTLCreateSystemDefaultDevice() else { return "none" }
        let apple: [MTLGPUFamily] = [.apple9, .apple8, .apple7, .apple6, .apple5]
        let family = apple.first(where: device.supportsFamily).map { "apple\($0.rawValue)" }
            ?? (device.supportsFamily(.mac2) ? "mac2" : "other")
        return "\(device.name)|\(family)"
    }()

    /// Size and modification time of `url`'s files: the file itself, or every regular file below
    /// a directory (hidden files and the cache itself excluded).
    static func sources(of directory: URL) -> [SourceFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles]) else { return [] }
        let base = directory.standardizedFileURL.path
        var files: [SourceFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            files.append(SourceFile(path: relative, size: Int64(values.fileSize ?? -1),
                                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? -1))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// SHA-256 over a canonical encoding of every field.
    var digest: SHA256.Digest {
        var hasher = SHA256()
        func add(_ text: String) {
            var data = Data(text.utf8)
            var length = UInt32(data.count).littleEndian
            hasher.update(data: Data(bytes: &length, count: 4))
            hasher.update(data: data)
            data.removeAll()
        }
        add("sources"); add(String(sources.count))
        for file in sources { add(file.path); add(String(file.size)); add(String(file.modified.bitPattern)) }
        add("edits")
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) { add(key); add(value) }
        add("properties")
        for (key, value) in userProperties.sorted(by: { $0.key < $1.key }) { add(key); add(value) }
        add("displays")
        for display in displays.sorted() {
            add("\(display.pixelWidth)x\(display.pixelHeight)@\(display.scale.bitPattern)")
        }
        add("settings"); add(settings)
        add("environment"); add(environment)
        add("revision"); add(String(shaderRevision))
        add("gpu"); add(gpu)
        return hasher.finalize()
    }

    /// The digest as the file name (hex).
    var name: String { Digest.hex(digest) }
}
