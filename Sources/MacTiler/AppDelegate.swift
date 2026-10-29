import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var autoRetileWatcher: AutoRetileWatcher?
    private var dragSwapMonitor: DragSwapMonitor?
    var smokeRetileAndQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            TilerLog.info("UN authorization granted=\(granted) err=\(String(describing: err))")
        }

        TilerLog.info("launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") path=\(Bundle.main.bundlePath) trusted=\(AccessibilityPermission.isTrusted(prompt: false)) smoke=\(smokeRetileAndQuit)")

        menuBar = MenuBarController()
        autoRetileWatcher = AutoRetileWatcher()
        autoRetileWatcher?.start()
        dragSwapMonitor = DragSwapMonitor()
        dragSwapMonitor?.start()

        if !AccessibilityPermission.isTrusted(prompt: true) {
            AccessibilityPermission.openSystemSettings()
        }

        if smokeRetileAndQuit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let msg = WindowTiler.shared.retile()
                TilerLog.info("smoke-retile result=\(msg)")
                // Give log queue a moment to flush
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoRetileWatcher?.stop()
        dragSwapMonitor?.stop()
        TilerLog.info("terminate")
    }
}

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
            // Auto-retile stays quiet on success to avoid notification spam;
            // failures still log via WindowTiler.
            _ = WindowTiler.shared.retile()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}
