# Glimmer 分发与打包说明

本文档说明如何把 Glimmer 打包成可分发的 DMG、如何校验产物，
以及 **Apple Development／ad-hoc 测试构建** 与 **Developer ID + 公证的正式发行** 之间的区别与切换方式。

相关脚本（本仓库，均使用系统自带 `bash`/`hdiutil`/`codesign`/`xcrun`）：

| 脚本 | 职责 |
| --- | --- |
| `scripts/build-app.sh` | 编译全部模块、生成 `.app`、拷贝资源；完整 Scene 构建需要有效证书签名身份 |
| `scripts/make-dmg.sh` | 生成压缩 DMG、Applications 符号链接、SHA-256 与 manifest；默认保留源 App 的有效签名，可显式选择 Developer ID 重签与公证 |
| `scripts/package-release.sh` | 打包入口：可先构建再打包；`--verify` 校验已有 DMG |

`scripts/build-app.sh --dmg` 会在构建完成后自动调用 `scripts/make-dmg.sh`（无参数，使用默认路径）。

本文描述当前脚本行为；不代表已安装应用已经切换为稳定签名。实际安装版本与签名以相应安装记录及产物 manifest 为准。

从新拉取的源码开始时，先运行 `scripts/prepare-dependencies.sh`，准备项目私有 SDK 和打包所需的 SteamKit2 对应源码。完整 App 的 Scene 后端需要完整 Xcode 及有效证书签名身份，不支持 ad-hoc；共享签名函数的 ad-hoc 回退仅适用于允许该模式的独立组件。环境要求见 [开发说明](docs/development.md)。

---

## 1. 快速开始（本机测试 DMG）

```bash
# 方式 A：一次完成编译 + 打包（推荐）
scripts/build-app.sh --dmg

# 方式 B：先打包入口（缺 .app 时加 --build 先构建）
scripts/package-release.sh --build

# 方式 C：已有 build/Glimmer.app 时只打包
scripts/package-release.sh
```

产物默认输出到仓库 `dist/`：

```
Glimmer-<版本>-<架构>.dmg              压缩磁盘映像（拖入 Applications 即安装）
Glimmer-<版本>-<架构>.dmg.sha256       SHA-256 校验文件（shasum 格式）
Glimmer-<版本>-<架构>.manifest.json    版本 / 架构 / 签名状态 / 校验清单
```

例如 `Glimmer-0.16.0-arm64.dmg`。文件名与 manifest 中的版本取自
`Info.plist` 的 `CFBundleShortVersionString`，架构取自可执行文件的 `lipo -archs`
（`arm64` / `x86_64` / `universal`）。

### 校验产物

```bash
# SHA-256
(cd dist && shasum -a 256 -c Glimmer-0.16.0-arm64.dmg.sha256)

# 磁盘映像完整性
hdiutil verify dist/Glimmer-0.16.0-arm64.dmg

# 结构校验：app 存在、Applications 符号链接指向 /Applications、签名结构有效、SHA-256 一致
scripts/package-release.sh --verify dist/Glimmer-0.16.0-arm64.dmg
```

### 安装方式（供他人使用）

1. 双击打开 DMG；
2. 把 `Glimmer.app` 拖入打开的 `Applications` 文件夹（映像内的 Applications 符号链接）；
3. 从"应用程序"或聚焦搜索启动。

> **注意（本地测试构建）**：Apple Development 和 ad-hoc 都不是 Developer ID 公证发行。
> 未使用 Developer ID 证书、未公证的构建在其他人的 Mac 上首次打开可能被 Gatekeeper 拦截。
> 此时需右键点击
> 应用选"打开"，或在"系统设置 → 隐私与安全性"中允许。通过聊天软件/浏览器传输
> 的 DMG 还会带有 quarantine 标记，这是正常现象，不是文件损坏。
> 希望他人"双击即开"就必须完成下面第 3 节的正式签名与公证。

---

## 2. 签名模式对照

