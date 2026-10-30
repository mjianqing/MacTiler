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

        TilerLog.info("launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") path=\(Bundle.main.bundlePath) trusted=\(AccessibilityPermission.isTrusted()) smoke=\(smokeRetileAndQuit)")

        menuBar = MenuBarController()
        autoRetileWatcher = AutoRetileWatcher()
        autoRetileWatcher?.start()
        dragSwapMonitor = DragSwapMonitor()
        dragSwapMonitor?.start()

        // Silent check only. Tip ≤1× per CDHash/24h; never prompt:true on launch.
        // Same Team + /Applications cover should keep AX; ad-hoc CDHash change still needs re-grant.
        _ = AccessibilityPermission.nagOnLaunchIfNeeded()
        TilerLog.info("AX sign=\(AccessibilityPermission.signingSummary())")

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
        guard AccessibilityPermission.isTrusted() else { return }
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
