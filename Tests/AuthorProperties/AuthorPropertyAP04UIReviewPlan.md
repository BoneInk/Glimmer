# AP04 原生资源控件验收

仅临时库、许可/自建素材与 review backend；不使用生产账号、当前桌面或锁屏。此计划补充既有 scalar 验收，不修改 UIReviewMain。

父级接线：`AuthorPropertySettingsView(... resourceActions: AuthorPropertyResourceActions { request in try await service.perform(request) }, ... onValuesChanged: scalarCallback)`。资源 Request/Operation/Failure/Actions 为 AuthorPropertyAssets 内 Foundation-only 桥接类型。

事务所有权：父 service 负责 grant checkpoint → 授权并生成可读虚拟资源 → override 存盘 → manifest 与 host ACK。存盘失败回滚 grant；已保存但 ACK 失败保留 grant 和 override，抛 `AuthorPropertyResourceFailure(persisted:true, message:)`。UI 重试该状态发送 `.retry`，不再次打开 picker 或重选源，不重复 scalar callback。旧副本仅全部 live host 确认后才可 prune，UI 不 prune。

原生交互矩阵：

| 操作 | 预期 |
|---|---|
| 取消 NSOpenPanel | 不调用资源 service，不写 override/grant，不变桌面 |
| 选择临时图片 | file 控件显示文件名，service 收到原生选择 URL；持久化仅虚拟值，网页真实读取所选内容 |
| 选择临时目录 | 显示“已授权文件夹”；刷新重新扫描；空选择刷新不可点 |
| 清除 / 单项默认 | 走 clear/reset 资源事务，撤销该 key；不影响另一 item/key |
| 全部默认 | 资源与 scalar 各走正确通道，保留不支持和 orphan 值；不重复 scalar callback |
| 保存失败 | grant/override 保持此前值，明确未保存，可重试 |
| host ACK 失败 | 显示资源设置已保存但尚未应用；重试更新已保存 manifest，不重复制/撤销 |
| picker 打开后关闭/切换作品 | panel 被取消，结果须匹配当前 session；不把 A 的选择写到 B |
| 授权进行中切换作品 | 已明确选中的 A 事务可以完成，但只写 A；B 立即独立；当前 session 的其他编辑 busy |
| Video/Scene 或无资源 actions | 控件只读；存在 schema 字段不等于 runtime 支持 |

必须另做真实 Web host evidence：选图片/目录后实际 DOM/像素变化；撤销后新请求拒绝且其他 item 不可读；ondemand 与 fetchall 各自官方回调；拒绝权限/来源丢失/重启恢复；旧 host 未 ACK 时保留旧版本。当前 UI session 测试的 host 是受控 fixture，不能替代这些。

卡片 focused fixture：`Tests/UIReview/LibraryCardFloatingReview.swift` 单独与 WallpaperCard/真实 model/shared glass 编译，替换 ThumbnailCache 为 fixture actor；不与生产 ThumbnailCache 一起编译。输出 `evidence/library-card-floating-native.png`。覆盖 240/290/340pt、长中文、Web 无封面、缺失文件、选中、正常/降低透明度。NSView bitmap 不完整捕获 compositor 的真实 Liquid Glass；最终需要 native 窗口肉眼检查和鼠标/键盘命中。

卡片交互重点：封面/标题单击打开详情与设置；独立详情/收藏/全部屏三个按钮；context menu；拖出 Web 整项目/视频文件；缺失禁用 apply；任何预览/打开详情均不应用。建议 fake callback 分别计数，验证每次只触发指定动作。
