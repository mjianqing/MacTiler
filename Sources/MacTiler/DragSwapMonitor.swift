import AppKit
import ApplicationServices

/// Drag window A (title bar) onto B's frame → swap frames (PRD v1.2.2).
/// Hit-test: cursor inside target window rect (AppKit). Highlight while dragging.
/// Only title-bar presses arm swap; edge/corner resize is ignored.
final class DragSwapMonitor {
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var dragActive = false
    private var startPoint = CGPoint.zero
    private var sourceElement: AXUIElement?
    private var sourceFrameAtDown = CGRect.zero
    private var maxDragDistance: CGFloat = 0
    private var highlightedTarget: AXUIElement?
    /// Snapshot at mouse-down — avoid re-enumerating every app's AX windows on each drag tick
    /// (AeroSpace lesson: AX on the main thread blocks; thrashing mid-drag feels janky).
    private var dragWindowSnapshot: [ManagedWindow] = []

    /// Small travel before swap/highlight arms (filters clicks).
    private let minDragDistance: CGFloat = 12
    /// AppKit title-bar band height (traffic lights + title).
    private let titleBarHeight: CGFloat = 26
    /// Distance from window edge treated as resize grip.
    private let resizeEdgeInset: CGFloat = 7
    /// Mid-drag: size change this large while origin almost fixed → abort as resize.
    private let resizeSizeDelta: CGFloat = 4

    private let highlight = SwapHighlightOverlay()