| 模式 | 触发方式 | 谁能运行 | 用途 |
| --- | --- | --- | --- |
| Apple Development 测试 | 构建时显式指定现有身份，或自动选择唯一可用的 Apple Development 身份 | 本机/受控环境 | 保持更新间应用身份稳定的本地验证 |
| ad-hoc 测试 | 允许该模式的独立组件或已有测试 App；完整 Scene 构建会拒绝 | 本机/受控环境 | 局部无证书开发验证 |
| Developer ID 签名 | `--developer-id` | 任意 Mac（首次需放行，未公证） | 分发测试 |
| Developer ID + 公证（正式发行） | `--release --notarize` | 任意 Mac，双击即开 | 公网发行 |

脚本会**如实检测并记录**最终签名状态（`manifest.json` 的 `signingMode` 字段）：

- `adhoc-test`：ad-hoc 测试构建（非正式发行）；
- `apple-development-test`：Apple Development 稳定本地测试签名，未公证（非正式发行）；
- `developer-id`：Developer ID 签名但未公证；
- `developer-id-notarized`：Developer ID 签名 + Apple 公证（正式发行）。

构建入口先采用 `GW_SIGNING_IDENTITY` 指定的现有身份名称或 SHA；未指定时，仅在存在唯一可用 Apple Development 身份时自动选择。共享函数在没有该身份时返回 ad-hoc，但完整 Scene 后端会据此停止；有多个身份时也会停止并要求明确指定。主应用及其嵌套组件沿用同一构建身份，不创建或导入证书。

默认测试打包要求输入 App 的 `codesign --verify --deep --strict` 校验通过，并保留它的有效签名，不重新签成 ad-hoc。仅设置打包的身份参数不会在默认测试模式下替换源签名；需要更换本地测试身份时，先用相应 `GW_SIGNING_IDENTITY` 重新构建。

复用同一有效证书和应用标识可保持 designated requirement 稳定，避免 ad-hoc 构建因代码变化而改变身份。两份不同代码的实际研究候选已验证 requirement 相同，见 `evidence/research/stable-identity-real-candidates.json`。该证据不是已安装版会话恢复验收；从旧 ad-hoc 版本迁移时仍可能需要用户亲自授权一次，Steam 撤销会话或用户退出后也可能需要重新登录。脚本不修改钥匙串 ACL，不取消系统授权。

### 正式发行命令示例

```bash
export GLIMMER_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
export GLIMMER_NOTARY_KEYCHAIN_PROFILE="glimmer-notary"   # 你自建的 notarytool 配置

scripts/package-release.sh --build --clean --release --notarize
```

等价的 `make-dmg.sh` 直接调用：

```bash
scripts/make-dmg.sh --release --notarize \
  --identity "Developer ID Application: 你的名字 (TEAMID)" \
  --keychain-profile glimmer-notary
```

执行顺序（**重签发生在资源拷贝完成之后**）：

1. 把完整 `.app` 拷贝进 DMG 暂存映像；
2. 默认测试模式保留源 App 的有效签名；显式 Developer ID／正式发行模式才对映像内副本执行
   `codesign --force --options runtime --timestamp`，只签副本，**绝不修改 `build/` 里的原始 `.app`**；
3. 转成压缩映像（UDZO）；
4. Developer ID／正式发行模式对 DMG 本身签名；默认测试模式不签 DMG；
5. 仅显式选择 `--notarize` 时提交公证：`xcrun notarytool submit ... --wait` → `xcrun stapler staple/validate`。

### 环境变量

| 变量 | 作用 |
| --- | --- |
| `APP_PATH` | 输入 `.app`（默认 `build/Glimmer.app`） |
| `OUTPUT_DIR` | 输出目录（默认 `dist/`） |
| `DMG_VOLUME_NAME` | 映像卷名（默认 `Glimmer <版本>`） |
| `GW_SIGNING_IDENTITY` | 构建时使用的现有身份名称或 SHA；`-` 明确选择 ad-hoc；默认测试打包仍保留源 App 有效签名 |
| `GLIMMER_SIGN_IDENTITY` | Developer ID Application 身份（等价 `--identity`） |
| `GLIMMER_NOTARY_KEYCHAIN_PROFILE` | notarytool 钥匙串配置名（等价 `--keychain-profile`） |

