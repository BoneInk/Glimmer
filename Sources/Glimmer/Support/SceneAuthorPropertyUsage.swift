import Darwin
import Foundation

/// Conservative, read-only evidence for author settings that have no textual
/// binding in the original Scene source. An inconclusive result is deliberately
/// indistinguishable from "no notes" in the UI.
struct SceneAuthorPropertyUsage: Equatable, Sendable {
    let unreferencedScalarKeys: Set<String>
    let isConclusive: Bool

    static let unavailable = SceneAuthorPropertyUsage(
        unreferencedScalarKeys: [], isConclusive: false)
}

/// Scans only bounded local Scene JSON/JavaScript sources. It never executes a
/// script, reads registered/remote engine assets, writes files or changes values.
enum SceneAuthorPropertyUsageAnalyzer {
    private static let maximumSourceFiles = 512
    private static let maximumSourceFileBytes = 512 * 1024
    private static let maximumSourceTotalBytes = 8 * 1024 * 1024
    private static let maximumDirectoryEntries = 20_000
    private static let maximumDirectoryDepth = 24

    static func analyze(project: AuthorPropertyProject) -> SceneAuthorPropertyUsage {
        guard project.projectType.lowercased() == "scene",
              project.rawJSON.objectValue?["dependencies"] == nil,
              let entry = project.rawJSON.objectValue?["file"]?.stringValue,
              let normalizedEntry = try? ScenePackageArchive.normalizedPath(entry) else {
            return .unavailable
        }
        let root = project.projectURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard let sources = loadSources(root: root, entry: normalizedEntry),
              !sources.isEmpty,
              !sources.contains(where: { hasDynamicOrUnknownAccess($0) }) else {
            return .unavailable
        }
        let scalarKeys = Set(project.properties.filter {
            switch $0.kind {
            case .bool, .color, .slider, .combo, .textinput: return true
            case .file, .directory, .text, .unknown: return false
            }
        }.map(\.key).filter { $0.lowercased() != "schemecolor" })
        guard !scalarKeys.isEmpty else {
            return SceneAuthorPropertyUsage(unreferencedScalarKeys: [], isConclusive: true)
        }
        var referenced = Set<String>()
        for source in sources {
            collectReferences(in: source, keys: scalarKeys, into: &referenced)
        }
        return SceneAuthorPropertyUsage(
            unreferencedScalarKeys: scalarKeys.subtracting(referenced), isConclusive: true)
    }

    private static func loadSources(root: URL, entry: String) -> [String]? {
        if entry.lowercased().hasSuffix(".pkg") {
            return packageSources(root: root, packagePath: entry, scenePath: "scene.json")
        }
        let loose = root.appendingPathComponent(entry).standardizedFileURL
        if FileManager.default.fileExists(atPath: loose.path) {
            guard safeRegularFile(loose, root: root) != nil else { return nil }
            return looseSources(root: root)
        }
        return packageSources(root: root, packagePath: "scene.pkg", scenePath: entry)
    }

