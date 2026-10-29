# MacTiler

macOS 原生菜单栏分屏（Swift + Accessibility）。对齐 **PRD v1.2**：五种**全竖条**策略 + 一键重排 + **拖窗互换**。不关 SIP；无 Electron；无跨桌面记忆；无命名档案。

## 编译运行

```bash
cd ~/Documents/github/mac-tiler
xcodegen generate
xcodebuild -scheme MacTiler -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/MacTiler.app
```

系统设置 → 隐私与安全性 → 辅助功能 → 勾选 **MacTiler**。

## 策略（左→右竖条）

菜单用**竖条线框图标**示意（PRD v1.2.1），不写分数主文案；旁注快捷键 ⌃⌥⌘2…6。状态栏图标随当前布局切换。

| 快捷键 | 线框含义 | id |
|--------|----------|-----|
| ⌃⌥⌘2 | 两等分 | `two-halves` |
| ⌃⌥⌘3 | 三等分 | `three-thirds` |
| ⌃⌥⌘4 | 窄\|窄\|宽 | `quarters-quarters-half` |
| ⌃⌥⌘5 | 宽\|窄\|窄 | `half-quarters-quarters` |
| ⌃⌥⌘6 | 窄\|宽\|窄 | `quarter-half-quarter` |

已作废：`half-two-quarters`（半屏 + 上下两四分）。

## 快捷键

| 动作 | 键 |
|------|----|
| 重排 | ⌃⌥⌘R |
| 循环策略 | ⌃⌥⌘[ / ] |
| 直选 | ⌃⌥⌘2…6 |
| 暂停 | ⌃⌥⌘P |

## 拖拽互换

按住可管理窗 A，拖到另一可管理窗 B 区域内松手（拖移距离 ≥ ~48pt）→ 两者 frame 互换。暂停时不互换。

偏好：`~/Library/Application Support/MacTiler/preferences.json`
