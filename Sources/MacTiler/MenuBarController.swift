import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let hotKeys = HotKeyManager()
    private var axObserverTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "MacTiler")
            button.image?.isTemplate = true
        }
        rebuildMenu()
        hotKeys.handler = { [weak self] action in
            self?.handleHotKey(action)
        }
        hotKeys.start()
        axObserverTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func currentStrategy() -> StrategyID {
        StrategyStore.shared.currentStrategy
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        let store = StrategyStore.shared
        let strategy = currentStrategy()

        let titleItem = NSMenuItem(
            title: store.isPaused ? "MacTiler · 已暂停" : "MacTiler · \(strategy.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let hint = NSMenuItem(title: "仅当前策略 · 不记各桌面", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())

        if !trusted {
            let ax = NSMenuItem(title: "打开辅助功能设置…", action: #selector(openAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
            let noAuth = NSMenuItem(title: "未授权：不会移动任何窗口", action: nil, keyEquivalent: "")
            noAuth.isEnabled = false
            menu.addItem(noAuth)
            menu.addItem(NSMenuItem.separator())
        }

        let retile = NSMenuItem(title: "按当前策略重排", action: #selector(retileNow), keyEquivalent: "r")
        retile.keyEquivalentModifierMask = [.control, .option, .command]
        retile.target = self
        retile.isEnabled = trusted && !store.isPaused
        menu.addItem(retile)

        menu.addItem(NSMenuItem.separator())

        for s in StrategyID.allCases {
            let item = NSMenuItem(title: s.displayName, action: #selector(selectStrategy(_:)), keyEquivalent: "")
            item.representedObject = s.rawValue
            item.state = (s == strategy) ? .on : .off
            item.target = self
            item.isEnabled = trusted
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let mirror = NSMenuItem(
            title: store.halfOnLeft ? "半屏在左（点此切到右）" : "半屏在右（点此切到左）",
            action: #selector(toggleMirror),
            keyEquivalent: "\\"
        )
        mirror.keyEquivalentModifierMask = [.control, .option, .command]
        mirror.target = self
        menu.addItem(mirror)

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

        let quit = NSMenuItem(title: "退出 MacTiler", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func handleHotKey(_ action: HotKeyManager.Action) {
        guard AccessibilityPermission.isTrusted(prompt: true) else {
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
        case .strategy2:
            store.setStrategy(.twoHalves)
            present(WindowTiler.shared.retile(strategy: .twoHalves))
        case .strategy3:
            store.setStrategy(.threeThirds)
            present(WindowTiler.shared.retile(strategy: .threeThirds))
        case .strategy4:
            store.setStrategy(.halfTwoQuarters)
            present(WindowTiler.shared.retile(strategy: .halfTwoQuarters))
        case .pause:
            store.isPaused.toggle()
            present(store.isPaused ? .paused : .info("已恢复"))
        case .mirror:
            store.halfOnLeft.toggle()
            if currentStrategy() == .halfTwoQuarters && !store.isPaused {
                present(WindowTiler.shared.retile())
            }
        }
        rebuildMenu()
    }

    private func present(_ message: TilerMessage) {
        switch message {
        case .needAccessibility:
            notify("需要辅助功能权限", "请在系统设置中允许 MacTiler，然后重试。")
            AccessibilityPermission.openSystemSettings()
        case .unsupportedWindow:
            notify("部分窗口无法调整", "已跳过不支持 set frame 的窗口。")
        case .tooManyWindows(let max):
            notify("当前策略最多 \(max) 窗", "多出的窗口保持原位，不会自动收进格子。")
        case .paused:
            notify("已暂停", "暂停期间不会移动窗口。")
        case .info(let text):
            notify("MacTiler", text)
        case .none:
            break
        }
    }

    private func notify(_ title: String, _ body: String) {
        NotificationPoster.post(title: title, body: body)
    }

    @objc private func openAccessibility() {
        AccessibilityPermission.openSystemSettings()
        _ = AccessibilityPermission.isTrusted(prompt: true)
    }

    @objc private func retileNow() {
        present(WindowTiler.shared.retile())
        rebuildMenu()
    }

    @objc private func selectStrategy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = StrategyID(rawValue: raw) else { return }
        StrategyStore.shared.setStrategy(s)
        present(WindowTiler.shared.retile(strategy: s))
        rebuildMenu()
    }

    @objc private func toggleMirror() {
        StrategyStore.shared.halfOnLeft.toggle()
        if currentStrategy() == .halfTwoQuarters {
            present(WindowTiler.shared.retile())
        }
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
}
