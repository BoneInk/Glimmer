import Foundation

/// Isolated presentation contract fixture. Real runtime/ACK tests run separately.
@MainActor final class SceneWallpaperRuntime {
    enum State: String { case idle, loading, ready, paused, failed, disposed }
    var state: State
    var isAnimated: Bool
    init(_ state: State, animated: Bool) { self.state = state; isAnimated = animated }
}

@main enum ScenePresentationTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        check(SceneWallpaperPresentation.badge(state: nil, isAnimated: true) == "Scene", "unknown host never implies animation support")
        for state in [SceneWallpaperRuntime.State.idle, .loading, .failed, .disposed] {
            let text = SceneWallpaperPresentation.badge(state: state, isAnimated: true)
            check(!text.contains("动态") && !text.contains("静态"), "nonready state never fabricates runtime mode")
        }
        check(SceneWallpaperPresentation.badge(state: .ready, isAnimated: false) == "静态 Scene", "observed ready static mode")
        check(SceneWallpaperPresentation.badge(state: .ready, isAnimated: true) == "动态 Scene", "observed ready dynamic mode")
        check(SceneWallpaperPresentation.badge(state: .paused, isAnimated: true) == "动态 Scene · 已暂停", "pause preserves observed dynamic capability")
        check(SceneWallpaperPresentation.badge(for: nil) == "Scene", "unopened card is neutral")
        let runtime = SceneWallpaperRuntime(.ready, animated: true)
        check(SceneWallpaperPresentation.badge(for: runtime) == "动态 Scene", "host badge reads actual runtime capability")
        runtime.state = .failed
        check(SceneWallpaperPresentation.badge(for: runtime).contains("重试"), "failure replaces mode with actionable state")
        let error = SceneWallpaperPresentation.errorSummary("helper IPC connection failed\nSceneScript source line 19")
        check(!error.localizedCaseInsensitiveContains("helper") && !error.contains("IPC") && !error.contains("line 19"), "primary explanation hides implementation words and stack noise")
        check(SceneWallpaperPresentation.errorSummary(String(repeating: "错", count: 500)).count == 240, "primary explanation is bounded, full diagnostics stay separate")
        let missingModule = "Missing SceneScript module: scripts/motion.js\nOriginal stack at motion.js:3"
        check(SceneWallpaperPresentation.errorSummary(missingModule) == "找不到此壁纸需要的脚本模块。请重新导入完整项目文件夹。", "missing module offers complete-folder recovery")
        check(missingModule.contains("Original stack at motion.js:3"), "summary leaves original expanded diagnostic unchanged")
        check(SceneWallpaperPresentation.errorSummary("Error: Missing SceneScript module: x.js").contains("重新导入"), "known Error prefix is accepted")
        for error in ["Unsafe SceneScript module specifier", "SceneScript module escapes project", "Invalid SceneScript module snapshot path", "Invalid SceneScript module path"] {
            check(SceneWallpaperPresentation.errorSummary(error).contains("项目内的相对路径"), "known unsafe module path is actionable")
        }
        for error in ["Missing or ambiguous module export: value", "Missing or ambiguous re-export: default"] {
            check(SceneWallpaperPresentation.errorSummary(error).contains("导出缺失或重名"), "known export failure maps without guessing which case occurred")
        }
        for error in ["Dynamic import and import.meta are not supported", "Asynchronous module evaluation is not supported", "Direct eval with module imports is not supported"] {
            check(SceneWallpaperPresentation.errorSummary(error).contains("暂未支持"), "known module capability failure is not mislabeled transient")
        }
        for event in ["cursorMove", "mediaPlaybackChanged", "destroy", "resizeScreen", "applyGeneralSettings"] {
            check(SceneWallpaperPresentation.errorSummary("Unsupported SceneScript event: " + event).contains("暂未支持的脚本事件"), "known incomplete event is explicit")
        }
        for unknown in ["Unsafe image decoder failed", "Missing user setting", "Unsupported SceneScript event: futureUnknown", "TypeError: cannot read property", "Module network unavailable"] {
            check(SceneWallpaperPresentation.errorSummary(unknown) == unknown, "unknown errors preserve existing fallback")
        }
        print("PASS \(checks) Scene presentation checks; contract fixture only, no GUI/runtime launch")
    }
}
