import Foundation

/// Labels describe an observed host outcome, never a project filename or script-text guess.
@MainActor
enum SceneWallpaperPresentation {
    static func badge(state: SceneWallpaperRuntime.State?, isAnimated: Bool = false) -> String {
        switch state {
        case .ready: return isAnimated ? "动态 Scene" : "静态 Scene"
        case .paused: return isAnimated ? "动态 Scene · 已暂停" : "静态 Scene · 已暂停"
        case .loading: return "Scene · 正在加载"
        case .failed: return "Scene · 需重试"
        case .disposed: return "Scene · 预览已关闭"
        case .idle: return "Scene · 准备预览"
        case nil: return "Scene"
        }
    }

    static func badge(for runtime: SceneWallpaperRuntime?) -> String {
        guard let runtime else { return "Scene" }
        return badge(state: runtime.state, isAnimated: runtime.isAnimated)
    }

    /// Keep implementation vocabulary out of the primary error explanation. Exact source
    /// diagnostics remain available in the deliberately expanded details for troubleshooting.
    static func errorSummary(_ error: String) -> String {
        let first = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        var diagnostic = first.trimmingCharacters(in: .whitespaces)
        if diagnostic.hasPrefix("Error: ") { diagnostic.removeFirst("Error: ".count) }
        if diagnostic.hasPrefix("Missing SceneScript module: ") {
            return "找不到此壁纸需要的脚本模块。请重新导入完整项目文件夹。"
        }
        if ["Unsafe SceneScript module specifier", "SceneScript module escapes project",
            "Invalid SceneScript module snapshot path", "Invalid SceneScript module path"].contains(diagnostic) {
            return "脚本模块路径不安全或超出项目文件夹。请使用项目内的相对路径。"
        }
        if diagnostic.hasPrefix("Missing or ambiguous module export: ") ||
            diagnostic.hasPrefix("Missing or ambiguous re-export: ") {
            return "脚本模块的导出缺失或重名。请检查完整项目及模块导出。"
        }
        if diagnostic == "Dynamic import and import.meta are not supported" {
            return "此壁纸使用了暂未支持的动态模块加载或模块元信息。请改用静态导入，或选择其他壁纸。"
        }
        if diagnostic == "Asynchronous module evaluation is not supported" {
            return "此壁纸使用了暂未支持的模块顶层异步执行。请调整脚本，或选择其他壁纸。"
        }
        if diagnostic == "Direct eval with module imports is not supported" {
            return "此壁纸的模块脚本使用了暂未支持的直接求值。请移除直接 eval 调用，或选择其他壁纸。"
        }
        let unsupportedEvents = ["destroy", "resizeScreen", "applyGeneralSettings", "cursorEnter", "cursorLeave",
            "cursorMove", "cursorDown", "cursorUp", "cursorClick", "mediaStatusChanged", "mediaPlaybackChanged",
            "mediaPropertiesChanged", "mediaThumbnailChanged", "mediaTimelineChanged"]
        if unsupportedEvents.contains(where: { diagnostic == "Unsupported SceneScript event: " + $0 }) {
            return "此壁纸使用了暂未支持的脚本事件。请选择其他壁纸，或等待兼容更新。"
        }
        return String(first.prefix(240))
            .replacingOccurrences(of: "helper", with: "渲染服务", options: .caseInsensitive)
            .replacingOccurrences(of: "worker", with: "渲染服务", options: .caseInsensitive)
            .replacingOccurrences(of: "IPC", with: "连接", options: .caseInsensitive)
    }
}
