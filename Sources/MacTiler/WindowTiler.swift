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
        let trusted = AccessibilityPermission.isTrusted()
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
        var sawAPIDisabled = false
        var clampCompromised = false
        var hardFailReason: String? = nil

        var skippedNonResizable = 0

        // BRIEF/PRD: retile only the focus screen (focused window → mouse → main).
        // Other screens stay untouched; each screen is independent when it becomes focus.
        guard let screen = resolveFocusScreen(from: all) else {
            return .info("没有可铺窗口落在焦点屏上")
        }
        let onScreen = all.filter { windowBelongs(to: screen, frame: $0.frame) }
        guard !onScreen.isEmpty else {
            return .info("没有可铺窗口落在焦点屏上")
        }

        // Focused first, then stable L→R (minX), then top→bottom — never shuffle slots.
        let ordered = onScreen.sorted { a, b in
            if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
            if abs(a.frame.minX - b.frame.minX) > 1 { return a.frame.minX < b.frame.minX }
            return a.frame.minY > b.frame.minY
        }

        let workArea = screen.visibleFrame

        // Drop fully non-resizable windows before slotting — avoid misleading half-layouts.
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
            TilerLog.info("screen=\(screen.localizedName) all windows non-resizable; skip")
            return .info("窗口无法调整尺寸，已跳过（未留下半布局）")
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
        TilerLog.info("focusScreen=\(screen.localizedName) visible=\(workArea) windows=\(onScreen.count) candidates=\(candidates.count) placing=\(toPlace.count) targets=\(targets.map { "w=\(Int($0.width))" })")

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
    /// For equal-fraction full-span layouts (two-halves), retry exact targets before accepting
    /// unequal redistrib — hand-drag proves equal half is often reachable despite a first miss.
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

        let targetsSpanFull = abs(targets.reduce(CGFloat(0)) { $0 + $1.width } - workArea.width) <= 2
        let equalTargets = n >= 2 && targets.allSatisfy { abs($0.width - targets[0].width) <= 2 } && targetsSpanFull

        // Pass 1: apply ideal targets.
        for i in 0..<n {
            let frame = CGRect(x: targets[i].minX, y: workArea.minY, width: desired[i], height: workArea.height)
            TilerLog.info(
                "place target title=\(windows[i].title.prefix(24)) frame=\(Int(frame.minX)),\(Int(frame.minY)) "
                + "\(Int(frame.width))x\(Int(frame.height)) workArea=\(Int(workArea.minX)),w=\(Int(workArea.width))"
            )
            let outcome = setFrame(
                windows[i].element,
                appKitFrame: frame,
                title: windows[i].title,
                workAreaWidth: workArea.width,
                workArea: workArea
            )
            if outcome.apiDisabled { result.apiDisabled = true }
            let after = getAppKitFrame(windows[i].element) ?? frame
            actualWidths[i] = after.width
            let minSize = axMinSize(windows[i].element)
            if after.width > desired[i] + tol {
                TilerLog.info(
                    "soft-wide title=\(windows[i].title.prefix(24)) targetW=\(Int(targets[i].width)) "
                    + "actualW=\(Int(after.width)) minSize=\(minSize.map { Int($0.width) }.map(String.init) ?? "n/a")"
                )
            }
            if outcome.ok {
                result.placed += 1
            } else if after.width > desired[i] + tol {
                // tentatively count as placed; equal-fill retry may still fix
                result.placed += 1
            } else {
                result.skipped += 1
            }
        }

        // Equal-fill retry: re-apply exact targets R→L then L→R before locking any clamp.
        // Avoids false "min-size" redistrib when Electron rejects the first combined move+shrink.
        if equalTargets {
            var drifted = false
            for i in 0..<n {
                let f = getAppKitFrame(windows[i].element)
                if let f, abs(f.width - targets[i].width) > tol || abs(f.minX - targets[i].minX) > 2 {
                    drifted = true
                }
                if f == nil { drifted = true }
            }
            if drifted {
                TilerLog.info("equal-fill retry (R→L then L→R) workAreaW=\(Int(workArea.width)) half=\(Int(targets[0].width))")
                for i in (0..<n).reversed() {
                    let frame = CGRect(x: targets[i].minX, y: workArea.minY, width: targets[i].width, height: workArea.height)
                    _ = setFrame(
                        windows[i].element,
                        appKitFrame: frame,
                        title: windows[i].title + "/eq-rl",
                        workAreaWidth: workArea.width,
                        workArea: workArea
                    )
                }
                for i in 0..<n {
                    let frame = CGRect(x: targets[i].minX, y: workArea.minY, width: targets[i].width, height: workArea.height)
                    _ = setFrame(
                        windows[i].element,
                        appKitFrame: frame,
                        title: windows[i].title + "/eq-lr",
                        workAreaWidth: workArea.width,
                        workArea: workArea
                    )
                }
                usleep(50_000)
                for i in 0..<n {
                    let after = getAppKitFrame(windows[i].element)
                    actualWidths[i] = after?.width ?? actualWidths[i]
                    TilerLog.info(
                        "equal-fill after title=\(windows[i].title.prefix(24)) "
                        + "targetW=\(Int(targets[i].width)) actualW=\(Int(actualWidths[i])) "
                        + "x=\(after.map { Int($0.minX) }.map(String.init) ?? "?")"
                    )
                }
            }
        }

        // Hard clamp only after retries, and only when still wider than target.
        for i in 0..<n {
            if actualWidths[i] > desired[i] + tol {
                let minSize = axMinSize(windows[i].element)
                let minW = minSize?.width ?? 0
                // Anna: do not blame min-size unless logs prove min > half.
                if minW > desired[i] + tol {
                    clamped[i] = true
                    desired[i] = actualWidths[i]
                    TilerLog.info(
                        "clamped(minSize) title=\(windows[i].title.prefix(24)) targetW=\(Int(targets[i].width)) "
                        + "actualW=\(Int(actualWidths[i])) axMinW=\(Int(minW))"
                    )
                } else {
                    // Still too wide with no proven AX min — lock measured width only as last resort
                    // so redistrib can keep full span without overlap; message stays honest.
                    clamped[i] = true
                    desired[i] = actualWidths[i]
                    TilerLog.info(
                        "clamped(refused) title=\(windows[i].title.prefix(24)) targetW=\(Int(targets[i].width)) "
                        + "actualW=\(Int(actualWidths[i])) axMinW=\(minSize.map { Int($0.width) }.map(String.init) ?? "n/a") "
                        + "— equal-fill retry still wide"
                    )
                }
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
            // Only eat remainder to workArea.maxX when targets already span the full
            // workArea (all strategy slots filled). Otherwise keep empty slots empty —
            // never inflate the last placed window into unused strip space.
            var x = floor(workArea.minX)
            let maxX = floor(workArea.maxX)
            for i in 0..<n {
                let remainW = max(1, maxX - x)
                let w: CGFloat
                if targetsSpanFull && i == n - 1 {
                    w = remainW
                } else {
                    w = max(1, min(floor(desired[i]), remainW))
                }
                let frame = CGRect(x: x, y: workArea.minY, width: w, height: workArea.height)
                let outcome = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/redist", workAreaWidth: workArea.width, workArea: workArea)
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
                _ = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/pack", workAreaWidth: workArea.width, workArea: workArea)
                actual = getAppKitFrame(windows[i].element) ?? frame
                // If min-width still overflows, pin right edge (may overlap → fail visibly below)
                if floor(actual.maxX) > maxX + 1 {
                    let pinnedX = max(floor(workArea.minX), maxX - floor(actual.width))
                    let pinned = CGRect(x: pinnedX, y: workArea.minY, width: floor(actual.width), height: workArea.height)
                    _ = setFrame(windows[i].element, appKitFrame: pinned, title: windows[i].title + "/pack-pin", workAreaWidth: workArea.width, workArea: workArea)
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
    /// Probe rect is always fitted inside `workArea` — growing from a right-edge x was a false
    /// nonResizable source (GitHub Desktop / Chrome near mid-screen refused overflow grow).
    private func isFullyNonResizable(_ win: ManagedWindow, workArea: CGRect) -> Bool {
        guard let before = getAppKitFrame(win.element) else { return false }
        let tol = max(2, workArea.width * Self.widthTolFraction)
        let minX = floor(workArea.minX)
        let maxX = floor(workArea.maxX)
        let areaW = max(1, maxX - minX)

        var probeW = floor(areaW * 0.5)
        if abs(probeW - before.width) <= tol {
            let grow = floor(min(areaW - 1, max(100, before.width + max(80, areaW * 0.1))))
            if grow > before.width + 2 {
                probeW = grow
            } else {
                probeW = floor(max(100, before.width * 0.5))
            }
        }
        if abs(probeW - before.width) <= 2 {
            return false // cannot construct a distinct probe
        }
        probeW = min(probeW, areaW)
        // Keep the probe fully inside workArea (do not preserve an x that makes w overflow).
        let fittedX = min(max(minX, floor(before.origin.x)), max(minX, maxX - probeW))
        let probe = CGRect(
            x: fittedX,
            y: workArea.minY,
            width: max(1, probeW),
            height: workArea.height
        )
        _ = setFrame(win.element, appKitFrame: probe, title: win.title + "/probe", workAreaWidth: workArea.width, workArea: workArea)
        let after = getAppKitFrame(win.element) ?? before
        let unchanged = abs(after.width - before.width) <= 2
        let missed = abs(after.width - probeW) > tol
        let nonResizable = unchanged && missed
        // Always restore — probe must not leave the window parked at the test rect
        // (esp. non-resizable: we skip tiling it next, so without restore it stays moved).
        if abs(after.minX - before.minX) > 1 || abs(after.minY - before.minY) > 1
            || abs(after.width - before.width) > 1 || abs(after.height - before.height) > 1 {
            _ = setFrame(win.element, appKitFrame: before, title: win.title + "/probe-restore", workAreaWidth: workArea.width, workArea: workArea)
        }
        if nonResizable {
            TilerLog.info("nonResizable title=\(win.title.prefix(24)) beforeW=\(Int(before.width)) probeW=\(Int(probeW)) afterW=\(Int(after.width)) fittedX=\(Int(fittedX))")
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
            _ = setFrame(windows[i].element, appKitFrame: frame, title: windows[i].title + "/fit", workAreaWidth: workArea.width, workArea: workArea)
            var after = getAppKitFrame(windows[i].element) ?? frame
            if floor(after.maxX) > maxX + 1 {
                let pinnedX = max(floor(workArea.minX), maxX - floor(after.width))
                let pinned = CGRect(x: pinnedX, y: workArea.minY, width: floor(after.width), height: workArea.height)
                _ = setFrame(windows[i].element, appKitFrame: pinned, title: windows[i].title + "/fit-pin", workAreaWidth: workArea.width, workArea: workArea)
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
            // Soft AX timeout per app (public API). Avoids one hung app freezing the whole retile
            // on the main thread — same class of fix AeroSpace pursued with thread-per-app (#131),
            // but lighter: we stay single-threaded and just bound wait time.
            AXUIElementSetMessagingTimeout(appEl, 1.0)
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

    /// Focus screen for retile: screen of a focused manageable window, else mouse, else main.
    private func resolveFocusScreen(from windows: [ManagedWindow]) -> NSScreen? {
        if let focused = windows.first(where: { $0.isFocused }) {
            let center = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
            if let s = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                return s
            }
        }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
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
        guard CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        // CFGetTypeID already verified; forced cast is then safe.
        let posVal = posRef as! AXValue
        let sizeVal = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private struct SetFrameOutcome {
        let ok: Bool
        let apiDisabled: Bool
    }

    /// Apply AX size/position. Pass 1: size→pos→size→pos; if still off, pass 2: pos→size→pos.
    /// If still too wide, shrink-recovery: size at current x, then move, then size again
    /// (Electron/Cursor often rejects size+move in one shot but accepts staged shrink — and
    /// hand-drag proves equal half is reachable).
    /// Success requires position+width within tolerance (no longer treat "moved" alone as OK).
    @discardableResult
    private func setFrame(
        _ win: AXUIElement,
        appKitFrame: CGRect,
        title: String = "",
        workAreaWidth: CGFloat = 0,
        workArea: CGRect? = nil
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
        let waW = workArea.map { $0.width } ?? workAreaWidth
        let tolW = max(2, (waW > 0 ? waW : max(appKitFrame.width, 1)) * Self.widthTolFraction)
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

        // Shrink-recovery: width still too large — stage size at current x, then move, then size.
        if let a = after, a.width > appKitFrame.width + tolW {
            let minSize = axMinSize(win)
            TilerLog.info(
                "setFrame shrink-recovery title=\(title.prefix(32)) haveW=\(Int(a.width)) wantW=\(Int(appKitFrame.width)) "
                + "minSize=\(minSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "n/a") "
                + "workArea=\(workArea.map { "\(Int($0.minX)),\(Int($0.width))" } ?? "n/a")"
            )
            // Only skip recovery when AX reports a hard min wider than the target half.
            let hardMin = (minSize?.width ?? 0) > appKitFrame.width + tolW
            if !hardMin {
                var wantSize = axFrame.size
                if let sOnly = AXValueCreate(.cgSize, &wantSize) {
                    _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sOnly)
                    _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sOnly)
                }
                usleep(40_000)
                var mid = getAppKitFrame(win) ?? a
                // If still wide and we know workArea, size at a safe x that fits target width.
                if mid.width > appKitFrame.width + tolW, let wa = workArea {
                    let maxX = floor(wa.maxX)
                    let minX = floor(wa.minX)
                    let tw = max(1, floor(appKitFrame.width))
                    let safeX = min(max(minX, floor(mid.origin.x)), max(minX, maxX - tw))
                    let safeRect = CGRect(x: safeX, y: appKitFrame.minY, width: tw, height: appKitFrame.height)
                    let safeAX = WindowTiler.appKitToAX(safeRect)
                    var sOrigin = safeAX.origin
                    var sSize = safeAX.size
                    if let p = AXValueCreate(.cgPoint, &sOrigin), let s = AXValueCreate(.cgSize, &sSize) {
                        _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
                        _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
                        _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
                    }
                    usleep(40_000)
                }
                // Final: apply full target again size-first then pos-first.
                result = apply(order: "size-first")
                usleep(30_000)
                after = getAppKitFrame(win)
                if let b = after, !closeEnough(b) {
                    result = apply(order: "pos-first")
                    usleep(40_000)
                    after = getAppKitFrame(win)
                }
            }
        }

        if let a = after {
            let ok = closeEnough(a)
            if ok {
                TilerLog.info("setFrame OK title=\(title.prefix(32)) target=\(appKitFrame) after=\(a) p=\(result.p.rawValue) s=\(result.s.rawValue)")
            } else {
                let minSize = axMinSize(win)
                TilerLog.error(
                    "setFrame MISS title=\(title.prefix(32)) target=\(appKitFrame) after=\(a) "
                    + "dx=\(a.origin.x - appKitFrame.origin.x) dw=\(a.width - appKitFrame.width) "
                    + "minSize=\(minSize.map { "\(Int($0.width))" } ?? "n/a") "
                    + "p=\(result.p.rawValue) s=\(result.s.rawValue)"
                )
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

    /// Best-effort AX minimum size (many apps omit it).
    private func axMinSize(_ win: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        let attr = "AXMinSize" as CFString
        guard AXUIElementCopyAttributeValue(win, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        let val = ref as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(val, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Drag swap

    /// Snapshot of manageable windows (AppKit frames).
    func listManageableWindows() -> [ManagedWindow] {
        collectManageableWindows()
    }

    /// Swap position+size of two windows (AppKit frames → AX).
    /// - Parameter aOriginalFrame: A's frame *before* the user dragged it. At mouse-up the OS has
    ///   already moved A with the cursor; reading A's live frame would park B on that mid-drag
    ///   rect instead of A's original tile slot (PRD drag-swap).
    @discardableResult
    func swapFrames(a: AXUIElement, b: AXUIElement, aOriginalFrame: CGRect) -> Bool {
        guard let frameB = getAppKitFrame(b) else { return false }
        // Capture B first (still unmoved), then put B into A's pre-drag slot, then A into B's slot.
        TilerLog.info(
            "swapFrames A→B slot=\(Int(frameB.minX)),\(Int(frameB.minY)) \(Int(frameB.width))x\(Int(frameB.height)) "
            + "B→Aorig=\(Int(aOriginalFrame.minX)),\(Int(aOriginalFrame.minY)) \(Int(aOriginalFrame.width))x\(Int(aOriginalFrame.height))"
        )
        let okB = setFrame(b, appKitFrame: aOriginalFrame, title: "swap-B").ok
        let okA = setFrame(a, appKitFrame: frameB, title: "swap-A").ok
        return okA && okB
    }

    func appKitFrame(of win: AXUIElement) -> CGRect? {
        getAppKitFrame(win)
    }
}
