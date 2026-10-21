# 开发说明

## 环境与依赖

- Apple Silicon、macOS 26+。
- 完整 Xcode 与 macOS 26+ SDK；Scene framework 必须使用完整 Xcode。可通过 `SCENE_BACKEND_DEVELOPER_DIR` 指向其他 Xcode 路径；主程序工具链通过 `DEVELOPER_DIR` 选择。
- Python 3，以及系统 `bash`、`zsh`、`clang`、`codesign`、`hdiutil`。
- 完整 App 需要有效的证书签名身份。默认使用钥匙串中唯一的 Apple Development 身份；多个身份时通过 `GW_SIGNING_IDENTITY` 指定名称或 SHA。Scene 后端拒绝 ad-hoc 构建。
- 项目私有 .NET SDK **10.0.402**，版本和 SHA-512 见 `Workers/SteamContent/sdk-pin.json`。

从全新源码目录开始，先执行：

```bash
./scripts/prepare-dependencies.sh
./scripts/prepare-dependencies.sh --verify
```

准备脚本下载并校验 .NET SDK 和 SteamKit2 固定提交的源码归档，写入 `.tools/`。已有文件校验失败时停止，不静默覆盖。Steam helper 的首次构建通过 `NuGet.Config` 从 nuget.org 恢复依赖，使用 `packages.lock.json` 与 `--locked-mode` 固定版本和哈希。

Scene 后端及其本地依赖快照已经放在 `Vendor/OpenWallpaperEngine/`，不是 Git 子模块。请保留该目录的源码、资源、Sparkle 二进制依赖和全部许可；新增 `.gitignore` 规则时不要一概忽略 `*.app` 或所有二进制，否则可能漏掉 Sparkle framework 内嵌的工具。

## 构建与输出

```bash
./scripts/build-app.sh --typecheck
./scripts/build-app.sh
```

`--typecheck` 检查主程序与共享协议，不编译 Scene framework、.NET helper 或实验扩展；完整打包需要第二条命令。脚本不负责安装 App 或切换桌面壁纸。

| 变量 | 用途 |
| --- | --- |
| `CONFIG=debug` | 主程序使用调试编译选项，默认 `release` |
| `GW_SIGNING_IDENTITY` | 指定本机已有签名身份 |
| `GW_OUT_DIR` | 主 App 与部分辅助产物输出目录，默认 `build/`；Steam helper 和 Scene 后端仍有独立输出目录 |
| `SCENE_BACKEND_BUILD_DIR` | 单独构建后端时的输出目录；完整 App 默认使用 `build/SceneBackend/` |
| `SCENE_BACKEND_DEVELOPER_DIR` | 后端使用的完整 Xcode 路径 |

根目录 `Package.swift` 是 IDE 索引/辅助入口。完整 App 由构建脚本收集全部源码，定义 `GW_UNIVERSAL_SCENE_BACKEND`，编译并嵌入 XPC、运行时、扩展和第三方声明。

## 品牌与图标

应用名和可执行文件名为 `Glimmer`，默认产物为 `build/Glimmer.app`。图标的唯一矢量源为 `Resources/Glimmer.svg`：深蓝背景与九颗隐约勾出 G 字的萤火虫微光；菜单栏的单色点阵沿用同一构图。运行 `scripts/make-icon.sh` 可用 macOS 原生 SVG 渲染重新生成 `Resources/Glimmer.png` 和全尺寸 `Resources/AppIcon.icns`；主构建在矢量源或生成脚本更新后自动重新生成图标。

为兼容既有安装，源码目录 `Sources/Glimmer`、主程序/扩展/XPC 的 bundle identifier、钥匙串 service、配置格式标识、偏好设置键和 `Application Support/Glimmer` 数据目录保持稳定。品牌更名不需要搬迁素材库或重新登录 Steam。根目录 LICENSE 保留原有版权归属。

## 验证入口

测试按模块放在 `Tests/`，由 `scripts/test-*.sh` 单独编译运行。不存在统一的 `swift test` 验收入口。按修改范围选择对应脚本，例如：

```bash
# 本地、隔离测试，不需要真实 Steam 账号
./scripts/test-scene-runtime-asset-registry.sh
./scripts/test-scene-preview-preload.sh

# Steam helper 的受控会话测试
./scripts/test-steam-content-session.sh
```

GUI、Metal、实验扩展、真实素材或账号测试另有环境前提，先阅读脚本及其对应说明，不要一次执行所有测试。`evidence/` 是本地生成的输出与历史记录，不随 Git 分发；文档中对该目录的引用仅表示本机历史证据，不代表新机器已完成验收。

几个独立 GUI probe 通过参数或环境变量接收私有素材，不使用作者本机路径：

| Probe / 测试 | 输入 |
| --- | --- |
| `WallpaperActualMediaTransitionProbe` | `<输出目录> <视频路径> <封面路径>` |
| `WallpaperFullDetailsPreviewProbe` | `<输出目录> <library.json 路径> <素材 UUID> [更多 UUID…]`，只读指定库 |
| `WallpaperPreviewReadinessTests` | `<测试视频路径>` |
| `WallpaperCoverContinuousTests`、`WallpaperFullCanvasLayoutTests` | `GW_TEST_OUTPUT` 指定输出目录；未指定时写系统临时目录 |

## Git 与本地工作文件

提交源码、测试、脚本、依赖锁、第三方来源和许可；以下文件保留在本机并由 `.gitignore` 排除：

- `.tools/`、`.build/`、`build/`、`build-*/`、`dist/`、.NET `bin/` 与 `obj/`。
- `evidence/` 中的研究副本、截图、日志、测试导出和历史 README。
- `delivery-status.json`、早期任务规划 JSON、本地任务路由脚本。
- 本地环境变量文件、签名证书、Xcode 用户状态和编辑器缓存。

上传前可用 `git status --short`、`git diff --cached --stat` 检查实际提交内容。发布包放在 Release 资产中；不要强制加入构建目录、私有素材、Steam 会话或证书。

Vendor 快照保留了上游约 52.5 MiB 的 `WallpaperNotFound.mp4`，因此源码仓库包含较大的媒体文件；这是上游资源，不是用户壁纸或本机构建产物。更换或裁剪 Vendor 需要同步检查资源引用、打包和来源记录。

## 引擎与分发

引擎修改遵循[统一接入规则](scene-engine-integration.md)，支持边界见[兼容矩阵](scene-backend-compatibility-matrix.md)。原始 Wallpaper Engine 资产由使用者正常登录 Steam 后获取，不从本机缓存复制进仓库。

开发签名、Developer ID、公证及 DMG 验证见 [DISTRIBUTION.md](../DISTRIBUTION.md)。实验性系统壁纸扩展的生命周期和数据约定见 [扩展说明](../Extensions/GlimmerWallpaperExtension/README.md)。
