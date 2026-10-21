# UI 一致性只读审计

快照：2026-10-18 13:39 CST。此时其他成员正在改主窗口 titlebar、shared top alignment 与 safe area；源码会继续更新。本文只读取源码，没有启动 GUI、账户或锁屏，没有修改生产代码；未做像素级截图验证。主窗口隐藏「玻璃壁纸」标题与 sidebar/detail 顶部严格对齐已有专人处理，不重复提出第二套偏移修复。

## 当下最明显的五处偏差

### 1. 同类图片卡片的字号、内边距与图上按钮尺寸不同

证据：`WallpaperCardView.swift` 的标题 17 pt、内容 padding 18、按钮 minimum 30；`WorkshopDiscoveryComponents.swift` 的标题 15 pt、内容 padding 16、图标按钮 34×34；`WorkshopDownloadsView.swift` 用 `.headline`、padding 14、原生 small 控件。同样是壁纸封面，跨页会显得一页像主图、一页像小型工具卡。

最小修复：浏览/素材两套卡统一标题 16 pt semibold、padding 16、元数据 caption2、图标控制 34×34；素材「应用」保持文字按钮，高度至少 34。下载标题也明确为 16 pt，状态操作可保持 small，但行高至少与 34 pt 图标控制协调。先直接改已有值，不创建通用卡片协议或新 design system。

比例与圆角是次要细节：素材 1.5:1/22，发现 1.55:1/22，下载圆角 20 且 minHeight 280。可以顺手把前两者统一 1.5:1，下载圆角统一 22；**不要强制下载卡固定比例**，它必须容纳真实进度、失败恢复与展开信息。比例差 0.05 本身不是最值得优先的视觉问题。

### 2. 完成下载卡比其他卡片有更多高亮与主按钮

证据：`WorkshopDownloadsView.swift` 的顶部可同时出现 mint「已完成」状态和 mint「已导入素材库」圆形 check；底部 `rowActions` 又同时提供 glass「详情与设置」、glassProminent 视频预览及自定义 glass「更多」。暂停则是醒目的继续下载，失败有醒目的重试。完成态的重心因此比正在处理/需要恢复的状态更重。

最小修复：完成态只保留一个成功状态图标；「已导入素材库」改为状态的 tooltip 或普通小字，避免两个绿色 check。将视频预览改为普通 `.glass`，只让当前恢复动作「继续」「重试」使用 `.glassProminent`；完成态不需要强色主 CTA。更多菜单用与其余图标按钮相同的 34 pt hit area。保留所有既有行为、禁用条件和已导入标记语义，不改调度与导入逻辑。

### 3. 失败信息依赖封面底色，且重试与普通 action row 分家

证据：`WorkshopDownloadsView.swift` 的 `failurePanel` 是橙色错误文字 + `.orange.opacity(0.08)` 背景，仍叠在彩色封面上，最多三行；内部包含重试、检查账号，下面还继续显示普通 `rowActions`。标题、项目摘要、三行错误、两组动作、信息 disclosure 会使失败卡明显增高，并让同一状态有两处操作区。

最小修复：错误摘要改成一行白色/primary 文字，橙色只用于警告符号；使用稳定暗底或普通较实的填充，不依赖仅 8% 橙色底。完整错误移进已经存在的「信息」disclosure。把失败的重试和检查账号收进同一 action row，或在失败状态不再另渲染空/重复普通操作区。错误摘要只缩展示，不截断保存的真实诊断内容；redaction 保持。

### 4. 次级窗口的头部像来自四套界面

证据：`WorkshopAccountDialog.swift` 是仅 xmark 的空顶栏、padding 16、Divider，标题在内容区；`WallpaperDetailsWindowContent.swift` 是标题+完成的 glass header，水平内/外边距都 16；`WorkshopBrowsingDetail.swift` 是标题+完成的 glass header，外边距 20；`WorkshopVideoPreviewSheet.swift` 是无遮罩标题+关闭，整体 padding 20。它们背景已经统一为 `PopupSurfaceBackground`，头部却仍有裸顶栏、独立玻璃栏、空栏三种结构。

最小修复：次级窗口统一普通 `HStack` header：标题 headline，关闭/完成使用相同文字和常规 controlSize，水平 20、竖直 12，下方一个 Divider。去掉 header 的独立自定义 glass 外壳即可，不改 sheet/window 生命周期。账号把「Steam 登录」标题放到这条已有顶栏，再移除内容里的同义标题；已登录账号管理状态可保留更准确标题。不要连带把视频播放器圆角也强制成封面卡的 22：播放器是不同用途的内容。

详情主体已有一层 `style.panelBackground(26)`，内部大多已使用 `groupedBackground`，无需本轮再重排整套详情表单。只统一 header 就能消除最明显的变化。

### 5. 发现页仍有少量说明性文案和独立玻璃标签

证据：`WorkshopSearchView.swift` 的 savedShelf 仍将「稍后查看 / 仅保存在本机 / N 项」包在独立 glass 面；结果状态使用「搜索已停止 · 可重新搜索或选择主题继续探索」；发现卡 Scene 文案含「需运行验证」，但类型限制已有详情/筛选说明；`WorkshopBrowsingDetail.swift` 的已完成反馈是「下载完成，可打开本地详情与设置」。这些语义大都正确，但与页面已存在的标题、按钮、帮助信息重复。

最小修复：savedShelf 改普通标题「稍后查看 · N」，本机保存范围留在已有按钮 help；已停止改「搜索已停止」并保留可操作按钮；下载完成改「已完成」，真实文件不可用的告警继续明确显示。Scene 兼容性边界仍有意义，不能简单全部删除，可在首次详情/类型 help 说明，卡片只保留「Scene」。这项优先级低于头部、按钮、失败可读性，不建议为删几句文案修改产品状态机。

## 已改善、无需重复改动

- 设置页大「设置」标题已移除，版本已在末尾；高级工具默认收起。
- 发现页 trend/filter/recent-search 已多处改为普通填充或 borderless，近期修改正在消除 glass 套 glass。
- 下载常态背景已经透明；账号入口没有单独导航页；暂停/完成进度环的规则在 presentation helper 中维护，不在卡片里再加另一套判断。
- 封面单击进入详情，应用由显式按钮触发；不能为了统一按钮外观改成单击立即应用。
- 主页面水平边距和顶部对齐会被同级布局任务统一，本文不会建议在各页叠加新的 `.offset(y:)`。

## 推荐实施顺序

先完成主窗口标题/顶边对齐，再做图卡 16 pt/16 padding/34 pt 控制的局部数值统一与下载 primary-action 收敛；失败可读性其次；popup header 若本轮时间允许可单独小步统一。没有必要把所有 `glassEffect`、圆角或容器都归到一个复杂组件中，保持现有行为与辅助功能降级即可。
