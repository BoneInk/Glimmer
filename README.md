<p align="center">
  <img src="Resources/Glimmer.png" width="128" height="128" alt="Glimmer 图标">
</p>

<h1 align="center">Glimmer</h1>

<p align="center">一款Mac的端动态壁纸软件，采用了苹果的Liquid Glass设计语言，整体设计追求沉浸感和简约风。</p>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>


## 特点


- 接入Wallpaper Engine 创意工坊源，支持大部分Wallpaper Engine的原版功能，更多功能开发适配中。
- 兼容不同类型动态壁纸：
    - 视频类型：完美适配
    - web类型高度适配
    - scene类型初步适配
    - 更多功能适配中
- 支持mac端原生动态锁屏。
- 支持本地导入动态壁纸。
- 令人舒适的过渡动画。
- 更多适配源/功能开发中。

## 安装

需要 **Apple Silicon Mac（M 系列芯片）和 macOS 26 或更高版本**。当前构建目标为 `arm64`，暂不提供 Intel 版本。

1. 在本仓库的 [Releases](https://github.com/BoneInk/Glimmer/releases) 页面下载 `Glimmer-<版本>-arm64.dmg`。
2. 打开 DMG，将 `Glimmer.app` 拖入「Applications」。
3. 从「应用程序」启动 Glimmer。

当前开发预览包使用 **Apple Development 签名，尚未经过 Apple 公证**，首次在其他 Mac 上打开可能受到系统拦截。具体签名状态以对应 Release 的说明及随附 `manifest.json` 为准。

### 从 GlassWallpaper 升级

旧版与 Glimmer 使用不同的 bundle ID，可同时安装。首次打开 Glimmer 前，请先完全退出仍在运行的旧版 GlassWallpaper。只有旧数据目录存在且新目标目录尚未创建、确实需要迁移时，Glimmer 才会只读检查旧版是否仍在运行；若仍在运行会提示退出，但不会自动关闭旧版，也不会在迁移前读取旧版钥匙串。目标已初始化后可正常启动，即使作为备份保留的旧目录仍然存在。

迁移不会复制登录项；新的 Glimmer 应用身份需要在系统设置中重新开启登录项。旧钥匙串项目只做一次 best-effort 读取且不会删除；若 macOS 拒绝旧版 ACL 访问，请重新登录 Steam，旧项目会继续保留。系统当前选择的锁屏 provider 不会自动改写；如仍指向旧扩展，需在系统设置中重新选择。

## 快速上手

### 使用本地素材

1. 打开素材库，点击右上方的「＋」导入菜单。
2. 选择「视频文件或文件夹…」「Web 壁纸项目…」或「Scene 壁纸项目…」。
3. 导入后打开壁纸详情，预览画面，选择目标显示器，点击「设为壁纸」。

Web 和 Scene 壁纸需要选择包含 `project.json` 及相关资源的完整项目文件夹。已有 Steam 素材可通过「从 Steam 本地库导入…」选择。

### 使用创意工坊

使用Wallpaper Engine创意工坊前需在本应用内登录steam账号，且确保steam账号内已拥有Wallpaper Engine。本应用内下载收藏记录不会同步到云端，仅本地有效。

## 壁纸兼容性

| 类型 | 当前支持 | 说明 |
| --- | --- | --- |
| 视频 | 本地导入、循环播放、多显示器、静音与音量 | 实际解码能力取决于 AVFoundation，导入时会检查是否可播放；视频保持源文件帧率 |
| Web | 完整项目导入、桌面播放、作者设置 | 兼容性取决于项目使用的 Web 能力；FPS 设置依赖作者协作接口 |
| Scene | 原始项目及 `scene.pkg`、图片、文字、粒子、脚本、着色器、内嵌视频 | 使用社区 Metal 后端，具体能力与限制见[兼容矩阵](docs/scene-backend-compatibility-matrix.md) |

Scene 背景音乐已接入，默认静音。3D 模型与骨骼、灯光与相机对象尚未完成接入审计；系统音频频谱响应、鼠标左键交互和部分作者属性仍未接入。不能保证所有 Wallpaper Engine 作品都能播放，或与 Windows 版呈现完全一致。

遇到资源缺失、功能不支持或运行失败时，应用会显示相应诊断，方便判断具体原因。

### 实验性锁屏

项目包含系统壁纸扩展与锁屏接入流程。Scene / Web 默认使用**实时渲染**，时间、日期及脚本继续更新；在「设置 → 锁屏导出」可切换为录制视频。锁屏网页默认禁止联网，可按需开启 HTTPS 访问，用于壁纸自身提供的天气等组件；服务地址、城市和密钥由作者设置决定，仍受服务权限与网页跨域规则限制。不可用的 Scene / Web 功能仍遵守原有引擎兼容边界。锁屏不可见或休眠时暂停，Web 页面释放并保留最后一帧，恢复时重新加载当前时间。修改锁屏或作者设置后需重新设为锁屏。

选择录制视频时，Web / Scene 壁纸可录制为 **10 秒的无音轨视频**。在「设置 → 锁屏导出」中可选择原始、720p、1080p、1440p 或 4K 分辨率及导出帧率，也可开启「同步壁纸设置」跟随桌面渲染尺寸和帧率。导出保持画面比例，分辨率与帧率均不超过源规格；视频以实际轨道规格为准，Scene 以项目画布为准，Web 未声明尺寸时使用显示器渲染尺寸，Web / Scene 的帧率以当前壁纸帧率上限为准。结果根据素材、作者设置、实际导出规格和引擎版本缓存；修改设置在下次导出时生效；新视频校验通过后会原子覆盖该素材的旧视频及预览图，并清理旧规格缓存，导出失败则保留旧文件。

这部分依赖未公开的 macOS 系统接口，仍在验证中。视频导出成功不等于系统锁屏显示已经验证，也不代表支持开机或 FileVault 登录界面的动态壁纸。实现与验证范围见[扩展说明](Extensions/GlimmerWallpaperExtension/README.md)。

## 从源码构建

需要 Apple Silicon Mac、macOS 26+、完整 Xcode（包含 macOS 26+ SDK）和 Python 3。

完整 Scene 后端还需要钥匙串中已有的有效代码签名身份，不支持 ad-hoc 签名。脚本会自动选择唯一的 Apple Development 身份；存在多个身份时，通过 `GW_SIGNING_IDENTITY` 指定。

在项目根目录执行：

```bash
# 准备项目私有 .NET SDK 和固定版本 SteamKit2 源码
./scripts/prepare-dependencies.sh

# 可选：检查主程序 Swift 类型与严格并发
./scripts/build-app.sh --typecheck

# 构建完整应用，输出到 build/Glimmer.app
./scripts/build-app.sh

# 打包开发预览版 DMG，输出到 dist/
./scripts/package-release.sh

# 校验打包产物
./scripts/package-release.sh --verify dist/Glimmer-0.16.0-arm64.dmg
```

依赖准备写入项目内的 `.tools/`，校验固定版本与归档哈希。根目录 `Package.swift` 用于 IDE 索引和辅助开发；完整 App 请使用上述脚本构建。

环境变量、模块测试与目录说明见[开发说明](docs/development.md)。Developer ID 签名、Apple 公证及发布包校验见[分发与打包说明](DISTRIBUTION.md)。

## 数据与问题反馈

素材库和设置保存在本机。Steam 可恢复会话凭据保存在 macOS 钥匙串中，应用不保存 Steam 密码。用户壁纸、账号数据、缓存和签名证书不随源码发布。

反馈问题时，请附上 macOS 版本、芯片型号、Glimmer 版本、壁纸类型、复现步骤和界面错误信息。创意工坊作品可提供公开链接或作品 ID；请勿附上密码、验证码或会话令牌。

## 致谢与许可

Glimmer 的 Scene 后端基于社区项目 **OpenWallpaperEngine**，Steam 内容下载使用 **SteamKit2**，系统壁纸扩展参考了 **Phosphene** 的接口实现。感谢这些项目及相关依赖的作者。

本项目原创源码采用 [MIT 许可](LICENSE)。第三方组件保留各自许可，包括 Scene 后端的 GPL-3.0 和 SteamKit2 的 LGPL-2.1；根目录 MIT 许可不覆盖这些组件。完整来源、版本及许可说明见 [NOTICE.md](NOTICE.md)，打包脚本会随 App 附带相应声明与源码归档。
