import Foundation

/// 白名单必须来自真正接通的播放器；属性存在并不代表播放器支持它。
struct AuthorPropertyEditingCapabilities: Hashable, Sendable {
    let editableKeys: Set<String>
    let runtimeLabel: String
    let unsupportedReason: String

    init(editableKeys: Set<String>, runtimeLabel: String, unsupportedReason: String) {
        self.editableKeys = editableKeys
        self.runtimeLabel = runtimeLabel
        self.unsupportedReason = unsupportedReason
    }

    /// 只生成候选键。调用方仍须确认当前 Web host 实际支持这些属性。
    static func scalarKeys(in project: AuthorPropertyProject) -> Set<String> {
        Set(project.properties.filter {
            switch $0.kind {
            case .bool, .color, .slider, .combo, .textinput: return true
            case .file, .directory, .text, .unknown: return false
            }
        }.map(\.key))
    }

    /// Presentation gate for compact immersive settings. A declared raw key or
    /// text heading alone is not a usable editor; runtime capabilities stay live.
    func hasEditableOptions(in project: AuthorPropertyProject) -> Bool {
        let values = project.resolve(overrides: [:]).values
        return project.properties.contains { allows($0, project: project, values: values) }
    }

    func allows(_ definition: AuthorPropertyDefinition, project: AuthorPropertyProject,
                values: [String: GWJSONValue]) -> Bool {
        guard editableKeys.contains(definition.key), definition.isEditableSchema else { return false }
        if case .unsupported = project.visibility(for: definition.key, values: values) { return false }
        return true
    }
}
