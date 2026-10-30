import AppKit
import CoreGraphics

/// Screen Recording TCC — separate from Accessibility used by tiling (PRD v1.2).
enum ScreenshotPermission {
    private static var lastSettingsOpenAt: Date?
    private static let lock = NSLock()

    static func isTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request OS prompt when possible. Returns current (post-request) state.
    @discardableResult
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func openSystemSettingsIfNeeded(minInterval: TimeInterval = 60) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastSettingsOpenAt, now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastSettingsOpenAt = now
        openSystemSettings()
        return true
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                TilerLog.info("opened Screen Recording settings via \(raw)")
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}
