import AppKit
import ApplicationServices

final class WindowTiler {
    static let shared = WindowTiler()

    /// Max allowed |actualWidth - targetWidth| / workArea.width (acceptance: ≤2%).
    private static let widthTolFraction: CGFloat = 0.02
    /// Adjacent strips may share a ≤1pt seam; anything more is overlap.
    private static let overlapSeam: CGFloat = 1.0

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

        var totalPlaced = 0
        var skipped = 0
        var overflow: Int? = nil
        var screensTouched = 0
        var sawAPIDisabled = false
        var clampCompromised = false
        var hardFailReason: String? = nil

        var skippedNonResizable = 0

        for screen in NSScreen.screens {
            let onScreen = all.filter { windowBelongs(to: screen, frame: $0.frame) }
            guard !onScreen.isEmpty else { continue }
            screensTouched += 1

            let ordered = onScreen.sorted { a, b in
                if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
                return false
            }

            let workArea = screen.visibleFrame

            // P1: drop fully non-resizable windows before slotting — avoid misleading half-layouts.
            var candidates: [ManagedWindow] = []
            for w in ordered {
                if isFullyNonResizable(w, workArea: workArea) {
                    skippedNonResizable += 1
                    skipped += 1
                    TilerLog.info("nonResizable skip title=\(w.title.prefix(24)) screen=\(screen.localizedName)")
                } else {
                    candidates.append(w)
                }
            }
            guard !candidates.isEmpty else {
                TilerLog.info("screen=\(screen.localizedName) all windows non-resizable; skip screen")
                continue
            }

            let result = LayoutEngine.frames(
                strategy: chosen,
                windowCount: candidates.count,
                workArea: workArea
            )
            if let max = result.overflowHint {
                overflow = max
            }

            let toPlace = Array(candidates.prefix(result.frames.count))
            let targets = result.frames
            TilerLog.info("screen=\(screen.localizedName) visible=\(workArea) windows=\(onScreen.count) candidates=\(candidates.count) placing=\(toPlace.count) targets=\(targets.map { "w=\(Int($0.width))" })")

            let screenResult = tileScreenRespectingMins(
                windows: toPlace,
                targets: targets,
                workArea: workArea
            )
            if screenResult.apiDisabled { sawAPIDisabled = true }
            totalPlaced += screenResult.placed
            skipped += screenResult.skipped
            if screenResult.clampCompromised { clampCompromised = true }
            if let reason = screenResult.failReason {
                hardFailReason = reason
            }
        }

