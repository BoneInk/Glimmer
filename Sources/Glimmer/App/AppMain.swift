import AppKit
import SwiftUI

/// 应用入口。
///
/// 支持的命令行模式（便于验证与自动化，不影响正常图形界面使用）：
/// - 无参数：启动图形界面（菜单栏 + 素材库窗口）
/// - `--self-test [--evidence <目录>] [--library <目录>] [--frames <n>] [--keep-artifacts]`
/// - `--list-displays` / `--help`
@main
@MainActor
enum GlimmerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            exit(0)
        }

        if arguments.contains("--self-test") {
            runSelfTest(arguments: arguments)
        }
        #if GW_UNIVERSAL_SCENE_BACKEND
        if arguments.contains("--self-test-universal-scene") { runUniversalSceneTest(arguments: arguments) }
        #endif

        if arguments.contains("--list-displays") {
            listDisplays()
            exit(0)
        }

        if arguments.contains("--inspect-scene-engine-assets") || arguments.contains("--download-scene-engine-assets") || arguments.contains("--inventory-scene-engine-assets") || arguments.contains("--download-scene-runtime-assets") {
            runEngineAssetInspection(arguments: arguments)
        }

        GlimmerApp.main()
    }

    private static func runSelfTest(arguments: [String]) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        Task { @MainActor in
            exitCode = await SelfTestRunner.run(arguments: arguments)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(exitCode)
    }

    private static func listDisplays() {
        MainActor.assumeIsolated {
            let registry = DisplayRegistry(observeChanges: false)
            print("检测到 \(registry.displays.count) 台显示器：")
            for display in registry.displays {
                print(" - \(display.localizedName) id=\(display.id) \(display.resolutionText) scale=\(display.backingScaleFactor) 主屏=\(display.isPrimary)")
                print("   逻辑坐标: \(display.frame)")
            }
        }
    }

    private static func runEngineAssetInspection(arguments: [String]) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 1
        Task { @MainActor in
            status = await SceneEngineAssetDiagnostic.run(arguments: arguments)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    #if GW_UNIVERSAL_SCENE_BACKEND
    private static func runUniversalSceneTest(arguments: [String]) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 1
        Task { @MainActor in
            status = await SceneUniversalDiagnostic.run(arguments: arguments)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }
    #endif

    private static func printUsage() {
        print("""
        Glimmer \(AppConstants.version)

        用法:
          Glimmer                          启动图形界面
          Glimmer --self-test              运行完整自检（临时目录，不修改真实桌面/壁纸）
              --evidence <目录>                    将截图与报告写入指定目录
              --library <目录>                     使用指定数据目录（默认临时目录）
              --frames <n>                        解码帧采样次数（默认 6）
              --keep-artifacts                    保留临时测试目录
          Glimmer --self-test --smoke      只运行有界的解码/播放冒烟检查（推荐用于快速验证）
              --smoke-file <视频文件>             额外用一份真实视频（只读）做解码/播放检查
          Glimmer --list-displays          列出显示器与稳定 UUID
          Glimmer --inspect-scene-engine-assets --evidence <目录>
                                                  查询已授权 Scene 资源清单，不下载资源文件
          Glimmer --inventory-scene-engine-assets --evidence <目录>
                                                  生成完整的官方资源 manifest 元数据清单，不下载资源文件
          Glimmer --download-scene-runtime-assets --evidence <目录>
                                                  下载并校验固定的 Scene 通用运行资源数据集
          Glimmer --download-scene-engine-assets --evidence <目录>
                                                  校验并缓存 Scene 所需的官方内置资源
          Glimmer --help                   显示本帮助

        说明:
          - 桌面壁纸只会在你点击卡片上的「应用」按钮后才会出现在桌面窗口里。
          - 自检与预览入口不会改变当前桌面图片。
        """)
    }
}
