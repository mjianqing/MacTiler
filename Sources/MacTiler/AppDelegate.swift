import AppKit
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var autoRetileWatcher: AutoRetileWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we stay as agent (also set LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Probe Space once and log degradation clearly.
        _ = SpaceResolver.shared.currentKey()
        if SpaceResolver.shared.degraded {
            NSLog("MacTiler SPACE DEGRADED: \(SpaceResolver.shared.lastProbeNote)")
        } else {
            NSLog("MacTiler SPACE OK: \(SpaceResolver.shared.lastProbeNote)")
        }

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
