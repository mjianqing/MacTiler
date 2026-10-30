import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let hotKeys = HotKeyManager()
    private var axObserverTimer: Timer?
    /// Skip full menu rebuild when AX/pause/strategy/auto unchanged (timer polls every 2s).
    private var lastMenuFingerprint: String = ""

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        NotificationPoster.statusItem = statusItem
        updateStatusIcon()
        rebuildMenu()
        hotKeys.handler = { [weak self] action in
            self?.handleHotKey(action)
        }
        hotKeys.start()
        axObserverTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMenuIfNeeded()
        }
    }

    private func currentStrategy() -> StrategyID {
        StrategyStore.shared.currentStrategy
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        // Don't clobber an active tip flash.
        if !(button.title.isEmpty) && button.image == nil { return }
        let store = StrategyStore.shared
        if store.isPaused {
            button.image = NSImage(systemSymbolName: "pause.rectangle", accessibilityDescription: "MacTiler 已暂停")
            button.image?.isTemplate = true
        } else {
            button.image = StrategyIcons.image(for: currentStrategy(), forStatusBar: true)
        }
    }

    private func menuFingerprint(trusted: Bool, store: StrategyStore, strategy: StrategyID) -> String {
        let scr = ScreenshotPermission.isTrusted()
        let r = store.screenshotRegionHotKey.displayString
        let d = store.screenshotDisplayHotKey.displayString
        return "\(trusted)|\(scr)|\(store.isPaused)|\(store.autoRetile)|\(strategy.rawValue)|\(store.saveScreenshotToDesktop)|\(r)|\(d)"
    }

    /// Timer path: only rebuild when relevant state flipped (avoids rewriting NSMenu every 2s).
    private func refreshMenuIfNeeded() {
        let trusted = AccessibilityPermission.isTrusted()
        let store = StrategyStore.shared
        let strategy = currentStrategy()
        let fp = menuFingerprint(trusted: trusted, store: store, strategy: strategy)
        guard fp != lastMenuFingerprint else { return }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let trusted = AccessibilityPermission.isTrusted()
        let store = StrategyStore.shared
        let strategy = currentStrategy()
        lastMenuFingerprint = menuFingerprint(trusted: trusted, store: store, strategy: strategy)

        // Header: wireframe + short status (no fraction text)
        let titleItem = NSMenuItem(
            title: store.isPaused ? "已暂停" : "当前布局",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        titleItem.image = StrategyIcons.image(for: strategy)
        menu.addItem(titleItem)

        let hint = NSMenuItem(title: "拖窗互换 · 不记各桌面", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())

        // Always show AX trusted truth (survey §4.7); actions only when untrusted.
        let axStatus = NSMenuItem(
            title: trusted ? "辅助功能：已授权 (trusted=true)" : "辅助功能：未授权 (trusted=false)",
            action: nil,
            keyEquivalent: ""
        )
        axStatus.isEnabled = false
        menu.addItem(axStatus)
        if !trusted {
            let ax = NSMenuItem(title: "打开辅助功能设置…", action: #selector(openAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
            let pathHint = NSMenuItem(title: "请勾选 /Applications/MacTiler", action: nil, keyEquivalent: "")
            pathHint.isEnabled = false
            menu.addItem(pathHint)
            let noAuth = NSMenuItem(title: "未授权：不会移动任何窗口", action: nil, keyEquivalent: "")
            noAuth.isEnabled = false
            menu.addItem(noAuth)
            let copy = NSMenuItem(title: "复制 tccutil 重置命令", action: #selector(copyTccutilReset), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        menu.addItem(NSMenuItem.separator())

        let retile = NSMenuItem(title: "按当前布局重排", action: #selector(retileNow), keyEquivalent: "r")
        retile.keyEquivalentModifierMask = [.control, .option, .command]
        retile.target = self
        retile.isEnabled = trusted && !store.isPaused
        menu.addItem(retile)

        menu.addItem(NSMenuItem.separator())

        // Strategy rows: wireframe icon + hotkey title only (PRD v1.2.1)
        for s in StrategyID.allCases {
            let item = NSMenuItem(
                title: s.menuTitle,
                action: #selector(selectStrategy(_:)),
                keyEquivalent: s.menuKeyEquivalent
            )
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.representedObject = s.rawValue
            item.state = (s == strategy) ? .on : .off
            item.image = StrategyIcons.image(for: s)
            item.toolTip = s.accessibilityLabel
            item.target = self
            item.isEnabled = trusted
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Screenshot — independent of pause (PRD). Hotkey equiv shown as hint only.
        let regionHK = StrategyStore.shared.screenshotRegionHotKey.displayString
        let shotRegion = NSMenuItem(title: "选区截图（\(regionHK)）", action: #selector(screenshotRegion), keyEquivalent: "")
        shotRegion.target = self
        menu.addItem(shotRegion)

        let displayHK = StrategyStore.shared.screenshotDisplayHotKey.displayString
        let shotDisplay = NSMenuItem(title: "焦点屏整屏（\(displayHK)）", action: #selector(screenshotDisplay), keyEquivalent: "")
        shotDisplay.target = self
        menu.addItem(shotDisplay)

        let shotPrefs = NSMenuItem(title: "截图偏好…", action: #selector(openScreenshotPrefs), keyEquivalent: "")
        shotPrefs.target = self
        menu.addItem(shotPrefs)

        if !ScreenshotPermission.isTrusted() {
            let scr = NSMenuItem(title: "打开屏幕录制设置…", action: #selector(openScreenRecording), keyEquivalent: "")
            scr.target = self
            menu.addItem(scr)
        }

        menu.addItem(NSMenuItem.separator())

        let auto = NSMenuItem(title: "自动重排", action: #selector(toggleAuto), keyEquivalent: "")
        auto.state = store.autoRetile ? .on : .off
        auto.target = self
        menu.addItem(auto)

        let pause = NSMenuItem(
            title: store.isPaused ? "恢复铺砖" : "暂停铺砖",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        menu.addItem(pause)

        menu.addItem(NSMenuItem.separator())

        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let ver = NSMenuItem(title: "MacTiler \(short) (build \(build))", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)

        let quit = NSMenuItem(title: "退出 MacTiler", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusIcon()
    }

    private func handleHotKey(_ action: HotKeyManager.Action) {
        // Screenshot must work without Accessibility (separate TCC: Screen Recording).
        if action == .screenshotRegion {
            runScreenshot(.region)
            rebuildMenu()
            return
        }
        if action == .screenshotDisplay {
            runScreenshot(.focusDisplay)
            rebuildMenu()
            return
        }

        guard AccessibilityPermission.isTrusted() else {
            present(.needAccessibility)
            rebuildMenu()
            return
        }
        let store = StrategyStore.shared

        switch action {
        case .retile:
            present(WindowTiler.shared.retile())
        case .prevStrategy:
            let next = currentStrategy().previous()
            store.setStrategy(next)
            present(WindowTiler.shared.retile(strategy: next))
        case .nextStrategy:
            let next = currentStrategy().next()
            store.setStrategy(next)
            present(WindowTiler.shared.retile(strategy: next))
        case .strategy1:
            apply(.maximize)
        case .strategy2:
            apply(.twoHalves)
        case .strategy3:
            apply(.threeThirds)
        case .strategy4:
            apply(.quartersQuartersHalf)
        case .strategy5:
            apply(.halfQuartersQuarters)
        case .strategy6:
            apply(.quarterHalfQuarter)
        case .pause:
            store.isPaused.toggle()
            present(store.isPaused ? .paused : .info("已恢复"))
        case .screenshotRegion, .screenshotDisplay:
            break // handled above (no AX required)
        }
        rebuildMenu()
    }

    private func apply(_ s: StrategyID) {
        StrategyStore.shared.setStrategy(s)
        present(WindowTiler.shared.retile(strategy: s))
    }

    private func present(_ message: TilerMessage) {
        switch message {
        case .needAccessibility:
            notify("需要「辅助功能」才能移动窗口", AccessibilityPermission.guidanceBody)
            AccessibilityPermission.openSystemSettingsIfNeeded()
        case .unsupportedWindow:
            notify("部分窗口无法调整", "已跳过不支持 set frame 的窗口。")
        case .tooManyWindows(let max):
            notify("当前布局最多 \(max) 窗", "多出的窗口保持原位，不会自动收进格子。")
        case .paused:
            notify("已暂停", "暂停期间不会移动窗口。")
        case .info(let text):
            notify("MacTiler", text)
        case .retiled(let count):
            notify("已重排", "\(count) 个窗口")
        case .none:
            // Should not be used for retile success anymore; still tip so never silent.
            notify("MacTiler", "完成")
        }
    }

    private func notify(_ title: String, _ body: String) {
        NotificationPoster.post(title: title, body: body)
    }

    @objc private func openAccessibility() {
        // Explicit user action only: open Settings + at most one system prompt per process.
        AccessibilityPermission.openSystemSettings()
        _ = AccessibilityPermission.requestSystemPromptOnce()
    }

    @objc private func copyTccutilReset() {
        AccessibilityPermission.copyTccutilResetToPasteboard()
        notify("已复制", AccessibilityPermission.tccutilResetCommand + "（不会自动执行）")
    }

    @objc private func retileNow() {
        present(WindowTiler.shared.retile())
        rebuildMenu()
    }

    @objc private func selectStrategy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let s = StrategyID.migrated(from: raw)
        StrategyStore.shared.setStrategy(s)
        present(WindowTiler.shared.retile(strategy: s))
        rebuildMenu()
    }

    @objc private func toggleAuto() {
        StrategyStore.shared.autoRetile.toggle()
        rebuildMenu()
    }

    @objc private func togglePause() {
        StrategyStore.shared.isPaused.toggle()
        present(StrategyStore.shared.isPaused ? .paused : .info("已恢复"))
        rebuildMenu()
    }

    @objc private func quit() {
        hotKeys.stop()
        NSApp.terminate(nil)
    }

    @objc private func screenshotRegion() {
        runScreenshot(.region)
        rebuildMenu()
    }

    @objc private func screenshotDisplay() {
        runScreenshot(.focusDisplay)
        rebuildMenu()
    }

    @objc private func openScreenshotPrefs() {
        ScreenshotPrefsPanel.shared.show { [weak self] in
            self?.hotKeys.reload()
            self?.rebuildMenu()
        }
    }

    @objc private func openScreenRecording() {
        ScreenshotPermission.openSystemSettings()
        _ = ScreenshotPermission.requestAccess()
    }

    /// Screenshot ignores tiling pause (PRD).
    private func runScreenshot(_ mode: ScreenshotService.Mode) {
        let outcome = ScreenshotService.capture(mode)
        switch outcome {
        case .success(let path):
            if let path {
                notify("已截图", "剪贴板 + \(URL(fileURLWithPath: path).lastPathComponent)")
            } else {
                notify("已截图", "已复制到剪贴板")
            }
        case .cancelled:
            notify("已取消", "未截取")
        case .needScreenRecording:
            notify("需要屏幕录制权限", "打开开关后请退出并重开 MacTiler，然后重试。")
            ScreenshotPermission.openSystemSettingsIfNeeded()
        case .failed(let reason):
            notify("截图失败", reason)
        }
    }
}