    private static func packageSources(root: URL, packagePath: String,
                                       scenePath: String) -> [String]? {
        guard let normalizedPackage = try? ScenePackageArchive.normalizedPath(packagePath),
              let packageURL = safeRegularFile(
                root.appendingPathComponent(normalizedPackage).standardizedFileURL, root: root),
              let archive = try? ScenePackageArchive(url: packageURL),
              archive.contains(scenePath) else {
            return nil
        }
        var sources: [String] = []
        var totalBytes = 0
        for entry in archive.entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let ext = fileExtension(entry.path)
            if unknownScriptExtensions.contains(ext) { return nil }
            guard ext == "json" || ext == "js" else { continue }
            if baseName(entry.path) == "project.json" { continue }
            guard sources.count < maximumSourceFiles,
                  entry.length >= 0,
                  entry.length <= maximumSourceFileBytes,
                  entry.length <= maximumSourceTotalBytes - totalBytes else {
                return nil
            }
            let data: Data
            do {
                data = try archive.read(entry.path, maximumBytes: entry.length)
            } catch {
                return nil
            }
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                return nil
            }
            if ext == "json" {
                guard let json = try? JSONSerialization.jsonObject(with: data),
                      dependenciesAreLocal(json, contains: archive.contains) else { return nil }
            }
            totalBytes += data.count
            sources.append(text)
        }
        return sources.isEmpty ? nil : sources
    }

    private static func looseSources(root: URL) -> [String]? {
        var pending: [(URL, Int)] = [(root, 0)]
        var entriesSeen = 0
        var sources: [String] = []
        var totalBytes = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        while let (directory, depth) = pending.popLast() {
            guard depth <= maximumDirectoryDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(keys), options: []) else {
                return nil
            }
            for child in children.sorted(by: { $0.path < $1.path }) {
                entriesSeen += 1
                guard entriesSeen <= maximumDirectoryEntries,
                      let values = try? child.resourceValues(forKeys: keys) else {
                    return nil
                }
                if values.isSymbolicLink == true { return nil }
                let standardized = child.standardizedFileURL
                let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.path == standardized.path, isInside(canonical, root: root) else {
                    return nil
                }
                if values.isDirectory == true {
                    pending.append((canonical, depth + 1))
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let ext = fileExtension(standardized.path)
                if unknownScriptExtensions.contains(ext) { return nil }
                guard ext == "json" || ext == "js" else { continue }
                if baseName(standardized.path) == "project.json" { continue }
                guard sources.count < maximumSourceFiles,
                      let size = values.fileSize, size >= 0,
                      size <= maximumSourceFileBytes,
                      size <= maximumSourceTotalBytes - totalBytes,
                      let data = readBoundedRegularFile(standardized, maximumBytes: size),
                      let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                    return nil
                }
                totalBytes += data.count
                if ext == "json" {
                    guard let json = try? JSONSerialization.jsonObject(with: data),
                          dependenciesAreLocal(json, contains: { path in
                              guard let normalized = try? ScenePackageArchive.normalizedPath(path) else { return false }
                              return safeRegularFile(root.appendingPathComponent(normalized), root: root) != nil
                          }) else { return nil }
                }
                sources.append(text)
            }
        }
        return sources.isEmpty ? nil : sources
    }

    private static var unknownScriptExtensions: Set<String> {
        ["mjs", "cjs", "jsx", "ts", "tsx"]
    }

    private static func safeRegularFile(_ lexical: URL, root: URL) -> URL? {
        let standardized = lexical.standardizedFileURL
        guard isInside(standardized, root: root) else { return nil }
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == standardized.path,
              let values = try? canonical.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        return canonical
    }

    private static func readBoundedRegularFile(_ url: URL, maximumBytes: Int) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= maximumBytes else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return data }
            guard count <= maximumBytes - data.count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func collectReferences(in source: String, keys: Set<String>,
                                          into referenced: inout Set<String>) {
        if let data = source.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            func visit(_ value: Any, binding: Bool = false) {
                if let object = value as? [String: Any] {
                    for (key, child) in object {
                        let isBinding = binding || ["user", "userproperty", "property", "script", "expression", "code"].contains(key.lowercased())
                        visit(child, binding: isBinding)
                    }
                } else if let values = value as? [Any] {
                    for child in values { visit(child, binding: binding) }
                } else if binding, let text = value as? String {
                    collectTokens(in: text, keys: keys, into: &referenced)
                }
            }
            // A directory such as "particles/…" is an asset path, not a
            // reference to a user option named "particles".
            visit(json)
            return
        }
        collectTokens(in: source, keys: keys, into: &referenced)
    }

    private static func collectTokens(in source: String, keys: Set<String>,
                                      into referenced: inout Set<String>) {
        var token = ""
        token.reserveCapacity(64)
        for character in source {
            if character == "_" || character == "$" || character.isLetter || character.isNumber {
                token.append(character)
            } else if !token.isEmpty {
                if keys.contains(token) { referenced.insert(token) }
                token.removeAll(keepingCapacity: true)
            }
        }
        if !token.isEmpty, keys.contains(token) { referenced.insert(token) }

        // Property names are normally JavaScript identifiers. Preserve a
        // conservative exact-substring fallback for unusual authored names.
        for key in keys where !referenced.contains(key) && !isIdentifierToken(key) {
            if source.range(of: key) != nil { referenced.insert(key) }
        }
    }

    private static func isIdentifierToken(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy {
            $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber
        }
    }

    private static func hasDynamicOrUnknownAccess(_ source: String) -> Bool {
        if let bytes = source.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bytes) {
            func uncertain(_ value: Any) -> Bool {
                if let object = value as? [String: Any] {
                    for (key, value) in object {
                        if key.lowercased() == "modules" { return true }
                        if key == "script", let path = value as? String,
                           path.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".js") { return true }
                        if uncertain(value) { return true }
                    }
                } else if let array = value as? [Any] {
                    return array.contains(where: uncertain)
                } else if let text = value as? String {
                    return dynamicPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
                }
                return false
            }
            return uncertain(json)
        }
        return dynamicPatterns.contains {
            source.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Effect manifests list local materials/shaders as dependencies. Those are
    /// already part of the original package/source corpus, unlike an unresolved
    /// external Workshop/module dependency, and need not suppress all notes.
    private static func dependenciesAreLocal(_ value: Any, contains: (String) -> Bool) -> Bool {
        if let object = value as? [String: Any] {
            for (key, value) in object {
                if key.lowercased() == "dependencies" {
                    guard let paths = value as? [String], paths.allSatisfy(contains) else { return false }
                } else if !dependenciesAreLocal(value, contains: contains) { return false }
            }
        } else if let array = value as? [Any] {
            return array.allSatisfy { dependenciesAreLocal($0, contains: contains) }
        }
        return true
    }

    /// Any dynamic property lookup, script/module loader, reflection or
    /// dependency declaration makes absence of a key inconclusive.
    private static let dynamicPatterns: [String] = [
        #"\b[A-Za-z_$][A-Za-z0-9_$]*\s*\[\s*[A-Za-z_$0-9{`]"#,
        #"\bObject\s*\.\s*(?:keys|values|entries|getOwnPropertyNames)\s*\("#,
        #"\b(?:in|of)\s+[A-Za-z_$]"#,
        #"\beval\s*(?:\(|\.)"#,
        #"\bnew\s+Function\b"#,
        #"\bFunction\s*\("#,
        #"\b(?:Reflect|Proxy)\b"#,
        #"\brequire\b"#,
        #"\bimport\b"#,
        #"\bwith\s*\("#,
        #"\bObject\s*\.\s*(?:keys|values|entries|getOwnPropertyNames)\s*\(\s*(?:properties|userProperties)\b"#,
        #"\bin\s+(?:properties|userProperties)\b"#,
        #"\b(?:properties|userProperties)\s*\[\s*[A-Za-z_$0-9{]"#,
        #"\b(?:properties|userProperties)\s*\[\s*["'][^"']*["']\s*\+"#,
        #"\b(?:properties|userProperties)\s*\[\s*`[^`]*\$\{"#,
        #"\bscript\b\s*:\s*["'][^"']*\.(?:mjs|cjs|js)["']"#,
        #"\b(?:dependencies?|modules?)\s*:\s*[\[\{]"#
    ]

    private static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }

    private static func fileExtension(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }
}