    func start() {
        stop()
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.onMouseDown(e)
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            self?.onMouseDragged(e)
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            self?.onMouseUp(e)
        }
    }

    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        downMonitor = nil
        dragMonitor = nil
        upMonitor = nil
        reset(clearHighlight: true)
    }

    private func reset(clearHighlight: Bool) {
        dragActive = false
        sourceElement = nil
        sourceFrameAtDown = .zero
        maxDragDistance = 0
        highlightedTarget = nil
        dragWindowSnapshot = []
        if clearHighlight {
            highlight.hide()
        }
    }

    private func onMouseDown(_ event: NSEvent) {
        guard AccessibilityPermission.isTrusted(prompt: false) else { return }
        if StrategyStore.shared.isPaused {
            reset(clearHighlight: true)
            return
        }

        let point = Self.appKitMouseLocation()
        guard let win = windowUnderCursor(point: point, excluding: nil) else {
            reset(clearHighlight: true)
            return
        }

        // Edge / corner resize grips must not arm swap.
        if isInResizeEdge(point: point, frame: win.frame) {
            TilerLog.info("drag-swap ignore: resize edge at \(Int(point.x)),\(Int(point.y))")
            reset(clearHighlight: true)
            return
        }

        // Only title-bar band (or AX title area) starts a swap drag.
        guard isInTitleBar(point: point, frame: win.frame, element: win.element) else {
            TilerLog.info("drag-swap ignore: not title bar at \(Int(point.x)),\(Int(point.y)) frame=\(Int(win.frame.minX)),\(Int(win.frame.minY)) \(Int(win.frame.width))x\(Int(win.frame.height))")
            reset(clearHighlight: true)
            return
        }

        dragActive = true
        startPoint = point
        sourceElement = win.element
        sourceFrameAtDown = win.frame
        maxDragDistance = 0
        highlightedTarget = nil
        // One AX collect for the whole drag; B's frame is stable until swap commit.
        dragWindowSnapshot = WindowTiler.shared.listManageableWindows()
        highlight.hide()
        TilerLog.info("drag-swap arm title-bar title=\(win.title.prefix(24)) snap=\(dragWindowSnapshot.count)")
    }

    private func onMouseDragged(_ event: NSEvent) {
        guard dragActive, let source = sourceElement else { return }
        if StrategyStore.shared.isPaused {
            highlight.hide()
            highlightedTarget = nil
            return
        }

        // If the OS is resizing (size changes, origin almost fixed), abort swap.
        if let current = WindowTiler.shared.appKitFrame(of: source),
           looksLikeResize(from: sourceFrameAtDown, to: current) {
            TilerLog.info("drag-swap abort: resize detected mid-drag")
            reset(clearHighlight: true)
            return
        }

        let point = Self.appKitMouseLocation()
        let d = hypot(point.x - startPoint.x, point.y - startPoint.y)
        maxDragDistance = max(maxDragDistance, d)

        guard maxDragDistance >= minDragDistance else {
            highlight.hide()
            highlightedTarget = nil
            return
        }

        // Target = manageable window whose frame contains the cursor (no harsh inset).
        if let target = windowUnderCursor(point: point, excluding: source) {
            // CFEqual crashes on nil (CFEqual.cold.1); only compare when highlighted.
            let same = highlightedTarget.map { CFEqual(target.element, $0) as Bool } ?? false
            if !same {
                highlightedTarget = target.element
            }
            // Keep overlay synced if window moved during drag.
            highlight.show(over: target.frame)
        } else {
            highlightedTarget = nil
            highlight.hide()
        }
    }

    private func onMouseUp(_ event: NSEvent) {
        defer { reset(clearHighlight: true) }
        guard dragActive, let source = sourceElement else { return }
        guard !StrategyStore.shared.isPaused else { return }
        guard maxDragDistance >= minDragDistance else { return }

        // Final resize guard (e.g. size changed on mouse-up).
        if let current = WindowTiler.shared.appKitFrame(of: source),
           looksLikeResize(from: sourceFrameAtDown, to: current) {
            TilerLog.info("drag-swap abort: resize on mouse-up")
            return
        }

        let point = Self.appKitMouseLocation()
        guard let target = windowUnderCursor(point: point, excluding: source) else { return }

        // Pass A's frame at mouse-down — not A's live (dragged) frame.
        TilerLog.info(
            "drag-swap commit Aorig=\(Int(sourceFrameAtDown.minX)),\(Int(sourceFrameAtDown.minY)) "
            + "\(Int(sourceFrameAtDown.width))x\(Int(sourceFrameAtDown.height)) "
            + "B=\(Int(target.frame.minX)),\(Int(target.frame.minY)) "
            + "\(Int(target.frame.width))x\(Int(target.frame.height))"
        )
        _ = WindowTiler.shared.swapFrames(a: source, b: target.element, aOriginalFrame: sourceFrameAtDown)
    }

    /// Left / right / bottom edges (and their corners) are resize grips.
    /// Top-center stays title-bar move territory; top-left/right corners still caught via L/R.
    private func isInResizeEdge(point: CGPoint, frame: CGRect) -> Bool {
        let e = resizeEdgeInset
        guard frame.contains(point) else { return false }
        let nearLeft = point.x <= frame.minX + e
        let nearRight = point.x >= frame.maxX - e
        let nearBottom = point.y <= frame.minY + e
        return nearLeft || nearRight || nearBottom
    }

    /// Title bar = top strip in AppKit coords (y near maxY), inset from L/R edges.
    private func isInTitleBar(point: CGPoint, frame: CGRect, element: AXUIElement) -> Bool {
        if let axTitle = titleAreaFromAX(element), axTitle.contains(point) {
            return true
        }
        let e = resizeEdgeInset
        let band = CGRect(
            x: frame.minX + e,
            y: frame.maxY - titleBarHeight,
            width: max(0, frame.width - 2 * e),
            height: titleBarHeight
        )
        return band.contains(point)
    }

    /// Prefer AX title UI element frame when present (covers taller custom title bars).
    private func titleAreaFromAX(_ win: AXUIElement) -> CGRect? {
        var ref: CFTypeRef?
        let attrs = ["AXTitleUIElement", kAXTitleUIElementAttribute as String]
        for name in attrs {
            ref = nil
            guard AXUIElementCopyAttributeValue(win, name as CFString, &ref) == .success,
                  let el = ref,
                  CFGetTypeID(el) == AXUIElementGetTypeID() else { continue }
            let titleEl = el as! AXUIElement
            guard var rect = WindowTiler.shared.appKitFrame(of: titleEl) else { continue }
            // Expand vertically a bit so traffic-lights row still counts if only text node returned.
            let pad: CGFloat = 8
            rect = CGRect(
                x: rect.minX - pad,
                y: rect.minY - pad,
                width: rect.width + 2 * pad,
                height: max(titleBarHeight, rect.height + 2 * pad)
            )
            return rect
        }
        return nil
    }

    private func looksLikeResize(from before: CGRect, to after: CGRect) -> Bool {
        // Title-bar move keeps size; any clear size change means the user is resizing.
        let dw = abs(after.width - before.width)
        let dh = abs(after.height - before.height)
        return dw >= resizeSizeDelta || dh >= resizeSizeDelta
    }

    /// Cursor in AppKit frame of a manageable window. Prefer frontmost/smaller among overlaps.
    private func windowUnderCursor(point: CGPoint, excluding: AXUIElement?) -> ManagedWindow? {
        // Mid-drag: reuse snapshot. Mouse-down (excluding==nil): live collect to arm.
        let windows: [ManagedWindow]
        if excluding != nil, !dragWindowSnapshot.isEmpty {
            windows = dragWindowSnapshot
        } else {
            windows = WindowTiler.shared.listManageableWindows()
        }
        let hits = windows.filter { win in
            if let excluding, CFEqual(win.element, excluding) { return false }
            return win.frame.contains(point)
        }
        // Prefer focused, then smaller area (tile under cursor rather than huge behind).
        return hits.sorted { a, b in
            if a.isFocused != b.isFocused { return a.isFocused && !b.isFocused }
            let aa = a.frame.width * a.frame.height
            let bb = b.frame.width * b.frame.height
            return aa < bb
        }.first
    }

    private static func appKitMouseLocation() -> CGPoint {
        NSEvent.mouseLocation
    }
}

/// Border + light fill overlay matching a window's AppKit frame.
final class SwapHighlightOverlay {
    private var window: NSWindow?

    func show(over appKitFrame: CGRect) {
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            let w = NSWindow(
                contentRect: appKitFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let view = HighlightView(frame: NSRect(origin: .zero, size: appKitFrame.size))
            w.contentView = view
            window = w
            win = w
        }
        win.setFrame(appKitFrame, display: true)
        if let view = win.contentView as? HighlightView {
            view.frame = NSRect(origin: .zero, size: appKitFrame.size)
            view.needsDisplay = true
        }
        win.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let fill = NSColor.systemBlue.withAlphaComponent(0.18)
        fill.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    override var isOpaque: Bool { false }
}
