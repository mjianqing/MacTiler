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

## 安装（DMG）

1. **只装一份**：打开 `dist/MacTiler-*.dmg`，拖到「应用程序」（`/Applications/MacTiler.app`）。不要从 Downloads / 挂载卷直接跑。
2. 打开「应用程序 / MacTiler」（无 Dock 图标，看菜单栏右侧竖条线框）。
3. **系统设置 → 隐私与安全性 → 辅助功能**：勾选 **MacTiler**（路径应是 `/Applications`）。
4. **换包后**：同 Team（`G2B4QZWQN7`）覆盖安装一般**不必**重授。若开关已开仍提示无权限：先关掉 →「−」移除 → 退出 App → 再开并授权。高级：`tccutil reset Accessibility com.junmaly.mactiler`（需你自己在终端执行）。
5. 截图用的「屏幕录制」与辅助功能分线，互不影响。
6. 日志：`~/Library/Logs/MacTiler.log`。

### 发版签发（本地）

```bash
./Scripts/package-dmg.sh
```

- 要求：钥匙串有 **Apple Development: junmaly@gmail.com (JP9BN6938U)**，Team `G2B4QZWQN7`。
- 脚本拒绝打包 **ad-hoc**（`Signature=adhoc`）。
- 本机暂无 **Developer ID Application**；对外公证/少 Gatekeeper 摩擦需 Anna 配置 Developer ID 后再改 identity。
- `bundle id` 冻结：`com.junmaly.mactiler`（勿改正式版）。