        if screensTouched == 0 {
            return .info("没有可铺窗口落在任何屏幕上")
        }
        if sawAPIDisabled {
            TilerLog.error("AX APIDisabled — TCC grant stale for this CDHash; toggle Accessibility for MacTiler")
            return .needAccessibility
        }
        if let reason = hardFailReason {
            return .info(reason)
        }
        if clampCompromised {
            // Visible, honest outcome — not silent "已重排 N 窗"
            return .info("部分窗口有最小尺寸，已尽量排布")
        }
        if totalPlaced == 0 && skipped > 0 {
            if skippedNonResizable > 0 {
                return .info("窗口无法调整尺寸，已跳过（未留下半布局）")
            }
            return .unsupportedWindow
        }
        if let max = overflow {
            return .tooManyWindows(max: max)
        }
        if skippedNonResizable > 0 {
            return .info("已重排 \(totalPlaced) 窗（跳过 \(skippedNonResizable) 个无法缩放）")
        }
        if skipped > 0 {
            return .info("已重排 \(totalPlaced) 窗（跳过 \(skipped)）")
        }
        return .retiled(count: totalPlaced)
    }

    private struct ScreenTileResult {
        var placed: Int
        var skipped: Int
        var apiDisabled: Bool
        var clampCompromised: Bool
        var failReason: String?
    }

    /// Place strips L→R. If a window is clamped by its min width, keep that width and
    /// redistribute the remaining work-area among unclamped strips (same relative fractions).
    /// Never report success while frames still overlap.
    private func tileScreenRespectingMins(
        windows: [ManagedWindow],
        targets: [CGRect],
        workArea: CGRect
    ) -> ScreenTileResult {
        var result = ScreenTileResult(placed: 0, skipped: 0, apiDisabled: false, clampCompromised: false, failReason: nil)
        guard !windows.isEmpty, windows.count == targets.count else {
            result.failReason = "布局内部错误：窗数与目标不一致"
            return result
        }

        let n = windows.count
        let tol = max(2, workArea.width * Self.widthTolFraction)
        var desired = targets.map { $0.width }
        var clamped = Array(repeating: false, count: n)
        var actualWidths = Array(repeating: CGFloat(0), count: n)

        // Pass 1: apply ideal targets, detect clamps (actualW > targetW).
        for i in 0..<n {
            let frame = CGRect(x: targets[i].minX, y: workArea.minY, width: desired[i], height: workArea.height)
            let outcome = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title, workAreaWidth: workArea.width)
            if outcome.apiDisabled { result.apiDisabled = true }
            let after = getAppKitFrame(windows[i].element) ?? frame
            actualWidths[i] = after.width
            if after.width > desired[i] + tol {
                clamped[i] = true
                desired[i] = after.width // locked to measured min (clamped size)
                TilerLog.info("clamped title=\(windows[i].title.prefix(24)) targetW=\(Int(targets[i].width)) actualW=\(Int(after.width))")
            }
            if outcome.ok || clamped[i] {
                result.placed += 1
            } else {
                result.skipped += 1
            }
        }

        // Redistribute if any clamp: fixed widths for clamped; remaining split by original fractions among free.
        if clamped.contains(true) {
            result.clampCompromised = true
            let fixedSum = zip(clamped, desired).reduce(CGFloat(0)) { $0 + ($1.0 ? $1.1 : 0) }
            let freeIdx = clamped.indices.filter { !clamped[$0] }
            let remain = workArea.width - fixedSum

            if remain < CGFloat(freeIdx.count) * 80 {
                // Not enough room for free windows — degrade: keep clamped, drop trailing free, or fail visibly.
                TilerLog.error("remain=\(remain) too small for \(freeIdx.count) free strips; degrading")
                // Try packing only windows that fit L→R by measured mins / targets.
                let pack = packFitting(windows: windows, minWidths: desired, workArea: workArea)
                result.placed = pack.placed
                result.skipped = n - pack.placed
                if pack.overlap {
                    result.failReason = "部分窗口最小尺寸过大，无法无重叠排布"
                } else {
                    result.clampCompromised = true
                }
                return result
            }

            let origFree = freeIdx.map { targets[$0].width }
            let origFreeSum = max(origFree.reduce(0, +), 1)
            var newDesired = desired
            for (k, idx) in freeIdx.enumerated() {
                let isLastFree = (k == freeIdx.count - 1)
                if isLastFree {
                    // leftover assigned below after flooring others
                    newDesired[idx] = 0
                } else {
                    newDesired[idx] = max(1, floor(remain * (origFree[k] / origFreeSum)))
                }
            }
            if let last = freeIdx.last {
                let used = freeIdx.dropLast().reduce(CGFloat(0)) { $0 + newDesired[$1] }
                newDesired[last] = max(1, floor(remain - used))
            }
            desired = newDesired
            TilerLog.info("redistribute after clamp desired=\(desired.map { Int($0) }) clamped=\(clamped)")

            // Pass 2: lay out L→R with new desired widths.
            var x = floor(workArea.minX)
            let maxX = floor(workArea.maxX)
            for i in 0..<n {
                let w: CGFloat
                if i == n - 1 {
                    w = max(1, maxX - x)
                } else {
                    w = max(1, floor(desired[i]))
                }
                let frame = CGRect(x: x, y: workArea.minY, width: w, height: workArea.height)
                let outcome = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/redist", workAreaWidth: workArea.width)
                if outcome.apiDisabled { result.apiDisabled = true }
                let after = getAppKitFrame(windows[i].element) ?? frame
                actualWidths[i] = after.width
                // If still clamped wider, lock and we'll pack by actual below.
                if after.width > w + tol {
                    clamped[i] = true
                    result.clampCompromised = true
                }
                // Advance by actual, never past workArea right edge.
                if abs(after.width - w) <= tol {
                    x = min(maxX, frame.maxX)
                } else {
                    x = min(maxX, floor(after.maxX))
                }
            }
        }

        // Final verify: re-read, fix residual overlap by L→R pack on actual widths, then check.
        usleep(40_000)
        var frames = windows.compactMap { getAppKitFrame($0.element) }
        if frames.count != n {
            result.failReason = "布局未对齐：无法读回窗口 frame"
            return result
        }

        if hasOverlap(frames) || exceedsWorkArea(frames, workArea) {
            TilerLog.info("overlap/overflow after place — packing by actual widths L→R clamped to workArea")
            var x = floor(workArea.minX)
            let maxX = floor(workArea.maxX)
            for i in 0..<n {
                guard var actual = getAppKitFrame(windows[i].element) else { continue }
                let remain = maxX - x
                if remain < 1 {
                    TilerLog.info("pack stop at i=\(i) no remain")
                    break
                }
                // P1: never plan past right edge — w = min(actualW, workArea.maxX - x)
                let w = min(max(1, floor(actual.width)), remain)
                let frame = CGRect(x: x, y: workArea.minY, width: w, height: workArea.height)
                _ = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/pack", workAreaWidth: workArea.width)
                actual = getAppKitFrame(windows[i].element) ?? frame
                // If min-width still overflows, pin right edge (may overlap → fail visibly below)
                if floor(actual.maxX) > maxX + 1 {
                    let pinnedX = max(floor(workArea.minX), maxX - floor(actual.width))
                    let pinned = CGRect(x: pinnedX, y: workArea.minY, width: floor(actual.width), height: workArea.height)
                    _ = setFrame(windows[i].element, appKitFrame: pinned, title: windows[i].title + "/pack-pin", workAreaWidth: workArea.width)
                    actual = getAppKitFrame(windows[i].element) ?? pinned
                }
                x = min(maxX, floor(actual.maxX))
                result.clampCompromised = true
            }
            usleep(40_000)
            frames = windows.compactMap { getAppKitFrame($0.element) }
        }

        if frames.count == n, hasOverlap(frames) || exceedsWorkArea(frames, workArea) {
            result.failReason = "部分窗口最小尺寸过大，无法无重叠排布"
            TilerLog.error("overlap/overflow remains frames=\(frames.map { "x=\(Int($0.minX))w=\(Int($0.width))" }) workMaxX=\(Int(workArea.maxX))")
            return result
        }

        // Proportion check vs original targets — only required when nothing was clamped.
        if !result.clampCompromised {
            for (i, f) in frames.enumerated() where i < targets.count {
                if abs(f.width - targets[i].width) > tol {
                    result.clampCompromised = true
                    TilerLog.info("proportion soft-miss title=\(windows[i].title.prefix(24)) target=\(Int(targets[i].width)) actual=\(Int(f.width))")
                }
            }
        }

        TilerLog.info("screen done clamped=\(result.clampCompromised) frames=\(frames.map { "x=\(Int($0.minX))w=\(Int($0.width))" })")
        return result
    }

    private func hasOverlap(_ frames: [CGRect]) -> Bool {
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let inter = frames[i].intersection(frames[j])
                guard !inter.isNull, !inter.isEmpty else { continue }
                if inter.width > Self.overlapSeam && inter.height > Self.overlapSeam {
                    return true
                }
            }
        }
        return false
    }

    /// True if any frame extends past the work-area right (or left) edge by >1pt.
    private func exceedsWorkArea(_ frames: [CGRect], _ workArea: CGRect) -> Bool {
        let maxX = floor(workArea.maxX)
        let minX = floor(workArea.minX)
        return frames.contains { floor($0.maxX) > maxX + 1 || floor($0.minX) < minX - 1 }
    }

    /// Probe: write a clearly different width; if width barely moves and stays far from target → fixed-size.
    private func isFullyNonResizable(_ win: ManagedWindow, workArea: CGRect) -> Bool {
        guard let before = getAppKitFrame(win.element) else { return false }
        let tol = max(2, workArea.width * Self.widthTolFraction)
        var probeW = floor(workArea.width * 0.5)
        if abs(probeW - before.width) <= tol {
            probeW = floor(min(workArea.width - 1, max(100, before.width + max(80, workArea.width * 0.1))))
        }
        if abs(probeW - before.width) <= tol {
            probeW = floor(max(100, before.width * 0.5))
        }
        if abs(probeW - before.width) <= 2 {
            return false // cannot construct a distinct probe
        }
        let probe = CGRect(
            x: floor(before.origin.x),
            y: workArea.minY,
            width: max(1, probeW),
            height: workArea.height
        )
        _ = setFrame(win.element, appKitFrame: probe, title: win.title + "/probe", workAreaWidth: workArea.width)
        let after = getAppKitFrame(win.element) ?? before
        let unchanged = abs(after.width - before.width) <= 2
        let missed = abs(after.width - probeW) > tol
        if unchanged && missed {
            TilerLog.info("nonResizable title=\(win.title.prefix(24)) beforeW=\(Int(before.width)) probeW=\(Int(probeW)) afterW=\(Int(after.width))")
            return true
        }
        return false
    }

    /// Degrade: place as many as fit L→R without overlap given measured min widths.
    /// Each strip width is clamped so maxX ≤ workArea.maxX.
    private func packFitting(
        windows: [ManagedWindow],
        minWidths: [CGFloat],
        workArea: CGRect
    ) -> (placed: Int, overlap: Bool) {
        var x = floor(workArea.minX)
        let maxX = floor(workArea.maxX)
        var placed = 0
        for i in 0..<windows.count {
            let need = max(1, floor(minWidths[i]))
            let remain = maxX - x
            if remain < 1 { break }
            if need > remain + 1 && i > 0 {
                TilerLog.info("packFitting stop at i=\(i) need=\(need) remain=\(remain)")
                break
            }
            let w = min(need, remain) // P1: never past right edge
            let frame = CGRect(x: x, y: workArea.minY, width: max(1, w), height: workArea.height)
            _ = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/fit", workAreaWidth: workArea.width)
            var after = getAppKitFrame(windows[i].element) ?? frame
            if floor(after.maxX) > maxX + 1 {
                let pinnedX = max(floor(workArea.minX), maxX - floor(after.width))
                let pinned = CGRect(x: pinnedX, y: workArea.minY, width: floor(after.width), height: workArea.height)
                _ = setFrame(windows[i].element, appKitFrame: pinned, title: windows[i].title + "/fit-pin", workAreaWidth: workArea.width)
                after = getAppKitFrame(windows[i].element) ?? pinned
            }
            x = min(maxX, floor(after.maxX))
            placed += 1
            if x >= maxX - 1 { break }
        }
        usleep(40_000)
        let frames = Array(windows.prefix(placed).compactMap { getAppKitFrame($0.element) })
        let bad = hasOverlap(frames) || exceedsWorkArea(frames, workArea)
        return (placed, bad)
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

    /// Apply AX size/position. Pass 1: size→pos→size→pos; if still off, pass 2: pos→size→pos.
    /// Success requires position+width within tolerance (no longer treat "moved" alone as OK).
    @discardableResult
    private func setFrame(
        _ win: AXUIElement,
        appKitFrame: CGRect,
        title: String = "",
        workAreaWidth: CGFloat = 0
    ) -> SetFrameOutcome {
        let axFrame = WindowTiler.appKitToAX(appKitFrame)
        var origin = axFrame.origin
        var size = axFrame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            TilerLog.error("setFrame AXValueCreate failed title=\(title)")
            return SetFrameOutcome(ok: false, apiDisabled: false)
        }

        func apply(order: String) -> (p: AXError, s: AXError) {
            var p: AXError = .failure
            var s: AXError = .failure
            if order == "size-first" {
                s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
                p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
                s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
                p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            } else {
                // position → size → position
                p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
                s = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
                p = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            }
            return (p, s)
        }

        var result = apply(order: "size-first")
        var apiDisabled = (result.p == .apiDisabled || result.s == .apiDisabled)
        if apiDisabled {
            TilerLog.error("setFrame APIDisabled title=\(title.prefix(32)) p=\(result.p.rawValue) s=\(result.s.rawValue)")
            return SetFrameOutcome(ok: false, apiDisabled: true)
        }

        usleep(30_000)
        var after = getAppKitFrame(win)
        let tolW = max(2, (workAreaWidth > 0 ? workAreaWidth : max(appKitFrame.width, 1)) * Self.widthTolFraction)
        let tolX: CGFloat = 2

        func closeEnough(_ a: CGRect) -> Bool {
            abs(a.origin.x - appKitFrame.origin.x) <= tolX
                && abs(a.width - appKitFrame.width) <= tolW
                && abs(a.height - appKitFrame.height) <= max(8, tolW * 2)
        }

        if let a = after, !closeEnough(a) {
            TilerLog.info("setFrame retry pos→size→pos title=\(title.prefix(32)) after1=\(a) target=\(appKitFrame) p=\(result.p.rawValue) s=\(result.s.rawValue)")
            result = apply(order: "pos-first")
            apiDisabled = (result.p == .apiDisabled || result.s == .apiDisabled)
            if apiDisabled {
                return SetFrameOutcome(ok: false, apiDisabled: true)
            }
            usleep(30_000)
            after = getAppKitFrame(win)
        }

        if let a = after {
            let ok = closeEnough(a)
            if ok {
                TilerLog.info("setFrame OK title=\(title.prefix(32)) target=\(appKitFrame) after=\(a) p=\(result.p.rawValue) s=\(result.s.rawValue)")
            } else {
                TilerLog.error("setFrame MISS title=\(title.prefix(32)) target=\(appKitFrame) after=\(a) dx=\(a.origin.x - appKitFrame.origin.x) dw=\(a.width - appKitFrame.width) p=\(result.p.rawValue) s=\(result.s.rawValue)")
            }
            return SetFrameOutcome(ok: ok, apiDisabled: false)
        }

        // No re-read — trust AX write status only.
        let ok = (result.p == .success && result.s == .success)
        if ok {
            TilerLog.info("setFrame OK (no re-read) title=\(title.prefix(32)) p=\(result.p.rawValue) s=\(result.s.rawValue)")
        } else {
            TilerLog.error("setFrame FAIL title=\(title.prefix(32)) target=\(appKitFrame) ax=\(axFrame) p=\(result.p.rawValue) s=\(result.s.rawValue)")
        }
        return SetFrameOutcome(ok: ok, apiDisabled: false)
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
