import Foundation

enum AuthorPropertyKind: String, Codable, Sendable {
    case color, slider, bool, combo, textinput, file, directory, text, unknown
}

struct AuthorPropertyOption: Identifiable, Hashable, Sendable {
    let id: Int
    let rawJSON: GWJSONValue
    var label: String { rawJSON.objectValue?["label"]?.stringValue ?? rawJSON.objectValue?["text"]?.stringValue ?? "" }
    var value: GWJSONValue? { rawJSON.objectValue?["value"] }
}

struct AuthorPropertyDefinition: Identifiable, Hashable, Sendable {
    let key: String
    let rawJSON: GWJSONValue
    var id: String { key }
    var raw: [String: GWJSONValue] { rawJSON.objectValue ?? [:] }
    var rawType: String { raw["type"]?.stringValue ?? "" }
    var kind: AuthorPropertyKind { AuthorPropertyKind(rawValue: rawType) ?? .unknown }
    var defaultValue: GWJSONValue? { raw["value"] }
    var order: Double { raw["order"]?.numberValue ?? 0 }
    var condition: String? { raw["condition"]?.stringValue }
    var text: String { raw["text"]?.stringValue ?? key }
    var minimum: Double? { raw["min"]?.numberValue }
    var maximum: Double? { raw["max"]?.numberValue }
    var step: Double? { raw["step"]?.numberValue }
    var fraction: Bool? { raw["fraction"]?.boolValue }
    var precision: Int? {
        guard let value = raw["precision"]?.numberValue, value.isFinite,
              value.rounded() == value, (0...16).contains(value) else { return nil }
        return Int(value)
    }
    var options: [AuthorPropertyOption] {
        (raw["options"]?.arrayValue ?? []).enumerated().map { AuthorPropertyOption(id: $0.offset, rawJSON: $0.element) }
    }
    var isEditableSchema: Bool { kind != .text && kind != .unknown }

    func validate(_ value: GWJSONValue) throws {
        func fail(_ message: String) throws -> Never { throw AuthorPropertyError(message: "\(key)：\(message)") }
        switch kind {
        case .bool:
            guard value.boolValue != nil else { try fail("必须是布尔值") }
        case .slider:
            if raw["fraction"] != nil && fraction == nil { try fail("作者小数选项无效") }
            if raw["precision"] != nil && precision == nil { try fail("作者精度选项无效") }
            guard let number = value.numberValue, number.isFinite,
                  let minimum, let maximum, minimum.isFinite, maximum.isFinite, minimum <= maximum else { try fail("滑块数值或作者范围无效") }
            guard (minimum...maximum).contains(number) else { try fail("超出作者允许的范围") }
            if fraction != true && number.rounded() != number { try fail("此滑块只接受整数") }
            if let rawStep = raw["step"] {
                guard let step = rawStep.numberValue, step.isFinite, step > 0 else { try fail("作者步长无效") }
                let ticks = (number - minimum) / step
                guard ticks.isFinite, abs(ticks - ticks.rounded()) <= 1e-7 else { try fail("数值不符合作者步长") }
            }
        case .color:
            guard let text = value.stringValue else { try fail("颜色必须是三个以空格分隔的 RGB 分量") }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts.allSatisfy({ Double($0).map { $0.isFinite && (0...1).contains($0) } == true }) else { try fail("颜色 RGB 分量必须在 0 到 1 之间") }
        case .combo:
            guard !options.isEmpty, options.allSatisfy({ $0.value != nil }), options.contains(where: {
                if let a = $0.value?.stringValue, let b = value.stringValue { return Array(a.utf16) == Array(b.utf16) }
                return $0.value == value
            }) else { try fail("选项不在作者定义的列表中") }
        case .textinput:
            guard let string = value.stringValue, string.utf8.count <= 65_536, !string.contains("\0") else { try fail("文本值类型或长度无效") }
        case .file, .directory:
            guard let string = value.stringValue, string.utf8.count <= 4096, !string.contains("\0") else { try fail("文件或目录值必须是有效路径字符串") }
            // This is a schema value only. No filesystem access or runtime grant is implied.
        case .text: try fail("说明文字是只读属性")
        case .unknown: try fail("尚不支持作者定义的属性类型 \(rawType)")
        }
    }
}

struct AuthorPropertyDiagnostic: Hashable, Sendable {
    let key: String
    let message: String
}

struct AuthorPropertyResolution: Sendable {
    let values: [String: GWJSONValue]
    let diagnostics: [AuthorPropertyDiagnostic]
    let unknownOverrides: [String: GWJSONValue]
}

struct AuthorPropertyProject: Sendable {
    static let maximumBytes = 2 * 1024 * 1024
    let projectURL: URL
    let sourceData: Data
    let rawJSON: GWJSONValue
    let properties: [AuthorPropertyDefinition]
    var projectType: String { rawJSON.objectValue?["type"]?.stringValue ?? "" }
    var localization: GWJSONValue { rawJSON.objectValue?["general"]?.objectValue?["localization"] ?? .object([:]) }

