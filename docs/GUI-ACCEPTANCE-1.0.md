# 1.0 双屏界面验收（开发机）

适用环境：已安装本地 1.0.0 候选的 Mac，内建屏与 HP D27k 同时在线。下面每段 `bash` 命令都可从任意终端目录直接复制运行：使用 App 内 CLI 的**绝对路径**，不用先 `cd`，也不用把 `display-cli` 加入 `PATH`。复制时不要带终端提示符 `%`。界面操作需由操作者观察；命令回读不能代替肉眼效果。日志只保存在本机，分享前检查 UUID、序列号、用户名和路径。

## 0. 打开设置窗口

如果 App 尚未运行，在终端执行：

```bash
open -a "/Applications/DisplayDJ.app" --args --display-tools
```

如果 App 已在菜单栏运行，按下面的界面路径打开：

```text
菜单栏 DisplayDJ 图标 → 显示设置与预设
```

## 1. 确认两台显示器和服务

在终端逐行执行；应看到 `display-cli 1.0.0`、内建屏与 `hp-d27k`，且服务正在运行。你先前直接输入 `display-cli doctor` 出现 `command not found`，是因为当前目录不在系统的 `PATH` 中；以下写法与所在目录无关。

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" doctor
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" daemon status
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all
```

将开始时的亮度和 HP 原模式保存到桌面；这些文件含显示器标识，仅保留在本机：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all --json > "/Users/wenmaoquan/Desktop/displaydj-brightness-before.json"
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" modes list --display hp-d27k --json > "/Users/wenmaoquan/Desktop/displaydj-hp-original-mode.json"
```

## 2. 开始记录界面日志

打开**另一个终端窗口**，运行下面的命令；它会持续运行，测试完按 `Control-C` 停止。`BrightnessSync`、`BrightnessWrite`、`BrightnessHotkey`、`SoftwareDimming` 日志记录目标序号、百分比和结果或错误类别。模式守护日志另存在 App 的私有日志目录。

```bash
/usr/bin/log stream --info --debug --style compact \
  --predicate 'subsystem == "io.github.hellowmq.displaydj" && (category == "BrightnessSync" || category == "BrightnessWrite" || category == "BrightnessHotkey" || category == "SoftwareDimming")' \
  > "/Users/wenmaoquan/Desktop/displaydj-ui-acceptance.log"
```

## 3. 检查两屏设置

以下是 **App 界面操作，不要粘贴到终端**：

```text
1. 打开“显示设置”页。
2. 在“显示器”下拉框中切换内建屏和 HP。
3. 检查“多显示器控制”“分辨率与刷新率”“显示器音量与对比度”“软件调光 · Gamma”。
4. 选中 HP，点击“读取控制项”。
```

预期选中目标与卡片一致；HP 对比度有读数，音量明确显示不支持；切换屏幕后 Gamma 数值重新读取，不沿用另一屏的值。若控件缺失、文字被遮住或显示错误，请截图并记下时间。

终端可单独核对 HP 的控制项和两屏 Gamma：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" contrast get --display hp-d27k
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" volume get --display hp-d27k
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" dimming get --display all
```

## 4. HP 软件调光

以下是 **App 界面操作，不要粘贴到终端**：

```text
1. 在设置窗口选择 HP。
2. 将“软件调光 · Gamma”滑块调到 97% 后松开，等待自动应用。
3. 观察 HP 是否轻微变暗、内建屏是否保持原样。
4. 点击“关闭并恢复颜色”，确认 HP 画面恢复。
```

这一步不需要辅助功能权限，且不应改变 HP 的硬件背光读数。

应用后和恢复后各运行一次，比较结果；恢复后 HP Gamma 应是 100%，硬件亮度应与步骤 1 的基线一致：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" dimming get --display all
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display hp-d27k
```

如果颜色未恢复，可明确对 HP 执行恢复命令，再回读：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" dimming off --display hp-d27k
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" dimming get --display hp-d27k
```

## 5. 双屏硬件亮度同步

先在终端记录当前两屏硬件亮度：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all
```

以下是 **App 界面操作，不要粘贴到终端**：

```text
1. 在设置窗口打开“同步调节硬件亮度”。
2. 在菜单栏弹出的 HP 亮度卡片上增减 5 个百分点。
3. 反向调整 5 个百分点，最后关闭同步。
```

