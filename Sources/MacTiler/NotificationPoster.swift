import AppKit
import Foundation
import UserNotifications

/// Posts user-visible feedback. Always logs + status-item tip + beep;
/// UN notification is best-effort (may be denied → silent without fallbacks).
enum NotificationPoster {
    weak static var statusItem: NSStatusItem?
    private static var tipRestoreWork: DispatchWorkItem?

    static func post(title: String, body: String, beep: Bool = true) {
        TilerLog.info("feedback: \(title) — \(body)")
        if beep {
            NSSound.beep()
        }
        flashStatusTip("\(title): \(body)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                TilerLog.error("UN add failed: \(err.localizedDescription)")
            }
        }
    }

    /// Briefly replace status item image with short text so user sees success/fail even without UN.
    static func flashStatusTip(_ text: String) {
        guard let button = statusItem?.button else { return }
        tipRestoreWork?.cancel()
        let previousImage = button.image
        let previousTitle = button.title
        button.image = nil
        // Keep tip short for menu bar
        let tip = text.count > 28 ? String(text.prefix(27)) + "…" : text
        button.title = tip
        let work = DispatchWorkItem {
            button.title = previousTitle
            button.image = previousImage
        }
        tipRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
