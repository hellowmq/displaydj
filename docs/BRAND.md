# DisplayDJ 品牌系统

## 母题

DisplayDJ 的识别核心不是“显示器 + 滑块”的叙事组合，而是一个**开放的圆角控制通道**。它由三个固定原件组成：

1. **Rounded Channel**：连续的粗圆角主轮廓。
2. **Signature Gap**：固定在右侧的缺口。
3. **Fader**：从通道内部指向缺口的一根短横线。

辨识度优先来自轮廓，不来自内部细节。最小 glyph 是品牌核心；大尺寸只允许增加材质和状态信息，不改变骨架。

## 设计原则

- 不画完整显示器，不使用支架暗示显示器。
- 不画圆形 knob、target、radar 或 camera 感图形。
- 不依赖 cue、阴影或渐变建立识别。
- 主图标保持 cyan 单色；状态色不进入默认主 glyph。
- 小尺寸优先保留轮廓、固定缺口和横向 fader。

## 尺寸规则

| 场景 | 保留 | 删除 |
| --- | --- | --- |
| App / GitHub / 64px 以上 | Channel + Gap + Fader | 装饰线、复杂轨道、状态 cue |
| 32px | Channel + Gap + Fader | 渐变、辅助图形 |
| 16–18px 菜单栏 | 单色 Channel + Gap + Fader | 圆形 knob、cue、状态色 |
| 12–16px favicon | Channel + Gap | Fader 细节 |
| 宣传图 / 封面 | Channel + Gap + Fader，可选极小状态点 | 改变主轮廓的装饰 |

菜单栏 glyph 必须按 16–18px 单独绘制，不能把 App Icon 直接缩小。

## 颜色

### 品牌核心

| Token | Hex | 用途 |
| --- | --- | --- |
| Midnight | `#0A0F18` | 主背景 |
| Graphite | `#111821` | 次级背景 |
| Spectral Cyan | `#55D9FF` | 唯一品牌主色 |
| Signal Lime | `#B8F36A` | active / healthy 辅助状态 |

### 界面语义

| Token | Hex | 用途 |
| --- | --- | --- |
| Primary Hover | `#7BE6FF` | 主交互悬停 |
| Primary Pressed | `#2FC6EA` | 主交互按下 |
| Panel | `#18222E` | 抬升表面 |
| Divider | `#2A3745` | 边界与弱轨道 |
| Text Primary | `#F4F7FB` | 主文字 |
| Text Secondary | `#9AA6B2` | 次文字 |
| Agent Violet | `#8B7CFF` | automation 状态 |
| Warm Amber | `#FFBC5E` | waiting / busy 状态 |
| Restore Coral | `#FF6F73` | error / disconnect 状态 |

## 状态原则

状态变化不改变主轮廓。只能改变界面中的辅助色，或在 64px 以上宣传物料中增加一个极小状态点；默认 App Icon 和菜单栏 icon 都不显示状态色。

参考图中的侧边栏、Preset、Automation、Agents 和 Quick Actions 是视觉语言示例，不代表当前产品已经实现这些页面或功能。
