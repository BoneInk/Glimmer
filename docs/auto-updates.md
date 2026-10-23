# 应用内更新

Glimmer 使用 Sparkle 2.10.0。默认在启动时及每隔 24 小时检查新版本，发现更新时弹窗提醒。用户确认后，直接在应用内下载、校验、安装并重新启动，不需要打开 GitHub 网页。更新检查与安装出错时显示原因，可以稍后重试。

「设置 → 软件更新 → 新版本提醒」可以关闭后台检查与弹窗，选择会在重启后保留。关闭提醒后，设置页、应用菜单和菜单栏的「检查更新…」仍然可用。不会在用户确认前自动下载或安装更新。

## 更新来源与校验

- 配置：`Resources/UpdateConfiguration.plist`，构建时合并进 App 的 `Info.plist`。
- 清单：`https://raw.githubusercontent.com/BoneInk/Glimmer/main/appcast.xml`。
- 安装包：对应 GitHub Release 的 ZIP 资产；应用直接下载文件，不跳转网页。
- 清单和安装包都使用 Ed25519 签名。清单校验后才能展示，安装包校验后才能解压。私钥不进入 App。
- Sparkle 根据递增的 `CFBundleVersion` 比较版本，`CFBundleShortVersionString` 用于展示。每次发布必须增加构建号。
- 退出和重启沿用现有应用生命周期，等待锁屏提交与下载任务收尾，并保存素材库。应用数据位于 App 包之外，更新仅替换应用包。

仓库初始的 `appcast.xml` 是已签名的空清单，不会把没有更新功能的旧安装包误报为更新。在清单随源码推送前，线上地址可能返回 404。现有 0.17.0 及更早的已发布安装包需要手动安装一次带本功能的版本，之后才能接收应用内提醒。

## 私钥

本机首次接入时已生成 `.tools/glimmer-updates.ed25519.key`（权限 `0600`），其公钥已写入配置。该路径被 Git 忽略。请将私钥保存在发布者的安全备份中；后续发布继续使用同一私钥，不能每次重新生成。此流程不读写登录钥匙串。

换用其他构建机器时，将同一私钥放入受保护的位置，通过 `GLIMMER_UPDATE_KEY_FILE` 或 `--key` 指定。只读检查对应公钥：

```bash
xcrun swift scripts/update-signing.swift public /安全路径/glimmer-updates.ed25519.key
```

仅为全新的独立更新渠道创建密钥时，才使用下面的命令，并将输出的公钥配置到该渠道的 App 中。它会拒绝覆盖已有密钥：

```bash
umask 077
xcrun swift scripts/update-signing.swift create /安全路径/new-channel.ed25519.key
```

## 准备与发布更新

先增加 `scripts/build-app.sh` 中的版本和构建号，构建并完成既有打包检查。生成更新 ZIP 时应使用最终分发的已签名 App；若 DMG 打包阶段更换了签名或完成了公证，使用从最终 DMG 取出的 App。

```bash
# 现有构建与 DMG 流程
scripts/package-release.sh --build

# 为同一个版本另行生成应用内更新资产
scripts/package-update.sh \
  --app build/Glimmer.app \
  --out dist/update \
  --tag v0.18.0 \
  --notes /路径/release-notes.txt
```

`--tag` 应与实际 Release 一致；默认是 `v<应用版本>`。示例中的版本需改成实际构建版本。`--notes` 可省略；提供时说明会嵌入清单，在应用内显示。

脚本校验 App 签名及私钥与内置公钥是否匹配，保留框架符号链接，生成 `Glimmer-<版本>-<架构>.zip`、同名 `.sha256` 和 `appcast.xml`。官方工具的版本与 SHA-256 固定，下载后先验证再使用。脚本不会上传文件或修改仓库根目录的在线清单。

发布时的顺序：

1. 将 ZIP 与 `.sha256` 上传到对应的 GitHub Release，并确认 ZIP 下载地址可用。原有 DMG 可以继续提供给首次安装的用户。
2. 将生成的 `dist/update/appcast.xml` 原样复制到仓库根目录并发布到 `main`。此时客户端才会发现新版本。清单已签名，不能手工修改内容后直接发布。
3. 用较低构建号的隔离 App 验证提醒、确认下载和安装重启。

当前清单只包含最新完整更新包，不依赖历史增量包。预览版是否发布给用户由维护者是否将其加入清单决定，不依赖 GitHub 的 “latest release” 规则。

## 验证

```bash
scripts/test-app-updates.sh
scripts/build-app.sh --typecheck
```

集成测试使用临时 App、独立 Bundle ID、本地 HTTP 服务和临时测试密钥。生产构建只接受 HTTPS 更新地址。测试覆盖用户确认前无安装包下载、确认后的真实替换与重新启动、拒绝更新、关闭提醒后的手动检查、已是最新版本，以及签名校验失败。它不替换正在运行或已安装的 Glimmer，也不访问真实素材库、Steam 登录或锁屏设置。

Sparkle 接入与发布格式参考：[程序化接入](https://sparkle-project.org/documentation/programmatic-setup/)、[发布更新](https://sparkle-project.org/documentation/publishing/)。
