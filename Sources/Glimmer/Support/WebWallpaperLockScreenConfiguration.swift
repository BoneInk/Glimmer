import Foundation

/// Resolves the same validated scalar defaults and saved per-item overrides used by
/// Web preview. Native resource grants stay closed during recording.
enum WebWallpaperLockScreenConfiguration {
    static func payload(item: WallpaperItem, storage: AppStorage) async throws -> Data {
        let project = try AuthorPropertyProject.load(projectURL: item.fileURL,
                                                      allowedRoot: item.fileURL.deletingLastPathComponent())
        let overrides = AuthorPropertyOverrideStore(directory:
            storage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true))
        let resolution = try await overrides.resolve(itemID: item.id, project: project)
        let supported: Set<AuthorPropertyKind> = [.bool, .color, .slider, .combo, .textinput, .file, .directory]
        var result: [String: GWJSONValue] = [:]
        for definition in project.properties where supported.contains(definition.kind) {
            if definition.kind == .directory, definition.raw["mode"]?.stringValue == "fetchall" { continue }
            guard let value = resolution.values[definition.key] else { continue }
            try definition.validate(value)
            if definition.kind == .file || definition.kind == .directory {
                guard value.stringValue?.isEmpty != false else {
                    throw WebProjectError.invalid("该网页使用已选择的外部资源，暂不能生成动态锁屏。")
                }
            }
            var raw = definition.raw
            raw["value"] = value
            result[definition.key] = .object(raw)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(GWJSONValue.object(result))
    }
}
