import AppKit
import Carbon.HIToolbox

/// Lightweight prefs: save-to-desktop + rebind screenshot hotkeys (PRD).
final class ScreenshotPrefsPanel: NSObject, NSWindowDelegate {
    static let shared = ScreenshotPrefsPanel()

    private var window: NSWindow?
    private var saveCheckbox: NSButton!
    private var regionLabel: NSTextField!
    private var displayLabel: NSTextField!
    private var warnLabel: NSTextField!
    private var recordingTarget: RecordingTarget?
    private var localMonitor: Any?
    private var onHotKeysChanged: (() -> Void)?

    private enum RecordingTarget { case region, display }

    func show(onHotKeysChanged: @escaping () -> Void) {
        self.onHotKeysChanged = onHotKeysChanged
        if window == nil {
            build()
        }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "截图偏好"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))

        saveCheckbox = NSButton(checkboxWithTitle: "同时存桌面（MacTiler-时间戳.png）", target: self, action: #selector(toggleSave))
        saveCheckbox.frame = NSRect(x: 20, y: 210, width: 380, height: 24)
        content.addSubview(saveCheckbox)

        let regionTitle = NSTextField(labelWithString: "选区截图快捷键")
        regionTitle.frame = NSRect(x: 20, y: 170, width: 160, height: 20)
        content.addSubview(regionTitle)

        regionLabel = NSTextField(labelWithString: "")
        regionLabel.frame = NSRect(x: 180, y: 170, width: 120, height: 20)
        regionLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        content.addSubview(regionLabel)

        let regionBtn = NSButton(title: "改键…", target: self, action: #selector(recordRegion))
        regionBtn.frame = NSRect(x: 310, y: 166, width: 80, height: 28)
        content.addSubview(regionBtn)

        let displayTitle = NSTextField(labelWithString: "焦点屏整屏快捷键")
        displayTitle.frame = NSRect(x: 20, y: 130, width: 160, height: 20)
        content.addSubview(displayTitle)

        displayLabel = NSTextField(labelWithString: "")
        displayLabel.frame = NSRect(x: 180, y: 130, width: 120, height: 20)
        displayLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        content.addSubview(displayLabel)

        let displayBtn = NSButton(title: "改键…", target: self, action: #selector(recordDisplay))
        displayBtn.frame = NSRect(x: 310, y: 126, width: 80, height: 28)
        content.addSubview(displayBtn)

        let reset = NSButton(title: "恢复默认 ⌃⌥⌘S / ⌃⌥⌘A", target: self, action: #selector(resetDefaults))
        reset.frame = NSRect(x: 20, y: 80, width: 260, height: 28)
        content.addSubview(reset)

        warnLabel = NSTextField(wrappingLabelWithString: "不要占用系统 ⌘⇧3 / ⌘⇧4 / ⌘⇧5。改键后立即生效。屏幕录制授权后若仍黑图，请退出并重开 MacTiler。")
        warnLabel.frame = NSRect(x: 20, y: 20, width: 380, height: 50)
        warnLabel.textColor = .secondaryLabelColor
        content.addSubview(warnLabel)

        w.contentView = content
        window = w
    }

    private func refresh() {
        let store = StrategyStore.shared
        saveCheckbox?.state = store.saveScreenshotToDesktop ? .on : .off
        regionLabel?.stringValue = store.screenshotRegionHotKey.displayString
        displayLabel?.stringValue = store.screenshotDisplayHotKey.displayString
    }

    @objc private func toggleSave() {
        StrategyStore.shared.saveScreenshotToDesktop = (saveCheckbox.state == .on)
    }

    @objc private func recordRegion() {
        beginRecording(.region)
    }

    @objc private func recordDisplay() {
        beginRecording(.display)
    }

    @objc private func resetDefaults() {
        StrategyStore.shared.screenshotRegionHotKey = .defaultRegion
        StrategyStore.shared.screenshotDisplayHotKey = .defaultDisplay
        refresh()
        onHotKeysChanged?()
    }

    private func beginRecording(_ target: RecordingTarget) {
        recordingTarget = target
        warnLabel.stringValue = "请按下新的快捷键组合（Esc 取消）…"
        warnLabel.textColor = .systemOrange
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return nil // swallow
        }
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            endRecording(cancelled: true)
            return
        }
        // Require at least one of ⌃⌥⌘ (avoid bare keys + avoid naked ⌘⇧ digit)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if carbon == 0 {
            warnLabel.stringValue = "请加上 ⌃ / ⌥ / ⌘ 修饰键"
            warnLabel.textColor = .systemRed
            return
        }
        var spec = HotKeySpec(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        if spec.looksLikeSystemScreenshotDefault {
            warnLabel.stringValue = "不能占用系统截图键 ⌘⇧3/4/5，请另选"
            warnLabel.textColor = .systemRed
            return
        }
        switch recordingTarget {
        case .region:
            StrategyStore.shared.screenshotRegionHotKey = spec
        case .display:
            StrategyStore.shared.screenshotDisplayHotKey = spec
        case .none:
            break
        }
        endRecording(cancelled: false)
        onHotKeysChanged?()
    }

    private func endRecording(cancelled: Bool) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        recordingTarget = nil
        warnLabel.stringValue = cancelled
            ? "已取消改键。不要占用系统 ⌘⇧3/4/5。授权屏幕录制后若仍黑图请重开 App。"
            : "已更新。屏幕录制授权后若仍黑图，请退出并重开 MacTiler。"
        warnLabel.textColor = .secondaryLabelColor
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        recordingTarget = nil
    }
}
