import AppKit
import ApplicationServices

final class WindowTiler {
    static let shared = WindowTiler()

    private init() {}

    // MARK: - Coordinate conversion
    // AX kAXPosition uses top-left origin; NSScreen frames use AppKit bottom-left.
    // Convert via primary display (frame.origin == .zero), else NSScreen.main.

    private static var primaryScreen: NSScreen {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func appKitToAX(_ rect: CGRect) -> CGRect {
        let primary = primaryScreen
        let y = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: y, width: rect.width, height: rect.height)
    }

    static func axToAppKit(_ rect: CGRect) -> CGRect {
        let primary = primaryScreen
        let y = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: y, width: rect.width, height: rect.height)
    }

    // MARK: - Retile

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

        let all = collectManageableWindows()
        guard !all.isEmpty else {
            return .info("当前桌面没有可铺窗口")
        }

        let screen = resolveTargetScreen(from: all) ?? NSScreen.main
        guard let screen else {
            return .info("找不到可用屏幕")
        }

        // Only tile windows whose center lies on the target screen (AppKit coords).
        let onScreen = all.filter { windowBelongs(to: screen, frame: $0.frame) }
        guard !onScreen.isEmpty else {
            return .info("焦点屏上没有可铺窗口")
        }

        let ordered = onScreen.sorted { a, b in
            if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
            return false
        }

        let workArea = screen.visibleFrame // AppKit
        let result = LayoutEngine.frames(
            strategy: chosen,
            windowCount: ordered.count,
            workArea: workArea,
            halfOnLeft: store.halfOnLeft
        )

        let toPlace = Array(ordered.prefix(result.frames.count))
        var skipped = 0
        for (win, frame) in zip(toPlace, result.frames) {
            if !setFrame(win.element, appKitFrame: frame) {
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

    /// Focused window's screen → else frontmost window's screen → main.
    private func resolveTargetScreen(from windows: [ManagedWindow]) -> NSScreen? {
        if let focused = windows.first(where: { $0.isFocused }),
           let s = screenContaining(focused.frame) {
            return s
        }
        if let first = windows.first, let s = screenContaining(first.frame) {
            return s
        }
        return NSScreen.main
    }

    private func windowBelongs(to screen: NSScreen, frame: CGRect) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard NSMouseInRect(center, screen.frame, false) else { return false }
        let inter = frame.intersection(screen.frame)
        let area = max(frame.width * frame.height, 1)
        return (inter.width * inter.height) / area >= 0.6
    }

    // MARK: - Collect

    private func collectManageableWindows() -> [ManagedWindow] {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result: [ManagedWindow] = []

        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }

        for app in running {
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windowList = windowsRef as? [AXUIElement] else {
                continue
            }

            for win in windowList {
                guard isStandardWindow(win) else { continue }
                guard let appKitFrame = getAppKitFrame(win) else { continue }
                guard isOnScreen(appKitFrame) else { continue }
                let title = getString(win, kAXTitleAttribute as CFString) ?? ""
                let focused = (app.processIdentifier == frontPid) && isMainOrFocused(win)
                result.append(ManagedWindow(
                    element: win,
                    pid: app.processIdentifier,
                    title: title,
                    frame: appKitFrame,
                    isFocused: focused
                ))
            }
        }
        return result
    }

    private func isStandardWindow(_ win: AXUIElement) -> Bool {
        let role = getString(win, kAXRoleAttribute as CFString)
        guard role == kAXWindowRole else { return false }

        if let sub = getString(win, kAXSubroleAttribute as CFString) {
            if sub == kAXStandardWindowSubrole { return true }
            if sub == kAXDialogSubrole || sub == kAXFloatingWindowSubrole || sub == kAXSystemDialogSubrole {
                return false
            }
        }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let minimized = minRef as? Bool, minimized {
            return false
        }

        guard let frame = getAppKitFrame(win), frame.width > 80, frame.height > 80 else { return false }
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

    private func isOnScreen(_ appKitFrame: CGRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.intersects(appKitFrame.insetBy(dx: 8, dy: 8)) {
                return true
            }
        }
        return false
    }

    private func screenContaining(_ appKitFrame: CGRect) -> NSScreen? {
        let center = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - AX helpers

    private func getString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Read AX frame and convert to AppKit coordinates.
    private func getAppKitFrame(_ win: AXUIElement) -> CGRect? {
        guard let ax = getAXFrame(win) else { return nil }
        return WindowTiler.axToAppKit(ax)
    }

    private func getAXFrame(_ win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    /// `appKitFrame` is in AppKit coords; convert to AX before writing.
    @discardableResult
    private func setFrame(_ win: AXUIElement, appKitFrame: CGRect) -> Bool {
        let axFrame = WindowTiler.appKitToAX(appKitFrame)
        var origin = axFrame.origin
        var size = axFrame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // Size then position then size again — more reliable across apps.
        var s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        var p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)

        return p == .success && s == .success
    }
}
