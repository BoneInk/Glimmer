Open Wallpaper Engine
=========

[English](../../README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Italiano](README.it.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **简体中文** | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../../LICENSE)

Open Wallpaper Engine 是一款免费、开源的 macOS App，可播放和编辑 Wallpaper Engine 的场景、视频和网页墙纸。场景使用原生 Metal 渲染器绘制，支持特效、粒子、3D 模型、光照、SceneScript 和音频响应视觉效果，并内置 Steam 创意工坊。本项目最初是 Haren Chen 与 MrWindDog 的 [Open Wallpaper Engine](https://github.com/MrWindDog) 的分支，此后已大部分重写。

> **注：** 本项目与 Steam 上的商业软件 Wallpaper Engine 没有任何关联。这是一款开源的 macOS App，可显示来自 Wallpaper Engine Steam 创意工坊的墙纸素材。 → [ATTRIBUTION.txt](../../ATTRIBUTION.txt)

**网站：** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki：** [指南与疑难解答](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](../../docs/media/demo/hero.webp)](../../docs/media/demo/hero.webm)

[![Scene wallpapers running live](../../docs/media/demo/wallpapers-in-motion.webp)](../../docs/media/demo/wallpapers-in-motion.webm)

![资源库](../../docs/images/library.jpg)

## 与众不同之处

- **唯一能编辑 Wallpaper Engine 场景的 macOS App。** 墙纸编辑器可打开场景的图层、效果、粒子、时间线和脚本，并将其保存为 Wallpaper Engine 墙纸。
- **实况照片与 Android 版 Wallpaper Engine 导出。** 任何场景或视频都可以变成 iPhone 和 iPad 的动态锁定屏幕，或 Android 版 Wallpaper Engine 的墙纸包。
- **翻译 Wallpaper Engine 自己的着色器。** 每个图层、效果和材质都通过墙纸的原始着色器绘制，这些着色器被翻译为 Metal，包括创意工坊作者自己编写的效果。
- **完全实时的屏幕保护程序。** 屏幕保护程序在运行时绘制每台显示器的墙纸，因此时钟、脚本和音频响应部分会持续运动。不录制任何内容。

## 亮点

- **场景、视频和网页墙纸**：场景支持特效、粒子、3D 模型、光源、时间线、SceneScript 和音频响应视觉效果，并在能够显示 HDR 的显示器上为场景以及 HDR10 或 HLG 视频提供 HDR 输出。网页墙纸在 WebKit 或可选的 Chromium 引擎中运行，支持其文件夹属性、实时音频和 Now Playing。
- **Steam 创意工坊**：使用 Wallpaper Engine 的排序和筛选方式浏览，用你自己的 Steam 账户通过 SteamCMD 下载，或导入墙纸文件夹和 zip 文件。“已安装”标签页提供 Wallpaper Engine 的文件夹和排序方式。
- **墙纸编辑器**：一款秉承 Wallpaper Engine 编辑器理念的编辑器。使用操纵器添加和排列图层，添加带预览的效果，在着色器编辑器中编写和编辑你自己的效果，导入 FBX 和 OBJ 模型，在时间线上制作动画，编写 SceneScript，创建用户属性，编辑粒子系统和 Puppet Warp 骨架，并使用 Wallpaper Engine 的图像工具（前景分离、角色属性表创建、法线贴图生成）。**新墙纸…** 可从一张图片或 Wallpaper Engine 的某个模板开始创建墙纸。你编辑的是一份草稿：**保存** 会应用它，**保存为新墙纸** 会在资源库中添加一份副本，墙纸本身的文件绝不会被更改。

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](../../docs/media/demo/wallpaper-editor.webp)](../../docs/media/demo/wallpaper-editor.webm)

  ![墙纸编辑器](../../docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **场景编辑/导出**：直接在桌面上实时修改正在运行的墙纸的图层和效果，选择屏幕保护程序显示的内容，或将墙纸导出为实况照片或 Android 墙纸包。

  [![Scene Edit / Export: versions and layers changed live on the desktop](../../docs/media/demo/scene-edit.webp)](../../docs/media/demo/scene-edit.webm)

  ![场景编辑/导出](../../docs/images/scene-editor-live.jpg)

- **屏幕保护程序与锁定屏幕**：屏幕保护程序实时显示每台显示器的墙纸（*屏幕保护程序与壁纸相同*），或显示你选择的墙纸；锁定屏幕显示它的一张图片。

  <!-- demo: screen-saver -->

- **导出**：iPhone 和 iPad 的实况照片锁定屏幕，可通过 AirDrop 发送或存储到“照片”；以及 Android 版 Wallpaper Engine 的墙纸包，可通过二维码经 Wi-Fi 发送到设备。

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](../../docs/media/demo/live-photo-export.webp)](../../docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](../../docs/media/demo/android-export.webp)](../../docs/media/demo/android-export.webm)

  ![通过 Wi-Fi 发送](../../docs/images/send-over-wifi.png)

