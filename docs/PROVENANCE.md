# 来源与许可

用户提供的两份源码压缩包是此次整合的来源，而不是从新的 GitHub 项目抓取的代码。压缩包 SHA-256 与 Swift 文件数记录在 [source-archives.json](source-archives.json)。

| 来源 | 采用内容 | 原始许可 |
| --- | --- | --- |
| VibeDisplay.zip | Core、Server、CLI 与测试 | [VibeDisplay MIT](../LICENSES/VibeDisplay.txt) |
| DisplayDJ.zip | 硬件 Core、菜单栏、兼容 CLI 与测试 | [DisplayDJ MIT](../LICENSES/DisplayDJ.txt) |

DisplayDJ 的许可证明确声明派生自 MonitorControl，并列明 2017–2024 MonitorControl Contributors 版权。合并后的项目保留这一声明。VibeDisplay 原 README 的“不是 MonitorControl 源码派生”不能套用到整个合并项目。

没有导入压缩包的 `.git` 历史、内部远端与 Git 用户配置、`.build`、旧发布包、macOS 元数据和内部工作记录。公开文档重新编写，不将源包里的历史硬件验证声明当成本次验收证据。

内部模块名 DisplayDJCore / DisplayDJBar / DisplayDJCLI 保留，用于来源追踪与兼容；对外产品名为 DisplayDJ，主命令为 display-cli。