### 退出码

`0` 成功；`1` 运行失败；`2` 参数错误；`3` 正式发行前置条件不足（缺证书/公证配置，附中文说明）。

---

## 3. 正式发行前置条件（由你本人准备）

1. **Apple Developer Program 会员**，并在 developer.apple.com 创建
   **Developer ID Application** 证书，安装到本机钥匙串。
   检查：

   ```bash
   security find-identity -v -p codesigning
   ```

   看到 `"Developer ID Application: ..."` 即就绪。

2. **notarytool 钥匙串配置**（凭据只保存在你自己的钥匙串中；最多同时有效 2 个配置）：

   ```bash
   xcrun notarytool store-credentials "glimmer-notary" \
     --apple-id "你的 Apple ID" \
     --team-id "TEAMID" \
     --password "App 专用密码"   # 在 appleid.apple.com 生成
   ```

3. 之后运行第 2 节的正式发行命令。公证需要联网，通常数分钟。

### 脚本的安全边界（刻意设计）

- **不创建、不导入、不导出、不存储**任何证书或私钥；只读使用钥匙串中已存在的身份；
- **不伪造证书**：正式 release 模式在缺少有效证书或不满足公证条件时**失败并解释**（退出码 3）；
- **不自动上传公证**：只有调用者显式传入 `--notarize` 才会提交 Apple；
  且 `--release` 必须显式加 `--notarize`（双确认），避免误上传；
- 公证凭据通过 `notarytool` 钥匙串配置读取，**脚本不读取其内容、不落盘、不记录**；
- **不修改 `build/` 中的原始 `.app`**：重签只处理 DMG 内的副本；
- DMG 与 manifest **不嵌入开发目录绝对路径**，只包含文件名、版本、架构与哈希；
- 不安装任何系统组件、不修改全局 Steam、不触碰本机当前壁纸。

---

## 4. 构建前核对签名能力

在构建机器上检查已有身份与工具：

```bash
security find-identity -v -p codesigning
xcrun notarytool --version
```

本机历史签名数量和证书状态不能代表其他开发者的环境。完整 Scene 构建需要有效证书身份；公网发行需按第 3 节配置 Developer ID 和公证，并验证最终包。

---

## 5. 许可与第三方声明

- 本项目原创源码保留 MIT 许可，见仓库 `LICENSE`；第三方组件适用各自许可，见 `NOTICE.md`；
- Scene 后端打包会附带 GPL 后端的对应源码、来源记录与组件许可；Steam helper 打包会附带 SteamKit2 对应源码和依赖声明；
- `scripts/build-app.sh` 会把 `LICENSE`、`NOTICE.md`（以及存在时的
  `THIRD_PARTY_NOTICES.md`）复制进 `Glimmer.app/Contents/Resources/`，
  随分发包一起提供给最终用户；
- 打包脚本会在 manifest 的 `distributionWarnings` 中记录许可文件缺失（如有）；
  正式 release 模式下缺少许可文件会直接失败。

## 6. 发布前验收

```bash
# 1) 构建 + 打包
scripts/build-app.sh --clean && scripts/package-release.sh

# 2) 结构校验（期望全部 ✓）
scripts/package-release.sh --verify dist/Glimmer-0.16.0-arm64.dmg

# 3) 独立运行验证：把应用拷到开发仓库之外运行自检（不修改真实壁纸）
mkdir -p "$TMPDIR/gw-standalone" && ditto build/Glimmer.app "$TMPDIR/gw-standalone/Glimmer.app"
"$TMPDIR/gw-standalone/Glimmer.app/Contents/MacOS/Glimmer" --self-test
```
