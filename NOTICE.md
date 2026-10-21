# NOTICE — 第三方组件与许可

Glimmer 原创源码以 [MIT](LICENSE) 许可发布。仓库同时包含第三方组件，各自保留其原始许可；根目录 MIT 许可不覆盖这些组件。

## Scene 社区后端

`Vendor/OpenWallpaperEngine/` 来自 [deepratna-awale/open-wallpaper-engine-mac](https://github.com/deepratna-awale/open-wallpaper-engine-mac)，固定上游提交为 `8d9e86d16e87395d0ab46710b05ecc24fd992539`，包含 Glimmer 的通用渲染、资源校验与 XPC 接入修改。

- 仓库级许可：`Vendor/OpenWallpaperEngine/LICENSE`（GPL-3.0）。
- 来源记录：`Vendor/OpenWallpaperEngine/GLIMMER-PROVENANCE.json`。
- 接入说明：`Vendor/OpenWallpaperEngine/BACKEND-INTEGRATION.md`。
- ShaderToolchain、ufbx、Sparkle 等嵌套组件的原始许可及声明保留在对应目录。

主程序通过 IPC 与独立 helper 通信，不直接链接该 framework。App 包含 GPL 后端及其第三方依赖；`scripts/embed-scene-backend.sh` 将对应许可、来源记录和包含修改的源码归档放入 `Contents/Resources/SceneBackend*`。打包和分发时应一并保留这些文件。

## SceneScript 语法与模块分析

| 组件 | 固定版本 | 许可 | 源码及许可位置 |
| --- | --- | --- | --- |
| Acorn | 8.15.0 | MIT | `Workers/SceneScript/ThirdParty/Acorn/` |
| eslint-scope | 8.4.0 | BSD-2-Clause | `Workers/SceneScript/ThirdParty/ModuleScope/eslint-scope/` |
| esrecurse | 4.3.0 | BSD-2-Clause | `Workers/SceneScript/ThirdParty/ModuleScope/esrecurse/` |
| estraverse | 5.3.0 | BSD-2-Clause | `Workers/SceneScript/ThirdParty/ModuleScope/estraverse/` |

来源与包完整性记录保存在这些目录中。运行时使用系统 JavaScriptCore，不需要 Node.js 或 npm。许可随 App 放入 `Contents/Resources/Acorn-LICENSE.txt` 和 `ModuleScope-<组件名>-LICENSE.txt`。

## Steam 内容下载 helper

独立 ARM64 .NET helper 使用 SteamKit2 **3.4.0**（LGPL-2.1-only），保持为相邻、可替换的 DLL，不进行 trimming、NativeAOT 或 single-file 合并。

- 源码版本：`SteamRE/SteamKit` 提交 `1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7`。
- 原始许可及随附声明：`Workers/SteamContent/SteamKit2-LICENSE.txt`、`SteamKit2-THIRD-PARTY.txt`。
- 对应源码下载与 SHA-256：`Workers/SteamContent/source-pin.json`；运行 `scripts/prepare-dependencies.sh` 准备归档。
- .NET runtime、protobuf-net/Core、System.IO.Hashing 和 ZstdSharp 的许可、原始声明与来源记录：`Workers/SteamContent/Notices/`。
- 依赖版本及内容哈希：`Workers/SteamContent/packages.lock.json`。

`scripts/embed-steam-content-helper.sh` 将相应源码归档、依赖锁和声明放入 `Contents/Resources/SteamContent/`，运行时 DLL 位于 `Contents/Resources/SteamContentRuntime/`。替换 DLL 后需要重新签名开发 App。没有包含 DepotDownloader 实现。

## Scene 容器格式参考

Scene package 读取器参考 RePKG（MIT）的格式信息。完整声明保存在 `Sources/Glimmer/SceneWallpaper/ThirdParty/RePKG-LICENSE.txt`，并随 App 分发为 `Contents/Resources/RePKG-LICENSE.txt`。

其他阅读参考包括 macos-wallpaperengine、Loomscreen 及 Wallpaper Engine 官方文档；这些阅读参考不替代上方实际包含组件的许可声明。

## 系统框架与素材

SwiftUI、AppKit、AVFoundation、CoreGraphics、ImageIO、CryptoKit、JavaScriptCore 等由 macOS 提供。App 图标由 `scripts/make-icon.sh` 使用系统工具生成。

`Tests/Fixtures/` 中的几何图像和项目为本项目自制测试素材，具体许可见各 fixture 的说明。`Vendor/` 中的上游资源保留上游声明。Wallpaper Engine 官方私有运行资源、Steam 创意工坊用户作品及用户字体不随本仓库分发。