预期两屏分别按相同百分点变化并回到各自原值；如果任一屏读取失败，同步应拒绝启用；如果写入失败，应显示对应屏幕的错误，不应被另一屏的成功结果覆盖。

操作后再回读，并与步骤 1 保存的基线比较：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all
/bin/cat "/Users/wenmaoquan/Desktop/displaydj-brightness-before.json"
```

若亮度没有回到基线，先在 App 中分别恢复；停止后续写入，保留步骤 2 的日志和这次回读。

## 6. 动态快捷键目标

这一步才需要在系统中允许 DisplayDJ 使用辅助功能，并在 App 中启用快捷键。系统设置的位置：

```text
系统设置 → 隐私与安全性 → 辅助功能 → DisplayDJ
```

以下是 **App 与系统界面操作，不要粘贴到终端**：

```text
1. 在系统辅助功能中允许 DisplayDJ，并在 App 中启用快捷键。
2. 目标选“选中的显示器”；在设置窗口分别选内建屏、HP，按 ⌃⌘- 降亮、⌃⌘= 增亮。
3. 目标改为“鼠标所在显示器”；把指针分别移到两屏，再按相同快捷键。
4. 反向按键恢复各屏原亮度；最后撤销辅助功能权限并观察提示。
```

每次只应改变目标屏幕；权限撤销后，按键不应误调其他屏幕。

每一轮操作前后运行：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all
```

记录目标选项、指针所在屏幕和按键时间，便于与步骤 2 的日志对齐。

## 7. HP 显示模式确认

在操作前先看当前模式和可选模式；步骤 1 的 JSON 文件已保存本次会话的原模式 ID。**模式 ID 仅在本次连接会话有效**，不要照抄旧报告中的数字。

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" modes list --display hp-d27k
```

以下是 **App 界面操作，不要粘贴到终端**：

```text
1. 只选 HP 的可用 1600 × 900 @ 60 Hz 模式，直接点击“应用并确认”，选“保留模式”。
2. 在 App 中切回原模式，再次使用“应用并确认”并保留。
3. 重新选择另一个可用模式并点击“应用并确认”，这次不点击确认，等待 15 秒自动恢复。
```

预期内建屏不变，HP 在确认后保留目标模式；未确认的 15 秒超时恢复操作前的模式。若窗口不可见，先等待自动恢复，不要立即重复写入。

操作后回读当前模式，并查看守护日志：

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" modes list --display hp-d27k
/usr/bin/tail -n 80 "/Users/wenmaoquan/.displaydj/logs/mode-guard.jsonl"
```

**只有 HP 未自动恢复、且步骤 1 的原模式文件确实来自当前连接会话时**，才复制下面整段执行显式恢复。它从保存的文件读取原 HP UUID 和模式 ID，不使用文档里写死的数字：

```bash
/usr/bin/python3 - <<'PY'
import json
import subprocess

snapshot = "/Users/wenmaoquan/Desktop/displaydj-hp-original-mode.json"
cli = "/Applications/DisplayDJ.app/Contents/MacOS/display-cli"
with open(snapshot, encoding="utf-8") as file:
    display = json.load(file)["data"]["displays"][0]
subprocess.run(
    [cli, "modes", "set", str(display["current"]["id"]),
     "--display", "uuid:" + display["displayUUID"]],
    check=True,
)
PY
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" modes list --display hp-d27k
```

## 8. 结束和报告

在日志终端按 `Control-C`。检查两屏硬件亮度已回到步骤 1 的值、Gamma 为 100%、HP 为原模式。若有失败，停止后续写入，保留步骤、发生时间、预期与实际画面，以及本机日志；分享日志前检查私人标识。

```bash
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" brightness get --display all
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" dimming get --display all
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" modes list --display hp-d27k
"/Applications/DisplayDJ.app/Contents/MacOS/display-cli" daemon logs --lines 80
```

```text
失败步骤：
发生时间：
操作前两屏亮度／模式：
预期画面：
实际画面和错误文字：
是否已恢复原亮度、Gamma 和模式：
```

本页未覆盖干净首装、macOS 13/14、Intel、睡眠唤醒、不同线材和其他型号显示器。它们在 [1.0 发布验收清单](RELEASE-1.0-CHECKLIST.md) 中单独跟踪。
