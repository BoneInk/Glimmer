import Foundation
import Darwin
import CryptoKit

/// All loose resource reads walk under one open directory descriptor. Packages
/// remain indexed archives; no entry is ever extracted to a filesystem path.
struct SceneEngineAssetBundle: Sendable {
    let rootURL: URL
    /// app/depot/manifest provenance from the authenticated content broker.
    let manifestIdentity: String
    /// Relative manifest files, SHA-256 of each verified retained file.
    let verifiedFiles: [String:String]
    /// Optional verified engine PKG files, indexed in place without extraction.
    let archivePaths: [String]
    let requiresPrivateRoot: Bool
    init(rootURL:URL,manifestIdentity:String,verifiedFiles:[String:String],archivePaths:[String]=[],requiresPrivateRoot:Bool=false) {
        self.rootURL=rootURL;self.manifestIdentity=manifestIdentity;self.verifiedFiles=verifiedFiles;self.archivePaths=archivePaths;self.requiresPrivateRoot=requiresPrivateRoot
    }
}
final class SceneAssetSource {
    private struct MissingLooseResource: Error, LocalizedError {
        let path: String
        var errorDescription: String? { "Missing Scene resource: " + path }
    }
    private let rootDescriptor: Int32
    private var archive: ScenePackageArchive?
    private let limits: SceneReadLimits
    private let requiresPrivateFiles: Bool
    private var engineSource: SceneAssetSource?
    private var engineArchives:[ScenePackageArchive]=[]
    private var engineHashes:[String:String]=[:]
    init(rootURL: URL, limits: SceneReadLimits, engineAssets:SceneEngineAssetBundle? = nil, requiresPrivateRoot:Bool=false) throws {
        let descriptor = requiresPrivateRoot ? try SceneEngineAssetResolver.openPrivateRoot(rootURL) : Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SceneWallpaperFailure(message: "Cannot open Scene project root.") }
        rootDescriptor = descriptor; self.limits = limits; self.requiresPrivateFiles=requiresPrivateRoot
        if let bundle=engineAssets {
            guard !bundle.manifestIdentity.isEmpty,bundle.manifestIdentity.utf8.count<=512,bundle.verifiedFiles.count<=512,bundle.archivePaths.count<=8 else {throw SceneWallpaperFailure(message:"Invalid verified engine-asset identity/count.")}
            let source=try SceneAssetSource(rootURL:bundle.rootURL,limits:limits,requiresPrivateRoot:bundle.requiresPrivateRoot)
            for (path,hash) in bundle.verifiedFiles {
                _ = try ScenePackageArchive.normalizedPath(path)
                guard hash.count==64,hash.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw SceneWallpaperFailure(message:"Invalid engine-asset digest.")}
            }
            for path in bundle.archivePaths {
                guard let hash=bundle.verifiedFiles[path] else {throw SceneWallpaperFailure(message:"Engine archive is not in its verified manifest.")}
                let fd=try source.openFile(path);defer {Darwin.close(fd)}
                var digest=SHA256(),buffer=[UInt8](repeating:0,count:1_048_576),total:UInt64=0
                while true {
                    try Task.checkCancellation()
                    let n=Darwin.read(fd,&buffer,buffer.count)
                    if n<0 && errno==EINTR {continue}
                    guard n>=0 else {throw SceneWallpaperFailure(message:"Engine archive cannot be verified.")}
                    if n==0 {break}
                    total+=UInt64(n);guard total<=limits.maximumArchiveBytes else {throw SceneWallpaperFailure(message:"Engine archive exceeds byte budget.")}
                    digest.update(data:Data(buffer.prefix(n)))
                }
                guard digest.finalize().map({String(format:"%02x",$0)}).joined()==hash else {throw SceneWallpaperFailure(message:"Engine archive differs from verified manifest.")}
                engineArchives.append(try ScenePackageArchive(fileDescriptor:fd,limits:limits))
            }
            engineSource=source;engineHashes=bundle.verifiedFiles
        }
    }
    deinit { Darwin.close(rootDescriptor) }
    func useArchive(_ path: String) throws {
        let path = try ScenePackageArchive.normalizedPath(path)
        let fd = try openFile(path); defer { Darwin.close(fd) }
        archive = try ScenePackageArchive(fileDescriptor: fd, limits: limits)
    }
    func containsLoose(_ path: String) -> Bool {
        guard let fd = try? openFile(path) else { return false }; Darwin.close(fd); return true
    }
    func read(_ path: String, maximumBytes: Int? = nil, looseOnly: Bool = false) throws -> Data {
        let normalized=try ScenePackageArchive.normalizedPath(path)
        if !looseOnly {
            if let archive,archive.contains(normalized) {return try archive.read(normalized,maximumBytes:maximumBytes)}
            let hasLoose:Bool
            do { let descriptor=try openFile(normalized);Darwin.close(descriptor);hasLoose=true }
            catch is MissingLooseResource {hasLoose=false}
            if !hasLoose {
                // Only known engine asset namespaces may resolve outside the
                // workshop. Scene config, scripts and models never fall back.
                let allowed=normalized.hasPrefix("materials/particle/") || normalized.hasPrefix("shaders/") || ["materials/util/noise.tex","materials/gradient/gradient_iridescent.tex","fonts/Alcubierre.otf"].contains(normalized)
                if allowed,let source=engineSource {
                    if let hash=engineHashes[normalized] {
                        let data=try source.read(normalized,maximumBytes:maximumBytes,looseOnly:true)
                        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==hash else {throw SceneWallpaperFailure(message:"Engine resource differs from verified manifest: \(normalized)")}
                        return data
                    }
                    for engineArchive in engineArchives where engineArchive.contains(normalized) {return try engineArchive.read(normalized,maximumBytes:maximumBytes)}
                }
                if let archive {return try archive.read(normalized,maximumBytes:maximumBytes)}
            }
        }
        let fd = try openFile(normalized); defer { Darwin.close(fd) }
        var info = stat()
        let maximum = min(maximumBytes ?? limits.maximumEntryBytes, limits.maximumEntryBytes)
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= maximum else { throw SceneWallpaperFailure(message: "Scene resource exceeds read limit: \(path)") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SceneWallpaperFailure(message: "Could not read Scene resource: \(path)") }
            if count == 0 { return data }
            guard data.count + count <= maximum else { throw SceneWallpaperFailure(message: "Scene resource grew beyond read limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    /// Called only after actual inline bindings were extracted. This collects
    /// source, not dependencies: unreferenced JavaScript is never parsed here.
    func scriptModules(inlineByteCount: Int) throws -> [String: String] {
        let maximumModules = 128, maximumModuleBytes = 256 * 1024
        let maximumTotalBytes = SceneScriptSourcePolicy.maximumTotalSourceBytes
        let maximumEntries = min(20_000, limits.maximumEntries)
        guard inlineByteCount >= 0, inlineByteCount <= maximumTotalBytes, maximumEntries > 0 else {
            throw SceneWallpaperFailure(message: "Invalid SceneScript module snapshot budget.")
        }
        var modules: [String: String] = [:], totalBytes = inlineByteCount, entryCount = 0
        var aliases: [String: Data] = [:]
        func candidate(_ path: String) throws -> String? {
            guard path.split(separator: "/").count <= 32 else { throw SceneWallpaperFailure(message: "SceneScript module enumeration exceeds 32 path components.") }
            guard path.lowercased().hasSuffix(".js") else { return nil }
            guard !path.contains("\\"), path.hasSuffix(".js") else { throw SceneWallpaperFailure(message: "SceneScript modules require canonical paths and lowercase .js extensions: \(path)") }
            let normalized = try ScenePackageArchive.normalizedPath(path)
            let actualParts = path.split(separator: "/"), parts = normalized.split(separator: "/")
            for count in 1...parts.count {
                let prefix = parts.prefix(count).joined(separator: "/")
                let actual = Data(actualParts.prefix(count).joined(separator: "/").utf8)
                let key = prefix.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
                if let previous = aliases[key], previous != actual { throw SceneWallpaperFailure(message: "Ambiguous case/Unicode SceneScript module path: \(path)") }
                aliases[key] = actual
            }
            guard modules[normalized] == nil, modules.count < maximumModules else { throw SceneWallpaperFailure(message: "SceneScript module snapshot exceeds 128 files or contains duplicate paths.") }
            return normalized
        }
        func retain(_ data: Data, path: String) throws {
            guard data.count <= maximumModuleBytes, data.count <= maximumTotalBytes - totalBytes,
                  let source = String(data: data, encoding: .utf8), !source.contains("\0") else {
                throw SceneWallpaperFailure(message: "SceneScript module is not bounded UTF-8 source (256 KiB/file, 1 MiB including inline): \(path)")
            }
            totalBytes += data.count; modules[path] = source
        }
        if let archive {
            for entry in archive.entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
                try Task.checkCancellation(); entryCount += 1
                guard entryCount <= maximumEntries else { throw SceneWallpaperFailure(message: "SceneScript module inventory exceeds directory-entry limit.") }
                if let path = try candidate(entry.path) {
                    try retain(archive.read(entry.path, maximumBytes: min(maximumModuleBytes, maximumTotalBytes - totalBytes)), path: path)
                }
            }
            return modules
        }
        func walk(_ ownedFD: Int32, prefix: String) throws {
            guard let directory = fdopendir(ownedFD) else {
                Darwin.close(ownedFD); throw SceneWallpaperFailure(message: "Cannot enumerate SceneScript project directory.")
            }
            defer { closedir(directory) }
            while true {
                try Task.checkCancellation(); errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw SceneWallpaperFailure(message: "SceneScript directory changed or cannot be read.") }; break
                }
                let length = Int(entry.pointee.d_namlen)
                let nameBytes = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
                guard let name = String(data: nameBytes, encoding: .utf8) else { throw SceneWallpaperFailure(message: "SceneScript directory contains a non-UTF-8 filename.") }
                if name == "." || name == ".." { continue }
                entryCount += 1
                guard entryCount <= maximumEntries else { throw SceneWallpaperFailure(message: "SceneScript module inventory exceeds directory-entry limit.") }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard path.split(separator: "/").count <= 32 else { throw SceneWallpaperFailure(message: "SceneScript module enumeration exceeds 32 path components.") }
                var info = stat()
                guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SceneWallpaperFailure(message: "Cannot inspect SceneScript source path: \(path)") }
                let kind = info.st_mode & S_IFMT
                guard kind != S_IFLNK else { throw SceneWallpaperFailure(message: "SceneScript module inventory refuses symbolic links: \(path)") }
                if kind == S_IFDIR {
                    let child = openat(dirfd(directory), name, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SceneWallpaperFailure(message: "Cannot open SceneScript source directory without following links: \(path)") }
                    try walk(child, prefix: path)
                } else if let key = try candidate(path) {
                    guard kind == S_IFREG else { throw SceneWallpaperFailure(message: "SceneScript source is not a regular file: \(path)") }
                    let fd = openat(dirfd(directory), name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw SceneWallpaperFailure(message: "Cannot safely open SceneScript module: \(path)") }
                    defer { Darwin.close(fd) }
                    var before = stat()
                    let maximum = min(maximumModuleBytes, maximumTotalBytes - totalBytes, limits.maximumEntryBytes)
                    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                          before.st_ino == info.st_ino, before.st_dev == info.st_dev,
                          before.st_size >= 0, before.st_size <= maximum else { throw SceneWallpaperFailure(message: "SceneScript module changed or exceeds source budget: \(path)") }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        try Task.checkCancellation()
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        guard count >= 0, count <= maximum - data.count else { throw SceneWallpaperFailure(message: "SceneScript module grew or cannot be read: \(path)") }
                        if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    }
                    var after = stat()
                    guard fstat(fd, &after) == 0, after.st_size == before.st_size,
                          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                          data.count == Int(before.st_size) else { throw SceneWallpaperFailure(message: "SceneScript module changed during snapshot: \(path)") }
                    try retain(data, path: key)
                }
            }
        }
        let fd = openat(rootDescriptor, ".", O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SceneWallpaperFailure(message: "Cannot enumerate SceneScript project root.") }
        try walk(fd, prefix: "")
        return modules
    }
    private func openFile(_ path: String) throws -> Int32 {
        let pieces = try ScenePackageArchive.normalizedPath(path).split(separator: "/")
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw SceneWallpaperFailure(message: "Scene root descriptor unavailable.") }
        var retained = false
        defer { if !retained { Darwin.close(current) } }
        for (index, piece) in pieces.enumerated() {
            let fd = Darwin.openat(current, String(piece), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (index < pieces.count - 1 ? O_DIRECTORY : 0))
            guard fd >= 0 else {
                if errno == ENOENT {throw MissingLooseResource(path:path)}
                throw SceneWallpaperFailure(message: "Unsafe or inaccessible Scene resource: \(path)")
            }
            Darwin.close(current); current = fd
            if requiresPrivateFiles {
                var info = stat()
                guard fstat(current,&info)==0,info.st_uid==getuid(),info.st_mode & 0o077 == 0,
                      index < pieces.count-1 ? info.st_mode & S_IFMT == S_IFDIR : (info.st_mode & S_IFMT == S_IFREG && info.st_nlink==1) else {throw SceneWallpaperFailure(message:"Verified engine resource is no longer private: \(path)")}
            }
        }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw SceneWallpaperFailure(message: "Scene resource is not a regular file: \(path)") }
        retained = true; return current
    }
}