    static func load(projectURL: URL, allowedRoot: URL) throws -> Self {
        let path = projectURL.standardizedFileURL
        let lexicalRoot = allowedRoot.standardizedFileURL
        let canonicalRoot = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard path.isFileURL, allowedRoot.isFileURL, path.lastPathComponent.lowercased() == "project.json",
              path.path.hasPrefix(lexicalRoot.path + "/") else { throw AuthorPropertyError(message: "project.json 必须位于指定作品目录内") }
        let relative = String(path.path.dropFirst(lexicalRoot.path.count + 1))
        guard path.resolvingSymlinksInPath().standardizedFileURL == canonicalRoot.appendingPathComponent(relative).standardizedFileURL else {
            throw AuthorPropertyError(message: "project.json 路径包含符号链接或越过作品目录")
        }
        let metadata = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, size <= maximumBytes else { throw AuthorPropertyError(message: "project.json 不是常规文件或超过 2 MiB") }
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw AuthorPropertyError(message: "project.json 超过大小限制") }
        return try parse(data: bytes, projectURL: path)
    }

    static func parse(data: Data, projectURL: URL) throws -> Self {
        guard data.count <= maximumBytes else { throw AuthorPropertyError(message: "project.json 超过大小限制") }
        var input = data
        if input.starts(with: [0xef, 0xbb, 0xbf]) { input.removeFirst(3) }
        let json = try JSONDecoder().decode(GWJSONValue.self, from: input)
        guard let root = json.objectValue else { throw AuthorPropertyError(message: "project.json 根节点必须是对象") }
        let propertyJSON = root["general"]?.objectValue?["properties"]
        if let propertyJSON, propertyJSON.objectValue == nil { throw AuthorPropertyError(message: "general.properties 必须是对象") }
        let definitions = (propertyJSON?.objectValue ?? [:]).map { AuthorPropertyDefinition(key: $0.key, rawJSON: $0.value) }
        guard definitions.count <= 2048 else { throw AuthorPropertyError(message: "作者属性超过数量限制") }
        return Self(projectURL: projectURL, sourceData: data, rawJSON: json,
                    properties: definitions.sorted { $0.order == $1.order ? $0.key < $1.key : $0.order < $1.order })
    }

    func definition(for key: String) -> AuthorPropertyDefinition? { properties.first { $0.key == key } }

    func resolve(overrides: [String: GWJSONValue]) -> AuthorPropertyResolution {
        var values: [String: GWJSONValue] = [:]
        var diagnostics: [AuthorPropertyDiagnostic] = []
        for definition in properties {
            guard definition.isEditableSchema else {
                if let value = definition.defaultValue { values[definition.key] = value }
                if definition.kind == .unknown { diagnostics.append(.init(key: definition.key, message: "未知属性类型已保留，尚未支持编辑：\(definition.rawType)")) }
                if overrides[definition.key] != nil { diagnostics.append(.init(key: definition.key, message: "只读或未知类型的覆盖值未应用")) }
                continue
            }
            if let value = definition.defaultValue {
                do { try definition.validate(value); values[definition.key] = value }
                catch { diagnostics.append(.init(key: definition.key, message: "作者默认值无效：" + error.localizedDescription)) }
            }
            if let value = overrides[definition.key] {
                do { try definition.validate(value); values[definition.key] = value }
                catch { diagnostics.append(.init(key: definition.key, message: "覆盖值无效，保留有效默认值：" + error.localizedDescription)) }
            }
        }
        let keys = Set(properties.map(\.key))
        return .init(values: values, diagnostics: diagnostics, unknownOverrides: overrides.filter { !keys.contains($0.key) })
    }

    func localizedText(_ token: String, preferredLanguages: [String]) -> String {
        guard token.hasPrefix("ui_"), let languages = localization.objectValue else { return token }
        func normalized(_ language: String) -> String { language.lowercased().replacingOccurrences(of: "_", with: "-") }
        func candidates(_ input: String) -> [String] {
            let key = normalized(input)
            if key == "zh-chs" || key.hasPrefix("zh-hans") || key == "zh-cn" || key == "zh-sg" { return [key, "zh-chs", "zh-cn"] }
            if key == "zh-cht" || key.hasPrefix("zh-hant") || key == "zh-tw" || key == "zh-hk" { return [key, "zh-cht", "zh-tw"] }
            let base = key.split(separator: "-").first.map(String.init) ?? key
            return [key, base] + languages.keys.map(normalized).filter { $0.hasPrefix(base + "-") }.sorted()
        }
        let catalog = Dictionary(languages.sorted { $0.key < $1.key }.map { (normalized($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        for language in preferredLanguages.flatMap(candidates) + ["en-us", "en"] {
            if let translation = catalog[language]?.objectValue?[token]?.stringValue { return translation }
        }
        return token
    }

    func visibility(for key: String, values: [String: GWJSONValue]) -> AuthorPropertyConditionResult {
        guard let definition = definition(for: key) else { return .unsupported("找不到作者属性") }
        if let condition = definition.raw["condition"], condition.stringValue == nil { return .unsupported("作者条件不是文本表达式") }
        return AuthorPropertyCondition.evaluate(definition.condition, values: values)
    }
}
