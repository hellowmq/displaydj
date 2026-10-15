# 产品预览素材维护

2026-10-16 核对远端 `hellowmq/displaydj` 的 master 文件树：原有成品素材只有 `Assets/DisplayDJIcon.png` 与 `.svg`，README 没有原生 App 截图。它们仍对应 Full，保留不替换。

Lite 首发新增：

- `Assets/DisplayDJLiteIcon.svg` / `.png`：用户已通过的开口框与圆点图标，构建成 Lite 的 icns；不是 Full 图标替换件。
- `Assets/Previews/DisplayDJLite-0.1.0.png`：来自 `/Applications/DisplayDJLite.app` 的真实运行窗口，只裁取该窗口。图中的保存记录是恢复入口，不证明目标在线或恢复成功。

另只读核对 `hellowmq/hellowmq.github.io`：`studio/displaydj-settings-1.0.2.webp` 仍展示 Full 设置页，Full 界面本轮未改，不需换成 Lite。网站若增加 Lite，应另加产品对应素材与入口；本次没有修改或部署网站仓库。

维护标准：截图使用明确版本的安装实例；保留产品/版本/状态说明，不把模拟屏幕、概念稿或 UI 渲染当真实设备成功证据。Full 交互改版实现后重新截图，再更新其对应页面。真实屏幕 UUID、序列号和其他 App/桌面内容不进入公开图。
