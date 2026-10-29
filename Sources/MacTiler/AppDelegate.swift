import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var autoRetileWatcher: AutoRetileWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // PRD v1.1: no per-Space / profile memory — only current strategy.
        NSLog("MacTiler: MVP does not remember strategies per desktop (Anna 2026-10-29)")

        menuBar = MenuBarController()
        autoRetileWatcher = AutoRetileWatcher()
        autoRetileWatcher?.start()

        if !AccessibilityPermission.isTrusted(prompt: true) {
            AccessibilityPermission.openSystemSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoRetileWatcher?.stop()
    }
}

/// Lightweight auto-retile: when enabled, retile shortly after app activation / screen param changes.
final class AutoRetileWatcher {
    private var tokens: [NSObjectProtocol] = []
    private var workItem: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule()
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule()
        })
    }

    func stop() {
        workItem?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for t in tokens {
            center.removeObserver(t)
            NotificationCenter.default.removeObserver(t)
        }
        tokens.removeAll()
    }

    private func schedule() {
        guard StrategyStore.shared.autoRetile, !StrategyStore.shared.isPaused else { return }
        guard AccessibilityPermission.isTrusted(prompt: false) else { return }
        workItem?.cancel()
        let item = DispatchWorkItem {
            _ = WindowTiler.shared.retile()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}
