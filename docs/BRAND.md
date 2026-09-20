# DisplayDJ 品牌系统

## 母题：DJ Gate / 校准通道

DisplayDJ 的识别锚点不是“显示器图标加一个滑块”，而是一条不对称的校准通道：上方横向开口、左侧下行的轨道、底部轻微回勾形成可恢复的出口。fader 旋钮始终在该通道中运动；右侧 cue 只表达状态。

这条骨架同时表达显示器控制（校准通道）、DJ（fader/cue）和 Agent（通道内可观察、可恢复的任务信号），不把三种隐喻画成三个竞争的图形。

## 尺寸规则

| 表面 | 保留 | 删除 |
| --- | --- | --- |
| App / GitHub，64px 以上 | 完整 DJ Gate、轨道、knob、cue | 文字、刻度、额外弧线 |
| 32px | Gate、knob、cue | 内部轨道高光 |
| 16–18px 菜单栏 | Gate 与 knob 的单色 template | cue 颜色、阴影、渐变 |

主图标不使用显示器支架、同心 target 或太阳图形；这些元素会把它重新带回通用亮度工具的视觉类别。

## 颜色与状态

| Token | Hex | 唯一职责 |
| --- | --- | --- |
| Midnight | `#0A0F18` | 深色画布 |
| Graphite | `#111821` | 底层表面 |
| Panel | `#18222E` | 抬升表面 |
| Divider | `#2A3745` | 轨道与边界 |
| Spectral Cyan | `#55D9FF` | 唯一品牌控制色与 DJ Gate |
| Signal Lime | `#B8F36A` | active / healthy cue |
| Agent Violet | `#8B7CFF` | automation cue，不参与主图标主体 |
| Warm Amber | `#FFBC5E` | waiting / busy cue |
| Restore Coral | `#FF6F73` | error / disconnect cue |

同一份 icon、banner、架构图和状态 glyph 都从 DJ Gate 骨架出发。状态变化只改变 cue 与少量通道反馈，不能替换主轮廓。
