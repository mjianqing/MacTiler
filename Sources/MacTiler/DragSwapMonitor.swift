import AppKit
import ApplicationServices

/// Detects drag of window A onto window B and swaps their frames (PRD v1.2).
/// Uses global mouse monitors; requires Accessibility. Skips when paused.
final class DragSwapMonitor {
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    private var dragActive = false
    private var startPoint = CGPoint.zero
    private var sourceElement: AXUIElement?
    private var sourceStartFrame: CGRect = .zero
    private var maxDragDistance: CGFloat = 0

    /// Minimum pointer travel (AppKit points) before a release can trigger swap.
    private let minDragDistance: CGFloat = 48
    /// Target hit-test uses a shrunk frame so edge/resize drags are less likely to swap.
    private let targetInset: CGFloat = 24

    func start() {
        stop()
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.onMouseDown(event)
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.onMouseDragged(event)
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.onMouseUp(event)
        }
    }

    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        downMonitor = nil
        dragMonitor = nil
        upMonitor = nil
        reset()
    }

    private func reset() {
        dragActive = false
        sourceElement = nil
        maxDragDistance = 0
    }

    private func onMouseDown(_ event: NSEvent) {
        guard AccessibilityPermission.isTrusted(prompt: false) else { return }
        guard !StrategyStore.shared.isPaused else { return }

        let point = Self.appKitMouseLocation()
        guard let win = windowContaining(point: point) else {
            reset()
            return
        }
        // Ignore title-bar-ish? We accept any point in window; distance threshold filters clicks.
        dragActive = true
        startPoint = point
        sourceElement = win.element
        sourceStartFrame = win.frame
        maxDragDistance = 0
    }

    private func onMouseDragged(_ event: NSEvent) {
        guard dragActive else { return }
        let point = Self.appKitMouseLocation()
        let d = hypot(point.x - startPoint.x, point.y - startPoint.y)
        maxDragDistance = max(maxDragDistance, d)
    }

    private func onMouseUp(_ event: NSEvent) {
        defer { reset() }
        guard dragActive, let source = sourceElement else { return }
        guard !StrategyStore.shared.isPaused else { return }
        guard maxDragDistance >= minDragDistance else { return }

        let point = Self.appKitMouseLocation()
        guard let target = windowContaining(point: point, excluding: source, inset: targetInset) else {
            return
        }

        // Require that source actually moved or user dragged onto another tile.
        // Also require target is a different window.
        _ = WindowTiler.shared.swapFrames(a: source, b: target.element)
    }

    private func windowContaining(point: CGPoint, excluding: AXUIElement? = nil, inset: CGFloat = 0) -> ManagedWindow? {
        let windows = WindowTiler.shared.listManageableWindows()
        // Front-to-back: prefer smaller area (more specific) among hits, then focused.
        let hits = windows.filter { win in
            if let excluding, CFEqual(win.element, excluding) { return false }
            let frame = win.frame.insetBy(dx: inset, dy: inset)
            return frame.contains(point)
        }
        return hits.sorted { a, b in
            let aa = a.frame.width * a.frame.height
            let bb = b.frame.width * b.frame.height
            if abs(aa - bb) > 1 { return aa < bb }
            return a.isFocused && !b.isFocused
        }.first
    }

    /// NSEvent.mouseLocation is AppKit bottom-left global.
    private static func appKitMouseLocation() -> CGPoint {
        NSEvent.mouseLocation
    }
}
