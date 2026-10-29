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
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        TilerLog.info("retile begin trusted=\(trusted) paused=\(StrategyStore.shared.isPaused) strategy=\((strategy ?? StrategyStore.shared.currentStrategy).rawValue) screens=\(NSScreen.screens.count)")

        guard trusted else {
            TilerLog.error("retile aborted: AX not trusted")
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
        TilerLog.info("collectManageableWindows count=\(all.count): " + all.map { "[\($0.title.prefix(24))@\(Int($0.frame.midX)),\(Int($0.frame.midY)) foc=\($0.isFocused)]" }.joined(separator: " "))
        guard !all.isEmpty else {
            return .info("当前桌面没有可铺窗口")
        }

        // Tile every screen that has manageable windows (dual-monitor safe).
        // Previously only "focus screen" — clicking the menu bar often left focus on the
        // laptop while the user stared at the external display → apparent no-op.
        var totalPlaced = 0
        var skipped = 0
        var overflow: Int? = nil
        var screensTouched = 0
        var sawAPIDisabled = false

        for screen in NSScreen.screens {
            let onScreen = all.filter { windowBelongs(to: screen, frame: $0.frame) }
            guard !onScreen.isEmpty else { continue }
            screensTouched += 1

            let ordered = onScreen.sorted { a, b in
                if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
                return false
            }

            let workArea = screen.visibleFrame
            let result = LayoutEngine.frames(
                strategy: chosen,
                windowCount: ordered.count,
                workArea: workArea
            )
            if let max = result.overflowHint {
                overflow = max
            }

            let toPlace = Array(ordered.prefix(result.frames.count))
            TilerLog.info("screen=\(screen.localizedName) visible=\(workArea) windows=\(onScreen.count) placing=\(toPlace.count)")

            for (win, frame) in zip(toPlace, result.frames) {
                let outcome = setFrame(win.element, appKitFrame: frame, title: win.title)
                if outcome.apiDisabled { sawAPIDisabled = true }
                if outcome.ok {
                    totalPlaced += 1
                } else {
                    skipped += 1
                }
            }
        }

        if screensTouched == 0 {
            return .info("没有可铺窗口落在任何屏幕上")
        }
        if sawAPIDisabled {
            TilerLog.error("AX APIDisabled — TCC grant stale for this CDHash; toggle Accessibility for MacTiler")
            return .needAccessibility
        }
        if totalPlaced == 0 && skipped > 0 {
            return .unsupportedWindow
        }
        if let max = overflow {
            return .tooManyWindows(max: max)
        }
        if skipped > 0 {
            return .info("已重排 \(totalPlaced) 窗（跳过 \(skipped)）")
        }
        return .retiled(count: totalPlaced)
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
            let copyErr = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
            guard copyErr == .success, let windowList = windowsRef as? [AXUIElement] else {
                if copyErr == .apiDisabled {
                    TilerLog.error("kAXWindows APIDisabled for \(app.localizedName ?? "?") pid=\(app.processIdentifier)")
                }
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
                    title: title.isEmpty ? (app.localizedName ?? "?") : title,
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

    private struct SetFrameOutcome {
        let ok: Bool
        let apiDisabled: Bool
    }

    /// `appKitFrame` is in AppKit coords; convert to AX before writing.
    @discardableResult
    private func setFrame(_ win: AXUIElement, appKitFrame: CGRect, title: String = "") -> SetFrameOutcome {
        let axFrame = WindowTiler.appKitToAX(appKitFrame)
        var origin = axFrame.origin
        var size = axFrame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            TilerLog.error("setFrame AXValueCreate failed title=\(title)")
            return SetFrameOutcome(ok: false, apiDisabled: false)
        }

        // Size then position then size again — more reliable across apps.
        var s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        var p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)

        let apiDisabled = (p == .apiDisabled || s == .apiDisabled)
        let ok = (p == .success && s == .success)

        if ok {
            // Verify — some apps return success but ignore the write.
            usleep(30_000)
            if let after = getAppKitFrame(win) {
                let moved = hypot(after.midX - appKitFrame.midX, after.midY - appKitFrame.midY) > 8
                    || abs(after.width - appKitFrame.width) > 8
                    || abs(after.height - appKitFrame.height) > 8
                // "Close enough" if within 40pt (title bar / traffic lights)
                let close = abs(after.origin.x - appKitFrame.origin.x) < 40
                    && abs(after.width - appKitFrame.width) < 40
                    && abs(after.height - appKitFrame.height) < 80
                TilerLog.info("setFrame OK title=\(title.prefix(32)) target=\(appKitFrame) after=\(after) close=\(close) moved=\(moved) p=\(p.rawValue) s=\(s.rawValue)")
                return SetFrameOutcome(ok: close || moved, apiDisabled: false)
            }
            TilerLog.info("setFrame OK (no re-read) title=\(title.prefix(32)) p=\(p.rawValue) s=\(s.rawValue)")
            return SetFrameOutcome(ok: true, apiDisabled: false)
        }

        TilerLog.error("setFrame FAIL title=\(title.prefix(32)) target=\(appKitFrame) ax=\(axFrame) p=\(p.rawValue) s=\(s.rawValue) apiDisabled=\(apiDisabled)")
        return SetFrameOutcome(ok: false, apiDisabled: apiDisabled)
    }

    // MARK: - Drag swap

    /// Snapshot of manageable windows (AppKit frames).
    func listManageableWindows() -> [ManagedWindow] {
        collectManageableWindows()
    }

    /// Swap position+size of two windows (AppKit frames → AX).
    @discardableResult
    func swapFrames(a: AXUIElement, b: AXUIElement) -> Bool {
        guard let frameA = getAppKitFrame(a), let frameB = getAppKitFrame(b) else { return false }
        let okB = setFrame(b, appKitFrame: frameA, title: "swap-B").ok
        let okA = setFrame(a, appKitFrame: frameB, title: "swap-A").ok
        return okA && okB
    }

    func appKitFrame(of win: AXUIElement) -> CGRect? {
        getAppKitFrame(win)
    }
}
