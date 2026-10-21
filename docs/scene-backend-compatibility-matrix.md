# Scene 通用后端兼容矩阵（2026-10-20 修复批次）

本矩阵盘点“上游已支持、Glimmer 接入层当前状态”。规则：共用引擎接入，不按作品 ID、名称或
内容哈希分支；未实际实现或未通过严格就绪审计的能力一律保持拒绝，不以封面、降级画面或静默丢弃
冒充成功；缺资源（missingResources）与未接入能力（unsupportedCapability）分开报告。

| 类别 | 上游能力 | 接入状态 | 严格就绪审计 | 失败行为 |
| --- | --- | --- | --- | --- |
| 图片/文字/形状/精灵/木偶图层 | 有 | 已接入 | layer plan、原图材质、效果链、字体精确解析、稳定帧 fallback 基线 | `missing.resource` / `unsupported.*`，拒绝 ACK |
| 粒子 | 有 | 已接入 | 粒子计划、GPU 模拟状态、材质管线、内建 fallback 检测 | `unsupported.particle_*` |
| 3D 模型/骨骼 | 有运行时代码 | **未完成审计，仍拒绝** | 尚无逐 mesh/material/rig 就绪证据 | `unsupported.model_readiness_audit` |
| 声音（背景音乐） | 有（SceneSoundLayers/SceneSoundMixer） | **本次接通**：原包 VFS 解码、有界 LRU 缓存（512 MB，上游实现）、播放层准备；默认静音；用户意图经 `DisplayPlaybackSettings`（默认 `isMuted = true`）、预览、桌面统一链路；暂停/恢复/关闭释放；预加载与导出不主动出声；仅在用户开启后创建 output-only 设备（不请求麦克风） | 以 `WESceneSound` 同一数据形式提取对象顶层 `sound`（string 或 [string]）；每个声音对象的每个原始文件必须经 VFS 解码成功、通道/时长有效、`SceneSoundLayers` 播放层文件集与 `durations` 计数一致；`auditedSoundObjectIDs` 输出正向证据 | 仅当文件在原始 package/VFS 中真正不存在 → `missing.audio_file` + `missingResources`；存在但未能加载/解码/准备、或播放层缺失 → `runtime.audio_resource_unavailable` / `runtime.audio_decode_failed` / `runtime.audio_prepare_failed` / `runtime.audio_playback_missing` → `runtimeFailure`，不报 missing、不触发下载；`sound` 为空/非法声明 → `unsupported.sound_plan`（不伪造缺失路径、不报下载可修复） |
| 灯光/相机对象 | 有 | **未接入审计，仍拒绝** | 无 | `unsupported.nonplanar_readiness_audit` |
| SceneScript | 有 | 已接入 | 站点启动、watchdog 停止、控制台错误、`applyUserProperties` 回调 | `unsupported.script_*` |
| 作者属性 | 有 | **本次修复**：prepare 时以显式用户值（explicit 标志 + 内存属性 store）参与 binding table 与脚本初始值；热更新同时通知脚本、推进 live binding revision、对结构绑定重建内容并重跑严格就绪审计，ACK 前校验 helper 报告的真实 `propertyRevision` | 重建后完整 readiness；无假 ACK | 无效/不支持类型 → `unsupportedCapability`；缺资源 → `missingResources` |
| 内嵌视频纹理 | 有 | 已接入 | 原始 muted 解码帧、原视频运行时存在性 | `missing.video_frame` / `missing.required_video_runtime` |
| Bloom/HDR | 有 | 已接入（要求原链） | `original_bloom` 审计 | `unsupported.original_bloom` |
| 系统音频捕获/频谱响应 | 有（应用内） | **未接入**：helper 频谱恒为静音；不宣称支持，不代替用户授权录音 | 无 | 不涉及（能力未宣称） |
| 鼠标左键交互 | 有 | **未接入** | 无 | `unsupported` |
| SceneTexture / userShortcut 作者属性 | 有 | **未接入** | 无 | `unsupportedCapability` |
| 声明式 Workshop 依赖自动安装 | 有（应用侧 Steam 会话） | **未实现自动安装**；现有入口仅在已验证公共 assets 登记缺失时经授权 Steam 下载一次并校验登记，失败保留且不循环；不按缺失文件名任意联网 | 公共 assets manifest 校验 | 下载/校验失败原样保留 |
| 锁屏/导出 | 本次接入 | 独立通用 XPC 手动帧会话 → 10 秒、30 FPS、1920×1080 H.264 无音轨视频；共用 Web/Scene 缓存状态机，包含原作、作者参数、实际引擎与资产身份 | 真实编码、多帧变化、时钟推进、方向、缓存/取消/租约验证；未实机提交锁屏 | 缺能力/黑帧/编码失败不发布缓存 |

## 本次修复的共同根因

1. 作者属性：helper 只写 UserDefaults 与内存 store，没有 explicit 标志，`SceneContentLoader` 在
   load 时会重新推导 project.json 默认值，保存值从未进入 binding table / 脚本；热更新也未调用
   `SceneMetalRenderer.userPropertiesDidChange`、未重建结构绑定，仅返回 ACK。
2. 声音：`SceneBackendFacade` 对任何 `built.sounds` 非空的项目直接 `unsupported`；音频链路虽然上游
   完整，但从未接到通用后端，也没有默认静音/用户意图/暂停恢复的传递。
3. 错误：helper 只回传 `scene_backend_<code>`，UI 无法区分缺资源、未接入能力、着色器或脚本失败。

修复均在共享接入层（facade、严格就绪审计、DTO、helper 线协议、应用运行时/设置链路）完成，没有
按作品 ID、名称或哈希的分支。

## 声音 authored 提取与实际验收

- 根因：`GlimmerStrictReadiness.authoredSoundFiles` 曾把顶层 `sound` 当成嵌套 `sound` 字典，
  与上游 `Scene/Format/SceneSound.swift` 的 `WESceneSound` 解码形式不一致；原包 object19 是顶层
  `sound` 路径数组（播放选项也在对象顶层），已正确解码的声音因此被误报为空文件列表。
- 修复：统一读取对象顶层 `sound` 的 string / [string] 两种形式；文件比对、通道、时长、播放层与
  `durations` 计数仍走严格审计；真正缺失与"存在但未解码"继续分开报告，空列表不伪造缺失路径、
  不报下载可修复。
- 韩立实际原包已通过正式 build 34 的 XPC/GPU 审计：`evidence/iteration-047-build34-hanli/report.json`；背景音乐对象 19 已解码准备，默认静音。
- 栖川渡原包逐项 GPU 像素验证：`evidence/iteration-047-hanli/property-pixels-individual/individual-properties.json`。天光、微光与眨眼均改变画面；三个粒子选项没有被原作源引用，未编造额外效果。
- 暂停属性更新会刷新一次真实 GPU 帧且不推进时钟。helper 没有 upstream render RunLoop，因此暂停/静音时在 owner queue 上直接将声音 fade 收敛到零，避免无帧时等待不会运行的 timer。
