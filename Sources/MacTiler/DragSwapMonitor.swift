import AppKit
import ApplicationServices

/// Drag window A (title bar) onto B's frame → swap frames (PRD v1.2.2).
/// Hit-test: cursor inside target window rect (AppKit). Highlight while dragging.
final class DragSwapMonitor {
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var dragActive = false
    private var startPoint = CGPoint.zero
    private var sourceElement: AXUIElement?
    private var maxDragDistance: CGFloat = 0
    private var highlightedTarget: AXUIElement?

    /// Small travel before swap/highlight arms (filters clicks).
    private let minDragDistance: CGFloat = 12

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
        maxDragDistance = 0
        highlightedTarget = nil
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
        // Source = window under cursor at press (title-bar drag starts here).
        guard let win = windowUnderCursor(point: point, excluding: nil) else {
            reset(clearHighlight: true)
            return
        }
        dragActive = true
        startPoint = point
        sourceElement = win.element
        maxDragDistance = 0
        highlightedTarget = nil
        highlight.hide()
    }

    private func onMouseDragged(_ event: NSEvent) {
        guard dragActive, let source = sourceElement else { return }
        if StrategyStore.shared.isPaused {
            highlight.hide()
            highlightedTarget = nil
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

        let point = Self.appKitMouseLocation()
        guard let target = windowUnderCursor(point: point, excluding: source) else { return }

        _ = WindowTiler.shared.swapFrames(a: source, b: target.element)
    }

    /// Cursor in AppKit frame of a manageable window. Prefer frontmost/smaller among overlaps.
    private func windowUnderCursor(point: CGPoint, excluding: AXUIElement?) -> ManagedWindow? {
        let windows = WindowTiler.shared.listManageableWindows()
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
