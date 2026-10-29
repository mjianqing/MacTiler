import AppKit
import ApplicationServices

final class WindowTiler {
    static let shared = WindowTiler()

    private init() {}

    @discardableResult
    func retile(strategy: StrategyID? = nil) -> TilerMessage {
        guard AccessibilityPermission.isTrusted(prompt: false) else {
            return .needAccessibility
        }
        let store = StrategyStore.shared
        if store.isPaused {
            return .paused
        }

        let chosen = strategy ?? store.currentStrategy
        if let strategy {
            store.setStrategy(strategy)
        }

        let windows = collectManageableWindows()
        guard !windows.isEmpty else {
            return .info("当前桌面没有可铺窗口")
        }

        // Order: focused first (main slot), then others front-to-back as listed.
        let ordered = windows.sorted { a, b in
            if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
            return false
        }

        let focusScreen = screenForFocusedWindow(ordered) ?? NSScreen.main
        guard let screen = focusScreen else {
            return .info("找不到可用屏幕")
        }
        let workArea = screen.visibleFrame

        let result = LayoutEngine.frames(
            strategy: chosen,
            windowCount: ordered.count,
            workArea: workArea,
            halfOnLeft: store.halfOnLeft
        )

        let toPlace = Array(ordered.prefix(result.frames.count))
        var skipped = 0
        for (win, frame) in zip(toPlace, result.frames) {
            if !setFrame(win.element, frame: frame) {
                skipped += 1
            }
        }

        if let max = result.overflowHint {
            return .tooManyWindows(max: max)
        }
        if skipped > 0 {
            return .unsupportedWindow
        }
        return .none
    }

    // MARK: - Collect

    private func collectManageableWindows() -> [ManagedWindow] {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result: [ManagedWindow] = []

        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }

        for app in running {
            // Skip ourselves
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windowList = windowsRef as? [AXUIElement] else {
                continue
            }

            for win in windowList {
                guard isStandardWindow(win) else { continue }
                guard let frame = getFrame(win) else { continue }
                // Only windows on currently visible displays (visible Space).
                guard isOnScreen(frame) else { continue }
                let title = getString(win, kAXTitleAttribute as CFString) ?? ""
                let focused = (app.processIdentifier == frontPid) && isMainOrFocused(win)
                result.append(ManagedWindow(
                    element: win,
                    pid: app.processIdentifier,
                    title: title,
                    frame: frame,
                    isFocused: focused
                ))
            }
        }
        return result
    }

    private func isStandardWindow(_ win: AXUIElement) -> Bool {
        // Must be subrole AXStandardWindow or role AXWindow without sheet/dialog heuristics.
        let role = getString(win, kAXRoleAttribute as CFString)
        guard role == kAXWindowRole else { return false }

        if let sub = getString(win, kAXSubroleAttribute as CFString) {
            if sub == kAXStandardWindowSubrole { return true }
            // Dialogs / floating panels: skip
            if sub == kAXDialogSubrole || sub == kAXFloatingWindowSubrole || sub == kAXSystemDialogSubrole {
                return false
            }
        }

        // Minimized?
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let minimized = minRef as? Bool, minimized {
            return false
        }

        // Size sanity
        guard let frame = getFrame(win), frame.width > 80, frame.height > 80 else { return false }
        return true
    }

    private func isMainOrFocused(_ win: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMainAttribute as CFString, &ref) == .success,
           let main = ref as? Bool, main {
            return true
        }
        ref = nil
        if AXUIElementCopyAttributeValue(win, kAXFocusedAttribute as CFString, &ref) == .success,
           let focused = ref as? Bool, focused {
            return true
        }
        return false
    }

    private func isOnScreen(_ frame: CGRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.intersects(frame.insetBy(dx: 8, dy: 8)) {
                return true
            }
        }
        return false
    }

    private func screenForFocusedWindow(_ windows: [ManagedWindow]) -> NSScreen? {
        if let focused = windows.first(where: { $0.isFocused }) {
            return screenContaining(focused.frame)
        }
        if let first = windows.first {
            return screenContaining(first.frame)
        }
        return NSScreen.main
    }

    private func screenContaining(_ frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - AX helpers

    private func getString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func getFrame(_ win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    private func setFrame(_ win: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            return false
        }
        let p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        let s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        // Some apps need size then position or vice versa — retry once swapped.
        if p != .success || s != .success {
            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
            _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        }
        return true
    }
}
