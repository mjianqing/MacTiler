import ApplicationServices
import AppKit

enum AccessibilityPermission {
    /// Last time we opened System Settings for Accessibility (throttle spam).
    private static var lastSettingsOpenAt: Date?
    private static let lock = NSLock()

    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open Accessibility pane at most once per `minInterval` (default 60s).
    /// Use for automatic/nag paths. Explicit user menu actions may call `openSystemSettings()` instead.
    @discardableResult
    static func openSystemSettingsIfNeeded(minInterval: TimeInterval = 60) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastSettingsOpenAt, now.timeIntervalSince(last) < minInterval {
            TilerLog.info("AX settings open skipped (throttled, last \(Int(now.timeIntervalSince(last)))s ago)")
            return false
        }
        lastSettingsOpenAt = now
        openSystemSettings()
        return true
    }

    static func openSystemSettings() {
        // Deep link to Privacy → Accessibility (macOS 13+)
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                TilerLog.info("opened AX System Settings via \(raw)")
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
            TilerLog.info("opened AX System Settings (fallback privacy root)")
        }
    }
}
