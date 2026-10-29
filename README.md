# MacTiler

macOS 原生菜单栏分屏 MVP（Swift + Accessibility）。不关 SIP，不做 Electron，不做自建工作区。

## 编译运行

```bash
cd ~/Documents/github/mac-tiler
xcodegen generate
xcodebuild -scheme MacTiler -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/MacTiler.app
```

首次运行会提示辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 **MacTiler**。未授权时不会移动任何窗口。

## 快捷键

| 动作 | 快捷键 |
|------|--------|
| 按当前策略重排 | ⌃⌥⌘R |
| 循环策略 | ⌃⌥⌘[ / ⌃⌥⌘] |
| 直选 1/2 · 1/3×3 · 半+两四分 | ⌃⌥⌘2 / ⌃⌥⌘3 / ⌃⌥⌘4 |
| 暂停 / 恢复 | ⌃⌥⌘P |
| 半屏左右镜像（half-two-quarters） | ⌃⌥⌘\ |

## 策略

- `two-halves`：左右各 1/2
- `three-thirds`：左中右各 1/3
- `half-two-quarters`：半屏 + 上下两个 1/4（默认半屏在左，可镜像）

窗数不足时自动降级（2 窗→对半；1 窗→最大化）。第 4+ 窗不自动收进格子，并提示。

## Space 记忆

若公开 API 无法稳定识别 macOS Space id，会**降级为命名档案**（菜单里切换 Default / Coding / Writing），只对当前可见桌面上的窗口重排。详见交付说明。

偏好保存在：`~/Library/Application Support/MacTiler/preferences.json`

## Bundle

- Bundle ID：`com.junmaly.mactiler`
- Team：`G2B4QZWQN7`（与字幕 App 相同；若签名失败请在 Xcode 改 Team）
