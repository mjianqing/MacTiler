#!/usr/bin/env swift
import AppKit
import ApplicationServices

func primaryScreen() -> NSScreen {
    NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main!
}
func appKitToAX(_ rect: CGRect) -> CGRect {
    let p = primaryScreen()
    return CGRect(x: rect.origin.x, y: p.frame.maxY - rect.origin.y - rect.height, width: rect.width, height: rect.height)
}
func axToAppKit(_ rect: CGRect) -> CGRect {
    let p = primaryScreen()
    return CGRect(x: rect.origin.x, y: p.frame.maxY - rect.origin.y - rect.height, width: rect.width, height: rect.height)
}
func getAXFrame(_ win: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func setAXFrame(_ win: AXUIElement, appKit: CGRect) -> Bool {
    let ax = appKitToAX(appKit)
    var o = ax.origin; var s = ax.size
    guard let pv = AXValueCreate(.cgPoint, &o), let sv = AXValueCreate(.cgSize, &s) else { return false }
    _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    let b = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    let c = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    return b == .success && c == .success
}
func titleOf(_ win: AXUIElement) -> String {
    var ref: CFTypeRef?; AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &ref)
    return (ref as? String) ?? "?"
}
func subroleOf(_ win: AXUIElement) -> String {
    var ref: CFTypeRef?; AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &ref)
    return (ref as? String) ?? "?"
}

struct Item {
    let el: AXUIElement
    let app: String
    let title: String
    let sub: String
    let appKit: CGRect
    let ax: CGRect
}

var items: [Item] = []
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
    let name = app.localizedName ?? "?"
    if name == "MacTiler" { continue }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let list = windowsRef as? [AXUIElement] else { continue }
    for win in list {
        guard let ax = getAXFrame(win), ax.width > 100, ax.height > 100 else { continue }
        let ak = axToAppKit(ax)
        items.append(Item(el: win, app: name, title: titleOf(win), sub: subroleOf(win), appKit: ak, ax: ax))
    }
}

for s in NSScreen.screens {
    print("==== \(s.localizedName) frame=\(s.frame) visible=\(s.visibleFrame) ====")
    let on = items.filter { NSMouseInRect(CGPoint(x: $0.appKit.midX, y: $0.appKit.midY), s.frame, false) }
    for (i, it) in on.enumerated() {
        print("  [\(i)] \(it.app) | \(it.title) | sub=\(it.sub) | appKit=\(it.appKit) ax=\(it.ax)")
    }
    // Prefer standard windows that are mostly contained in this screen
    let candidates = on.filter { item in
        let inter = item.appKit.intersection(s.frame)
        let area = item.appKit.width * item.appKit.height
        let ratio = area > 0 ? (inter.width * inter.height) / area : 0
        return ratio > 0.6 && item.sub.contains("Standard")
    }
    let pick = candidates.first ?? on.first { $0.app != "访达" && $0.app != "Finder" } ?? on.first
    guard let target = pick else { print("  no window"); continue }
    let before = getAXFrame(target.el).map(axToAppKit)!
    let half = CGRect(x: s.visibleFrame.minX, y: s.visibleFrame.minY, width: s.visibleFrame.width/2, height: s.visibleFrame.height)
    let right = CGRect(x: s.visibleFrame.minX + s.visibleFrame.width/2, y: s.visibleFrame.minY, width: s.visibleFrame.width/2, height: s.visibleFrame.height)
    // Toggle: if already near left half, go right, else left
    let dest = abs(before.origin.x - half.origin.x) < 20 && abs(before.width - half.width) < 40 ? right : half
    print("  PICK \(target.app):\(target.title)")
    print("  BEFORE appKit=\(before)")
    print("  DEST   appKit=\(dest) ax=\(appKitToAX(dest))")
    let ok = setAXFrame(target.el, appKit: dest)
    usleep(250_000)
    let after = getAXFrame(target.el).map(axToAppKit)!
    let moved = hypot(after.midX - before.midX, after.midY - before.midY) > 5
        || abs(after.width - before.width) > 5 || abs(after.height - before.height) > 5
    print("  AFTER  appKit=\(after) setOK=\(ok) MOVED=\(moved)")
}
