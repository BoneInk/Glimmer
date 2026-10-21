# Wallpaper Engine 能力差距与下一批功能

研究日期：2026-10-18。只读核对当前源码、`feature-plan.json`、根 README、`delivery-status.json`、Scene/Web README 和 `docs/ui-direction-20261018.md`。未构建、启动 GUI、登录 Steam 或读写真实用户数据。开发正在并行进行，下面是本次读取到的源码状态；安装检查点以 delivery-status 的 0.15.1 build 8 为准。

建议接下来投入五项真实功能：**逐作品逐屏构图、每屏命名播放列表、Scene 自选图片纹理、生产 Scene 材质合成、可保存并排除类别的发现筛选**。第一和第五项适合先落地；第二项先完成每屏基础，再接触发条件；第三、第四项各自建立可扩展接口。完成这些依旧不等于完整 WE 兼容。

## 核查依据与属性归属

所有外部链接于 2026-10-18 核对。没有标注发布日期的帮助/开发文档不能把抓取日期当作发布日期。

| 官方依据 | 可以确认的能力与边界 |
| --- | --- |
| [WE 1.4 官方公告，2020-12-15](https://store.steampowered.com/news/posts/?appgroupname=Wallpaper+Engine&appids=431960&enddate=1612800921&feed=steam_community_announcements) | 明确为 **Scene、Video** 增加自由定位/缩放，以及亮度、对比度、饱和度和色相；也记录了逐显示器静音。不能把这套图像处理或视频速度直接套到 Web。 |
| [WE 命令行官方帮助](https://help.wallpaperengine.io/en/functionality/cli.html) | 可按 monitor/location 打开壁纸、播放列表、下一张；加载多屏 profile；动态应用作品属性。具体属性以真实作品的 Share JSON 为准，示例含 `rate`。 |
| [按应用切换壁纸/列表/profile](https://help.wallpaperengine.io/en/functionality/wallpaperperapp.html) | 应用条件和多屏 profile 是实际能力；profile 是保存的多屏作品与列表快照。WE 的应用规则“加载壁纸/列表”跨屏展开，独立屏幕需 profile，不能推成任意混用语义。 |
| [2018-08-20 官方列表更新](https://store.steampowered.com/news/posts/?appgroupname=Wallpaper+Engine&appids=431960&enddate=1557178758) | 时间段模式、同一作品多次出现、单项时间和已保存列表。这里只确认已公开的能力，不推断当前完整选项集合。 |
| [排除类别官方帮助](https://help.wallpaperengine.io/en/interface/exclude.html) | 除包含筛选外，可排除 genre，有长期过滤偏好；Steam 账号内容偏好与 WE 搜索年龄标签是两层机制。 |
| [Web property listener](https://docs.wallpaperengine.io/en/web/api/propertylistener.html)、[Web FPS](https://docs.wallpaperengine.io/en/web/performance/fps.html) | 作者属性、通用 FPS、暂停、目录变化是不同回调；FPS 通知由作者配合执行，不能当作强制限帧。 |
| [Scene 用户属性](https://docs.wallpaperengine.io/en/scene/userproperties/overview.html)、[纹理属性](https://docs.wallpaperengine.io/en/scene/userproperties/texture.html) | scalar 作者选项与纹理/快捷方式不是一回事；纹理可替换图像层、mask、粒子纹理，并有默认纹理回退。 |
| [Scene 总览](https://docs.wallpaperengine.io/en/scene/overview.html)、[特效](https://docs.wallpaperengine.io/en/scene/effects/introduction.html)、[SceneScript API](https://docs.wallpaperengine.io/en/scene/scenescript/reference.html) | Scene 范围包含效果、粒子、时间线、音频响应、视差、脚本、3D 和 shader；实现几个事件不等于完整 Scene。 |

归属应在代码和界面同时保持清楚：

- **宿主通用策略**：显示器分配、用户暂停意图、睡眠/电源策略、列表调度、启动恢复。所有类型都可共享调度接口，具体暂停是否真正停止计时/音频取决于 renderer。
- **Video 内建设置**：播放速度、音量/静音、画面构图；来自 AVFoundation，不是 `project.json` 作者属性。
- **Scene 与 Video 的最终画面设置**：自由对齐/缩放及颜色调整可共享模型，但实现点不同。Scene 层级变换、camera parallax、材质、粒子等仍是 Scene 专有功能。
- **Web 作者设置**：由网页真实 `applyUserProperties`/目录回调消费；通用 FPS 是 `applyGeneralProperties`。WebAudio、系统音频响应、媒体资料桥接各需独立实现，不能展示视频滑块假装已经生效。
- **Scene 作者设置**：必须找到实际绑定到图层、纹理、shader uniform 或脚本的消费路径；属性 schema 被读到并不代表可编辑。

## 已有实现：不要重复安排

| 范围 | 当前源码可见状态 | 仍存在的真实边界 |
| --- | --- | --- |
| 视频逐作品设置 | `WallpaperItem.VideoPlaybackPreferences` 有 mute/volume/rate/gravity；rate 0.25–4，gravity 只有 fit/fill。`DesktopWallpaperController` 把有效设置写到真实 player/layer。作品 override 覆盖显示器默认；暂停不存进作品。 | 无定位、焦点、缩放、拉伸/原尺寸模式；无颜色调整。同作品的设置全屏共用，不能为横屏/竖屏各留构图或音量覆盖。 |
| 多屏视频 | 按显示器 UUID 存分配与暂停意图；可选屏/全部屏。 | 是独立会话，不能宣称时间同步、跨屏 span/clone 或任意混合 DPI 拼接。逐作品 override 还会覆盖逐屏音量，需明确优先级。 |
| 列表 | `GWPlaylistSettings` 单一 enabled/mode/interval/itemIDs/currentItemID；顺序/随机、缺失跳过、策略挂起已在。 | `AppPlaybackIntegration.applyRotationSelection` 使用 `to:nil`，每次应用全部屏幕；没有命名列表、每屏绑定、每项时长、一天时段、视频结束触发、应用条件或 profile。数组去重还使重复条目不可能。 |
| Steam 发现 | 类型 video/web/scene/all、分辨率、genre、age、趋势时期、搜索排序/分页已有。`WorkshopBrowserStore` 保存搜索历史和本机收藏。 | filters 是非 Codable 单选包含条件；浏览存档没有完整筛选/排序快照，也没有排除集合。应补实际能力，不再增加一个“类型筛选”入口。 |
| 资产作者设置 | Web scalar + file + ondemand/fetchall directory 已有 managed grants、资源 manifest 和实际 callback ACK；同作品 hosts 同步。 | Scene `texture`、usershortcut、group 并未在 `AuthorPropertyKind` 中识别；Scene 纹理是导入时固定路径，缺用户图片替换消费链。不能因为 Web file picker 已有就说 Scene 已支持。 |
| 下载类型 | resolver、Web/Scene validators 和导入分支已经存在，SteamKit 真实视频完成/续传已有生产证据。 | 真实认证 Web/Scene 完整下载导入没有接受证据属于验收边界，不宜把整条已编码路径再次列为新功能。当前队列持久化、下载即时搜索由其他工作进行，不在本报告重复分配。 |

`feature-plan.json` 顶部仍是原 v1 video 范围，不能拿它的早期 excluded_from_v1 作为当前目标的终点。Scene README 的 installed 0.12 文字也落后于根交付记录；本报告依据源码描述能力，不修改这些文件。

## 下一批五项：接口、收益与用户验收

### 1. 逐作品逐显示器构图（首选小功能）

**收益**：同一横版视频放到竖屏时用户可把人物保留在画面里；调一块屏不会意外改变另一块屏。已存在的速度/音频设置继续复用。

**建议边界**：新增可 Codable 的 `WallpaperFraming(mode, scale, anchorX, anchorY)`，先支持现有 fit/fill 加 free；anchor 使用归一化坐标，scale 有界有限，迁移缺省等于当前中心 fit/fill。用 `VideoPreferenceOverrideKey(itemID, displayID?)` 存“此作品全部屏幕”与“此作品此屏”两层。解析优先级为**作品此屏 > 作品通用 > 显示器默认**，暂停仍只取显示器意图。避免把颜色处理顺手塞进第一版；颜色是独立后续扩展。

渲染入口建议 `VideoSession.apply(settings:framing:)` 与预览共用同一布局函数。持久值不能存当前 view points；横竖屏改变后按 source presentation size（含 transform）重算。AVPlayerLayer 的布局/裁切容器必须真改画面，不能只改 preview 缩略图。

**界面**：视频详情现有设置中加“画面”一行，fit/fill/free 与一张可拖动预览；只有多屏时显示当前目标。尺度和重置在同一区域，帮助解释范围，不新增页面。

**用户验收**：同视频横竖双屏各自保留焦点和缩放；切换作品再回来/重启后恢复；预览与桌面主体位置一致；恢复作品默认清掉对应 override；调整此屏构图或静音不传播到另一屏；手动暂停和政策挂起不会被编辑设置解除。物理双屏验收仍需真实设备，隔离两个 host 不冒充硬件覆盖。

**依赖/风险**：触点为 WallpaperItem、store 配置版本迁移、DesktopWallpaperController、共用预览与详情；现有 author properties 不动。应用框架的逐屏音频优先级需一起明确，避免同作品两个播放器同时出声。WE 官方自由对齐依据见上表 2020-12-15 公告。

### 2. 命名播放列表与每屏调度，再加入真实触发条件

**收益**：横屏循环风景、竖屏循环人像；白天/夜晚自动切换，并能在视频自然结束后切换而不截断。

**建议边界**：把当前单实例模型迁为 `GWPlaylistDocument(playlists:[Playlist], assignments:[displayUUID:playlistID])`；`PlaylistEntry(id,itemID,duration?,timeRange?)` 的 entry ID 独立于素材 UUID，允许同作品重复。每屏 `GWPlaylistRunner` 有独立 current/cursor/shuffle/timer，采用 `onSelectWallpaper(entry, displayID) async -> ApplyResult`，新画面实际准备成功再更新 current，失败保留旧会话并尝试后续候选。旧全局列表迁为一个命名默认列表，保持原先全部屏幕行为。

先落地每屏、命名、每项时长；随后用 `PlaylistTrigger.interval / videoEnded / timeOfDay` 接触发器。视频结束由实际 AVPlayerItem/Looper 第一轮完成事件传来并携带 session generation，不能用 duration×rate 的计时估计冒充。Web/Scene 没有通用结束语义，选择该触发器时退回显式 interval 或禁用并短句解释。时间段按本地 wall clock 求当前项，睡眠唤醒/时区/夏令时变化只取当前时段，不补播错过的所有项。

**界面**：现有列表页顶部一个列表 picker，旁边屏幕目标、`+` 和 `…`；时间条件收进该列表的调度 popover，条目时长放行尾。保留当前“下一张”，不增加 sidebar 子树。

**用户验收**：A 屏下一张不影响 B 屏；断开再接 UUID 恢复绑定；退出重启后列表、位置与分配恢复；某作品失败不把 UI 当前项提前标成功；手动暂停屏幕不会继续轮换；两屏同作品仍可独立暂停；结束触发在 0.5×/2×和用户 seek 后来自真正结束事件；夜间睡眠到白天唤醒仅切入当前日间项。

**依赖/边界**：替换 AppPlaybackIntegration 的 `to:nil` 回调和独立 persistence schema，播放 apply 需异步真实成功回执。应用 bundle-ID 规则/多屏 profile 可接同一调度层，但应为后续独立功能，不在本次同时实现复杂规则优先级。官方来源是 CLI、应用规则和 2018-08-20 公告；本轮未核实官方“视频结束”选项的当前完整精确定义，所以该分支是明确的本产品设计建议，不冒称已逐项复刻 WE。

### 3. Scene 作者的自选图片纹理

**收益**：让简单相框/自定义背景 Scene 的“选图片”真正可用，比继续只扩大 scalar 编辑面板更有用户价值。

**建议边界**：先支持 simple image layer 的 albedo PNG/JPEG 静态替换和作者默认回退。新增 `SceneTexturePropertyBinding(propertyKey, layerID, slot)` 与 `SceneTextureOverrideSnapshot`；复用现有 AuthorPropertyAssetStore 的系统 picker、managed copy、撤销与导出规则，Scene 不获取任意本机路径。Inspector 解析受认可的纹理绑定后传逻辑资产 ID，runtime 做有界解码并原子替换缓存。

必须先取得本应用有权使用的最小 WE 导出样例，核对真实 `texture` 定义/绑定序列化与 autosize 行为；官方教程描述功能，不是完整 PKG/JSON 格式规范。不能猜字段后把未知格式放行。暂不接受视频纹理、effect mask、particle texture 或 shortcut，未接消费链仍禁用并给局部原因。

**界面**：直接加入现有作者设置的一行图片缩略图+“选择/恢复”，搜索和仅修改继续复用。没有额外授权页面；只有选文件时开系统 picker。

**用户验收**：换两张明显不同图片在当前预览及所有活动同作品 Scene host 出现真实像素后才成功；暂停时也可更新一帧；坏图片/撤销/超限保留旧纹理；恢复默认回到作者原图；删除作品清理 managed assets；重启保持选择；另一作品不能取得该图片 grant。

**依赖**：AuthorPropertyKind/definition、Scene inspector/material texture binding、runtime cache 与 AuthorPropertyServices。scalar 控件不能伪装纹理消费已完成。官方功能来源：[Texture User Property](https://docs.wallpaperengine.io/en/scene/userproperties/texture.html)。

### 4. 把 Scene 材质合成接入生产，首批明确 blend 模式

**收益**：不是单纯换后端：让当前因非 translucent 材质拒绝的简单叠加类 Scene 得到正确画面，并建立后续效果 pass 的实际入口。

**当前硬证据**：`SceneWallpaperRuntime.compose` 仍调用 SceneWallpaperRenderer；Metal adapter 注释是 experimental accepted subset，不扩展 inspector。`MetalSceneBlend` 有 sourceOver/copy/additive，但 inspector 只准单 genericimage/genericimage2 pass、单纹理且 blending==translucent；任何 effects 数组都产生阻断诊断。独立 Metal 通过不代表生产已用 GPU，更不代表 shader 已执行。

**建议边界**：先建立 `SceneRenderBackend.prepare(validatedIR) / render(frame, viewport) / dispose` 和 `SceneMaterialIR(texture,blend,sampling,tint)`。选择确证过的 WE material blend 语义（首批例如 additive；具体源枚举/alpha 要以最小授权样例验证），接生产 Metal；原已支持内容保留 CPU 回退。承诺的新用户能力只限文档列明的 blend，未知 pass、constants、combos、RT 依赖仍阻断。缓存 GPU 纹理，不能每帧重建 compositor/全量解码。

**界面**：不增加渲染器选项页。用户继续导入、预览、应用；只在失败详情显示当前具体不支持项。后端与 pass 图留诊断。

**用户验收**：带透明半边与重叠色块的真实材质样例在预览、桌面显示正确 blend；作者颜色/透明度更新和父级 shear 不退化；生产确实选择 Metal；失败保留前一会话；多 host 无共享可变 framebuffer 串画面；删除/切换释放纹理与任务。只记录命中材质的兼容行，不能把“Metal 已接入”升级成“特效/全部 Scene 已完成”。

**依赖**：Inspector 到 material IR、SceneWallpaperRuntime 到 backend、既有 MetalSceneCompositor/PassGraph；后续需要独立 effect/shader ABI、资源解析、pass 图与质量控制。官方范围来源：[效果概述](https://docs.wallpaperengine.io/en/scene/effects/introduction.html)、[shader syntax](https://docs.wallpaperengine.io/en/scene/shader/syntax.html)。

### 5. 保存发现偏好并支持排除类别

**收益**：用户不用每次重选类型/分辨率/时期，并能稳定排除不想看的作品；减少搜索噪声，沿用一个筛选 popover。

**建议边界**：`WorkshopBrowsingPreferences:Codable` 持久保存 filters/sort/age policy，含 `includedTags` 与 `excludedTags`，同 tag 冲突有确定规则。`WorkshopSearchRequest` 显式携带排除条件；对当前 Steam SSR metadata 路径先核对服务端参数与真实结果，再选择可证实的远端排除能力。若只能本地隐藏，页数/总数须明确是远端总量，不能把一页删空标成全库零结果。取消、页码和旧请求 generation 仍跟随同一 request snapshot。

第一版可只做保存状态+genre 排除，不扩大账号能力。Approved 过滤、作者屏蔽、精确匹配与按屏幕长宽比筛选可用同一模型后续接入；不能因为标签是任意字符串就宣称 Steam 已正确执行。年龄标签仍是 metadata，不代替 Steam 账号内容权限。

**界面**：原筛选 popover 中类别支持包含/排除；顶部仅“筛选 n”和“重置”，保存默认自动完成；不要在首屏增加持久偏好说明卡或新 route。无结果给清筛选动作。

**用户验收**：关闭/重启保留所有选择和排序；包含/排除冲突稳定消解；清空搜索不清偏好；远端分页/本地隐藏不能混报总数；类型切换取消过期请求；下载页即时搜索仍仅过滤已有下载，不被发现筛选影响。

**依赖**：WorkshopSearchFilters、SteamWorkshopModels request URL、WorkshopBrowserStore snapshot schema、发现页状态；不触账号/下载队列数据。官方来源：[排除搜索内容](https://help.wallpaperengine.io/en/interface/exclude.html)。

## 全 Scene 能力矩阵：完成子项不能重命名终点

以下是按官方功能域组织的差距清单，不是完整二进制格式规格。`部分` 意味有明确支持范围且不完整。

| 官方能力域 | 当前 | 下一实际接口或依赖 |
| --- | --- | --- |
| PKG/常见 TEX 读取、压缩解码 | 部分：受限 PKG/TEX、LZ4、PNG/JPEG、RGBA/DXT1/3/5 | 其他格式、动画纹理、mips/色彩/HDR各需样例与解码路径；不以读到文件等价可渲染 |
| 图像层与父子变换 | 部分：2D、负/零 scale、祖先可见性、仿射 shear | pivot、非中心 alignment、perspective、深度/3D变换仍拒绝 |
| 材质与混合 | 部分：单 generic image pass/单纹理/translucent | 上述第4项；多 pass/RT、组合宏、uniform、sampler和shader ABI |
| 标准/自定义特效与后处理 | 未实现，effects 阻断 | effect schema/资产解析、纹理依赖、pass graph、mask、质量/HDR；每种效果分别验收 |
| 粒子与交互/音频响应 | 未实现 | emitter/initializer/operator/renderer 模型、随机/时间、纹理和音频输入 |
| 时间线/纹理动画/木偶变形 | 未实现 | animation clip、插值/骨骼/网格、播放状态、SceneScript animation API |
| 文本、字体、时钟 | 无真正文本层 | text layout/raster、字体资产、ITextLayer、脚本 text；有 textinput 作者控件不等价有文本层 |
| 3D 模型、光照、反射 | 未实现 | model/mesh/material、相机、光照、normal/reflection/shadow 与对应API |
| 视差/相机/风/摇动 | 未实现；明确关闭的 inert 默认才允许 | input/camera transforms、每屏坐标、时间/动力；不是移动整个预览图 |
| 音频播放、系统音频可视化、媒体资料/封面 | 未实现 | 独立音频播放、系统采集授权/频谱 buffer、macOS 可用媒体接口；三者不要合并成一个“音频支持” |
| 用户 scalar 属性 | 部分：实际绑定或已消费脚本属性；有 ACK | texture/group/usershortcut与更复杂condition按真实消费能力分别支持，第3项先做静态纹理 |
| SceneScript 语言/静态模块 | 部分：JSC、项目内静态模块、受限 Vec2/Vec3与层 API | 动态模块、完整类/方法/跨对象语义；按最新官方 definitions 做逐 API 映射 |
| Script 事件 | init/update/applyUserProperties/resizeScreen | destroy、applyGeneralSettings、cursor、媒体等事件和生命周期；不能将Web general callback直接复用 |
| 动态层、材质、资源、localStorage等 | 未实现或受限 | IScene/createLayer、IAssetHandle、IMaterial/IEffect/IAnimation、持久命名空间及资源生命周期 |
| 最终构图/颜色/速度/质量 | fit/fill；30fps调度上限 | 第1项可共享构图模型；Scene时间倍率、最终颜色、分辨率/抗锯齿/后处理质量需独立设置与实际渲染入口 |
| 编辑器、资产创作与发布 | 未实现 | 是独立产品级工程；运行时支持不等于可编辑/发布 |

应用规则、屏保、span/clone/同步、多屏 profile、Web 音频/媒体桥接、Web 远程资源可控授权、通用颜色调整和 Scene 完整 shader/effect/particle/3D 仍是后续真实功能，不因本轮五项完成而关闭。尤其 macOS 锁屏实验不能用 WE Windows 屏保能力替代验证。

## 社区 mac 软件审美对照

本轮重新核对[Wallspace 原作者首页](https://wallspace.app/)和[WaifuX 原作者仓库](https://github.com/jipika/WaifuX)（2026-10-18访问；均未本机运行）。只借鉴图片面积优先、封面内局部标题、低频控制按需出现。具体功能可靠性、能耗、锁屏或 Scene 宣传不能当作本项目已验证结果。

延续既有 ui-direction：五项都回到现有详情、列表和筛选 popover，避免新增 sidebar 层级；只露当前值与必要异常，授权、失败和删除的关键语义保留；渲染器、协议、缓存路径不进入普通主流程。

**执行建议**：先交付第1项和第5项，再完成第2项的每屏命名基础；第3项用最小合法导出样例明确绑定，第4项用生产材质 IR 逐步扩大真实可渲染内容。验收是各功能完成的一部分，不单独作为“下一功能”。