- **显示器**：与 Wallpaper Engine 一样：每台显示器一张墙纸、一张墙纸横跨所有显示器或在每台显示器上克隆，并支持分组、分割和配置文件。**在窗口中播放** 可在单独的窗口中播放墙纸。

  ![显示器](../../docs/images/displays.png)

- **播放列表**：按计时器、登录时、一天中的时段或星期几更换墙纸，并使用 Wallpaper Engine 的过渡效果。

  ![播放列表设置](../../docs/images/playlists.png)

- **控制**：用于操作、播放列表、墙纸和显示器配置文件的热键；Wallpaper Engine 的 `-control` [命令行](../../docs/command-line.md)；以及 **MCP 服务器** 插件，MCP 客户端可通过它设定墙纸、播放列表和设置并编辑场景，连接仅限本地，且只有你的账户可以打开。

  ![MCP 服务器插件](../../docs/images/mcp-plugin.png)

- **电源**：屏幕锁定时墙纸会暂停，遵循 Wallpaper Engine 的 *笔记本电脑使用电池时* 规则，并可在使用电池或处于低电量模式时降至较低的画质预设和帧速率。
- **主题颜色**：菜单栏、强调色以及着色的图标和文件夹会跟随墙纸的颜色变化；Open Wallpaper Engine 自己的窗口可以使用墙纸的准确颜色。

  ![主题颜色](../../docs/images/theming.png)

其他所有功能（按领域分类）：[docs/features.md](../../docs/features.md)。

## 安装

