import AppKit
import ApplicationServices

/// Region / focus-display capture. Semantics align with system `screencapture`
/// (interactive select, Esc cancel, clipboard-first). Implementation calls the
/// system CLI (public tool) — not a copy of Flameshot/ksnip (GPL). Screen Recording
/// TCC is checked on the host app (PRD / 开源对照).
enum ScreenshotService {
    enum Mode {
        case region
        case focusDisplay
    }

    enum Outcome {
        case success(savedPath: String?)
        case cancelled
        case needScreenRecording
        case failed(String)
    }

    static func capture(_ mode: Mode) -> Outcome {
        // Independent of tiling pause (PRD).
        if !ScreenshotPermission.isTrusted() {
            _ = ScreenshotPermission.requestAccess()
            if !ScreenshotPermission.isTrusted() {
                return .needScreenRecording
            }
            // Sequoia+: grant often needs process restart before frames are non-empty.
            TilerLog.info("screen recording just granted — may need relaunch")
        }

        let saveDesktop = StrategyStore.shared.saveScreenshotToDesktop
        let filePath: String? = saveDesktop ? desktopTimestampPath() : nil

        var args: [String] = ["-x", "-c"] // silent + clipboard
        switch mode {
        case .region:
            // -i interactive select; Esc cancels (system UI). -s = selection only (no window mode).
            args.append(contentsOf: ["-i", "-s"])
        case .focusDisplay:
            let index = focusDisplayIndex1Based()
            args.append(contentsOf: ["-D", "\(index)"])
        }
        if let filePath {
            args.append(filePath)
        }

        TilerLog.info("screencapture args=\(args.joined(separator: " "))")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failed("无法启动 screencapture：\(error.localizedDescription)")
        }

        let status = proc.terminationStatus
        if status != 0 {
            // Interactive cancel is typically non-zero with empty clipboard.
            TilerLog.info("screencapture exit=\(status) (treat as cancel if no image)")
            if pasteboardHasImage() {
                // Partial success path
            } else {
                return .cancelled
            }
        }

        if !pasteboardHasImage() {
            // Common when TCC looks granted but CDHash stale / needs relaunch.
            if !ScreenshotPermission.isTrusted() {
                return .needScreenRecording
            }
            return .failed("截图为空：请到「屏幕录制」确认已开 MacTiler，然后退出并重开本 App")
        }

        if let filePath, !FileManager.default.fileExists(atPath: filePath) {
            // Clipboard OK but file missing — write from pasteboard as fallback.
            if writePasteboardPNG(to: filePath) {
                return .success(savedPath: filePath)
            }
            return .success(savedPath: nil) // clipboard ok
        }
        return .success(savedPath: filePath)
    }

    private static func desktopTimestampPath() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let name = "MacTiler-\(fmt.string(from: Date())).png"
        return NSHomeDirectory() + "/Desktop/" + name
    }

    /// `screencapture -D` uses 1=main, 2=secondary, … matching NSScreen.screens order
    /// where screens[0] is not always main — map via CGDirectDisplayID list.
    private static func focusDisplayIndex1Based() -> Int {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 1 }
        let focus = resolveFocusScreen() ?? NSScreen.main ?? screens[0]
        // Build ordered list: main first (screencapture convention), then others.
        let main = NSScreen.main
        var ordered: [NSScreen] = []
        if let main { ordered.append(main) }
        for s in screens where s != main { ordered.append(s) }
        if let idx = ordered.firstIndex(where: { $0 == focus }) {
            return idx + 1
        }
        return 1
    }

    private static func resolveFocusScreen() -> NSScreen? {
        // Prefer screen under mouse (user intent for "focus display"); else main.
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func pasteboardHasImage() -> Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    @discardableResult
    private static func writePasteboardPNG(to path: String) -> Bool {
        let pb = NSPasteboard.general
        guard let objs = pb.readObjects(forClasses: [NSImage.self], options: nil),
              let img = objs.first as? NSImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            TilerLog.error("write desktop png failed: \(error)")
            return false
        }
    }
}
