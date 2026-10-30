import ApplicationServices
import AppKit
import Foundation

enum AccessibilityPermission {
    private static let defaults = UserDefaults.standard
    private static let kLastSettingsOpen = "ax.lastSettingsOpenAt"
    private static let kLastLaunchNagCDHash = "ax.lastLaunchNagCDHash"
    private static let kLastLaunchNagAt = "ax.lastLaunchNagAt"
    private static var promptedSystemDialogThisProcess = false
    private static let lock = NSLock()

    /// Silent trust check. Never pass prompt:true from hotkeys / timers / menu rebuild.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prefer `isTrusted()`. Kept for call sites that previously used options.
    static func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            return requestSystemPromptOnce()
        }
        return isTrusted()
    }

    /// System Accessibility prompt at most once per process lifetime (explicit user action only).
    @discardableResult
    static func requestSystemPromptOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if promptedSystemDialogThisProcess {
            return AXIsProcessTrusted()
        }
        promptedSystemDialogThisProcess = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Current code CDHash (sha256 hex) if readable; used to nag once per signed binary.
    static func currentCDHash() -> String? {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dvvv", path]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                if line.hasPrefix("CDHash=") {
                    return String(line.dropFirst("CDHash=".count))
                }
            }
        } catch {
            TilerLog.error("codesign CDHash read failed: \(error)")
        }
        return nil
    }

    static func signingSummary() -> String {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dvvv", path]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var team = "not set"
            var sig = "signed"
            var authority = ""
            var cd = "?"
            for line in text.split(separator: "\n").map(String.init) {
                if line.hasPrefix("TeamIdentifier=") { team = String(line.dropFirst("TeamIdentifier=".count)) }
                if line.hasPrefix("Signature=") { sig = String(line.dropFirst("Signature=".count)) }
                if line.hasPrefix("Authority=") && authority.isEmpty {
                    authority = String(line.dropFirst("Authority=".count))
                }
                if line.hasPrefix("CDHash=") { cd = String(line.dropFirst("CDHash=".count)) }
            }
            if sig == "adhoc" { /* keep */ }
            else if !authority.isEmpty { sig = authority }
            let short = cd.count > 12 ? String(cd.prefix(12)) : cd
            return "\(sig) team=\(team) cd=\(short)"
        } catch {
            return "codesign-unavailable"
        }
    }

    /// Open Accessibility pane at most once per `minInterval` (default 60s). Persisted across launches.
    @discardableResult
    static func openSystemSettingsIfNeeded(minInterval: TimeInterval = 60) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: kLastSettingsOpen)
        if last > 0, now - last < minInterval {
            TilerLog.info("AX settings open skipped (throttled, last \(Int(now - last))s ago)")
            return false
        }
        defaults.set(now, forKey: kLastSettingsOpen)
        openSystemSettings()
        return true
    }

    static func openSystemSettings() {
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

    /// Launch-time nag: at most once per CDHash (or once per 24h if CDHash unknown). Returns whether a nag was shown.
    @discardableResult
    static func nagOnLaunchIfNeeded() -> Bool {
        guard !isTrusted() else { return false }
        let cd = currentCDHash() ?? "unknown"
        let now = Date().timeIntervalSince1970
        let lastCD = defaults.string(forKey: kLastLaunchNagCDHash)
        let lastAt = defaults.double(forKey: kLastLaunchNagAt)
        if lastCD == cd, lastAt > 0, now - lastAt < 24 * 3600 {
            TilerLog.info("AX launch nag skipped (same CDHash within 24h)")
            return false
        }
        defaults.set(cd, forKey: kLastLaunchNagCDHash)
        defaults.set(now, forKey: kLastLaunchNagAt)
        NotificationPoster.post(
            title: "需要「辅助功能」才能移动窗口",
            body: "请只运行 /Applications/MacTiler。系统设置→隐私与安全性→辅助功能→打开 MacTiler；若已开仍无效：先关→「−」移除→退出再开。"
        )
        _ = openSystemSettingsIfNeeded(minInterval: 60)
        return true
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.junmaly.mactiler"
    }

    static var tccutilResetCommand: String {
        "tccutil reset Accessibility \(bundleIdentifier)"
    }

    static func copyTccutilResetToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tccutilResetCommand, forType: .string)
        TilerLog.info("copied tccutil reset cmd to pasteboard")
    }

    /// User-facing guidance body (menu / notify).
    static var guidanceBody: String {
        "请把 MacTiler 放在「应用程序」。系统设置→隐私与安全性→辅助功能→打开 /Applications/MacTiler。若开关已开仍无效：先关掉→用「−」移除→退出 App→再打开并授权。高级：终端执行 \(tccutilResetCommand) 后重开 MacTiler。"
    }
}