1. 从 [openwallpaperengine.app](https://openwallpaperengine.app/) 或 [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases) 下载最新版本。它经过签名和公证，并会自动更新。
2. 打开 DMG，将 **Open Wallpaper Engine** 拖到“应用程序”文件夹。

需要 **macOS 14.0（Sonoma）或更高版本**。场景墙纸需要来自你在 Steam 上自己的 Wallpaper Engine 副本的 Wallpaper Engine 素材；视频和网页墙纸则不需要。部分功能需要更新的 macOS、某项权限或某个插件：请参阅[入门指南](../../docs/getting-started.md#requirements)。

## 快速入门

1. 打开 App。设置助理会设置语言、SteamCMD、你的 Steam 登录和 Wallpaper Engine 素材，还可以导入你的 Wallpaper Engine 个人收藏和文件夹；每一步都可以跳过。
2. 如果想使用场景墙纸，请安装 Wallpaper Engine 素材（*设置 › 资源*）。这些素材来自你在 Steam 上自己的 Wallpaper Engine 副本；视频和网页墙纸无需它们即可使用。
3. 在 **发现** 和 **创意工坊** 标签页中查找墙纸，导入墙纸文件夹或 zip 文件（*文件 › 从文件夹导入墙纸…*，⌘I），或使用 **添加墙纸 › 新墙纸…** 制作一张。
4. 在资源库中点按一张墙纸，然后在其详细信息中点按 **设定墙纸**（或者右键点按它并选择 **设为墙纸**）。它的属性列在下方。

更多内容：[入门指南](../../docs/getting-started.md)和 [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)。

## 隐私

App 保存的所有内容都留在你的 Mac 上，它不收集任何数据或分析信息。它会连接 Steam（用于创意工坊和素材）、openwallpaperengine.app（用于检查更新）和 GitHub（用于下载更新），插件只会在你安装时下载。详情：[App 会连接哪些服务](../../docs/getting-started.md#what-the-app-connects-to)以及[隐私政策](../../docs/legal/privacy-policy.md)。

## 文档

- [入门指南](../../docs/getting-started.md) — 系统要求、素材、创意工坊和导入
- [功能](../../docs/features.md) — App 支持的所有功能及其使用方法
- 指南：[显示器布局](../../docs/display-layouts.md) · [播放列表](../../docs/playlists.md) · [屏幕保护程序](../../docs/screen-saver.md) · [iPhone 与 iPad 导出](../../docs/iphone-ipad-export.md) · [Android 导出](../../docs/android-export.md) · [深度图](../../docs/depth-maps.md) · [主题](../../docs/theming.md) · [模型导入](../../docs/model-import.md) · [图像工具](../../docs/image-tools.md) · [MCP 服务器](../../docs/mcp.md) · [命令行](../../docs/command-line.md) · [Chromium 网页引擎](../../docs/chromium-engine.md)
- [开发](../../docs/development.md) — 从源代码构建和项目结构；另见 [CONTRIBUTING.md](../../CONTRIBUTING.md) 和[架构](../../docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — 指南、设置参考和疑难解答

## 相关项目

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — 适用于 [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) 的 PyQt6 图形界面，其 Steam 创意工坊集成与 UI 设计移植自本 macOS 版本。

## 致谢

本项目建立在以下贡献者的工作之上：

- **[MrWindDog](https://github.com/MrWindDog)** — 上游 [wallpaper-engine-mac](https://github.com/MrWindDog) 分支的维护者，添加了新功能并改进了 UI
- **[Haren Chen](https://github.com/haren724)** — [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac) 的原作者，构建了 App 的核心架构（SwiftUI、视频墙纸播放、导入系统、播放列表 UI）
- **1ris_W** — 中文 i18n 翻译
- **[Klaus Zhu](https://github.com/klauszhu1105)** — 原始标志设计
- **[Chen Chia Yang](https://github.com/Unayung)** — 场景墙纸渲染、网页墙纸修复、Steam 创意工坊集成、多显示器支持、zip 导入
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Metal 场景渲染器与效果管线、GLSL→MSL 着色器转换与缓存、SceneScript 运行时、音频响应渲染、创意工坊／下载功能全面改进、摆放与性能设置、标志重新设计

与原项目相同，本项目采用 [GPL-3.0](../../LICENSE) 许可证。

## 法律信息

[使用条款](../../docs/legal/terms-of-use.md) · [隐私政策](../../docs/legal/privacy-policy.md) · [安全政策](../../SECURITY.md)

- **English:** Please read the Terms of Use and the Privacy Policy.
- **Deutsch:** Bitte lesen Sie die Nutzungsbedingungen und die Datenschutzrichtlinie.
- **Français :** Veuillez lire les conditions d’utilisation et la politique de confidentialité.
- **Español:** Lee las condiciones de uso y la política de privacidad.
- **Português (Brasil):** Leia os Termos de Uso e a Política de Privacidade.
- **Italiano:** Leggi le condizioni d’uso e l’informativa sulla privacy.
- **日本語：** 利用規約とプライバシーポリシーをお読みください。
- **한국어:** 이용 약관과 개인정보 처리방침을 읽어 주십시오.
- **简体中文：** 请阅读使用条款和隐私政策。
- **繁體中文：** 請閱讀使用條款和隱私權政策。
- **Русский:** Прочитайте условия использования и политику конфиденциальности.
- **Polski:** Przeczytaj warunki korzystania i politykę prywatności.
- **Türkçe:** Lütfen Kullanım Koşulları’nı ve Gizlilik Politikası’nı okuyun.
- **Українська:** Прочитайте умови використання та політику приватності.
- **العربية:** يُرجى قراءة شروط الاستخدام وسياسة الخصوصية.
- **हिन्दी:** कृपया उपयोग की शर्तें और गोपनीयता नीति पढ़ें।
