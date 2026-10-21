# 作者属性原生 UI 隔离验收计划

组件：`AuthorPropertySettingsView`。本文件不接入现有 UIReviewMain，不新增生产 runtime，也不注册系统壁纸。

## 父级最小接线

```swift
AuthorPropertySettingsView(
    project: project,
    overrideStore: AuthorPropertyOverrideStore(directory: temporaryRoot.appendingPathComponent("overrides")),
    itemID: fixtureItemID,
    capabilities: AuthorPropertyEditingCapabilities(
        editableKeys: hostIsReady ? AuthorPropertyEditingCapabilities.scalarKeys(in: project) : [],
        runtimeLabel: "Web 壁纸",
        unsupportedReason: "当前视频／Scene 播放器尚未支持这些作者选项。"),
    preferredLanguages: ["zh-Hans"],
    onValuesChanged: { values in
        // 生产：等待当前预览和同 itemID 的 Web session 接收完成；失败必须 throw。
        // 验收：只记录到 MainActor fake host，不能调用生产 playback/apply/lockscreen。
    })
```

组件不创建 ScrollView、整页背景或播放器。父级放入既有详情 ScrollView；白名单仅在实际 host 就绪后提供。`scalarKeys(in:)` 是候选集合，不是运行时支持检测。父级需隔离不同 itemID，回调被拒绝时抛错。打开/读取组件不会提交设置。

## Fixture

用临时 project.json，general.properties 包含：text 分组标题；bool 开关；RGB color；整数和 fraction 滑块（范围、显式 step、precision）；combo；Unicode 多行 textinput；file/directory；未知类型完整 raw；bool 条件显示与未知函数条件。general.localization 提供 en-us 与 zh-cn 标签。预置一个被移除的 orphan override 和 unsupported file override。所有目录由本轮 UUID 临时根创建，退出只清自己的根。

测试矩阵：

| 场景 | 验收行为 |
|---|---|
| 就绪 scalar Web fake host | bool/color/slider/combo/textinput 可编辑；file/directory 保持禁用；未知字段可展开只读 |
| 显式全类型 fake host | 文件夹/文件选择按钮可用；只能选择本轮临时 fixture；fake host 仅收到字符串，不获取任何生产授权 |
| Video / Scene / Web 未就绪 | editableKeys 空；全部编辑和重置禁用；说明只出现一次；unknown disclosure 仍可展开 |
| 条件与本地化 | 更改依赖 bool 后隐藏/显示目标；不支持条件的项显示锁与原因并禁用；zh/en 切换保留同 key 值 |
| 搜索 / 已修改 | 按本地化标签和 key 搜索；修改后标记；只显示已修改；清空搜索不改任何值 |
| 单项 / 全部默认 | 单项只重置该键；全部只重置可编辑键，file/orphan 覆盖值保留；不改项目源 |
| host 拒绝 | 注入一次 throw；明确“值已保存，但尚未应用”；重试只重新提交，不声称失败值已生效 |
| 存储错误 | 临时目标文件改为目录；编辑后无 host callback；恢复文件可重试；加载失败禁用编辑 |
| 快速编辑 / 切换作品 | 挂起 fake host ack 后继续拖动，最终收到最新值；切换 itemID 不提交给新作品；单纯打开无 callback |
| 布局 | 440 / 640pt 宽；长中文标题和路径；明暗色；窗口缩放；所有设置在父级滚动区内可达 |
| 可访问性 | 键盘 Tab / Space / 原生 picker；VoiceOver label；高对比/降低透明度；降低动态效果；无自建动画 |

截图至少：440pt 只读；640pt Web 编辑 + 错误；降低透明度的同一页面。组件 accessibilityIdentifier 使用 author-property-settings、author-property-search、author-property-modified-only、author-property-reset-all、author-property-<key>、author-property-reset-<key>、author-property-status/error。

状态：session 自动化测试已执行；本计划的原生像素/VoiceOver/UI 交互验收待父级接入 UIReview 后执行，不能以 typecheck 替代。
