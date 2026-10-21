import Darwin
import Foundation

/// Independent per-library-item overrides. Never edits source project.json, opens
/// selected files/directories, or claims that a renderer has consumed these values.
actor AuthorPropertyOverrideStore {
    static let maximumBytes = 1024 * 1024
    private let directory: URL
    private var itemRemovals: [UUID: UUID] = [:]
    private var removedItems: Set<UUID> = []

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    /// Serialized with direct UI writes. A deletion barrier never reads a
    /// document, so even corrupt settings can be moved safely to Trash.
    func beginItemRemoval(itemID: UUID, token: UUID) throws {
        try requireAvailable(itemID)
        itemRemovals[itemID] = token
    }

    func finishItemRemoval(itemID: UUID, token: UUID, committed: Bool) {
        guard itemRemovals[itemID] == token else { return }
        itemRemovals[itemID] = nil
        if committed { removedItems.insert(itemID) }
    }

    private func requireAvailable(_ itemID: UUID) throws {
        guard itemRemovals[itemID] == nil, !removedItems.contains(itemID) else {
            throw AuthorPropertyError(message: "此壁纸正在删除或已删除，未重新创建作者设置")
        }
    }

    func load(itemID: UUID) throws -> [String: GWJSONValue] {
        try document(itemID: itemID)["values"]?.objectValue ?? [:]
    }

    func set(_ value: GWJSONValue?, for key: String, itemID: UUID, project: AuthorPropertyProject) throws {
        guard !key.isEmpty, key.utf8.count <= 512 else { throw AuthorPropertyError(message: "作者属性键无效") }
        if let value {
            guard let definition = project.definition(for: key) else { throw AuthorPropertyError(message: "作者项目没有此属性，未保存覆盖值") }
            try definition.validate(value)
        }
        var current = try document(itemID: itemID)
        var values = current["values"]?.objectValue ?? [:]
        values[key] = value
        current["values"] = .object(values)
        try save(current, itemID: itemID)
    }

    func reset(itemID: UUID) throws {
        var current = try document(itemID: itemID)
        current["values"] = .object([:])
        try save(current, itemID: itemID)
    }

    func resolve(itemID: UUID, project: AuthorPropertyProject) throws -> AuthorPropertyResolution {
        project.resolve(overrides: try load(itemID: itemID))
    }

    private func fileURL(_ itemID: UUID) -> URL { directory.appendingPathComponent(itemID.uuidString + ".json") }

    private func validateDirectory(create: Bool) throws -> Bool {
        guard directory.isFileURL else { throw AuthorPropertyError(message: "覆盖值目录必须是本地目录") }
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            if !create { return false }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // The actor retains this URL. Foundation resource values can cache a
        // prior non-directory across a failed save and a later filesystem fix.
        // lstat also checks the final component without following a symlink.
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == getuid() else {
            throw AuthorPropertyError(message: "覆盖值目录不属于当前用户或是符号链接")
        }
        if create { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        return true
    }

    private func document(itemID: UUID) throws -> [String: GWJSONValue] {
        try requireAvailable(itemID)
        let empty: [String: GWJSONValue] = ["schemaVersion": .number(1), "itemID": .string(itemID.uuidString), "values": .object([:])]
        guard try validateDirectory(create: false) else { return empty }
        let url = fileURL(itemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let count = metadata.fileSize, count <= Self.maximumBytes else {
            throw AuthorPropertyError(message: "覆盖值文件不是当前用户的常规文件或超过大小限制")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw AuthorPropertyError(message: "覆盖值文件超过大小限制") }
        let json = try JSONDecoder().decode(GWJSONValue.self, from: data)
        guard let object = json.objectValue, object["schemaVersion"] == .number(1),
              object["itemID"]?.stringValue.flatMap(UUID.init(uuidString:)) == itemID,
              object["values"]?.objectValue != nil else {
            throw AuthorPropertyError(message: "覆盖值文件版本、素材 UUID 或结构无效，原文件保持不变")
        }
        return object
    }

    private func save(_ document: [String: GWJSONValue], itemID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(GWJSONValue.object(document))
        guard bytes.count <= Self.maximumBytes else { throw AuthorPropertyError(message: "覆盖值超过大小限制，未保存") }
        _ = try validateDirectory(create: true)
        let destination = fileURL(itemID)
        if let value = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), value.isSymbolicLink == true {
            throw AuthorPropertyError(message: "覆盖值目标是符号链接，未保存")
        }
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
