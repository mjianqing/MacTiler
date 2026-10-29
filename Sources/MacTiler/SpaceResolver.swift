import Foundation
import CoreGraphics
import AppKit

/// Resolves a persistence key for the "current desktop".
/// Public APIs do not expose stable macOS Space IDs.
/// We attempt a best-effort probe; if unstable, fall back to named profiles
/// and only retile windows on the currently visible Space.
final class SpaceResolver {
    static let shared = SpaceResolver()

    private(set) var degraded: Bool = true
    private(set) var lastProbeNote: String = "Not probed yet"

    /// Returns the key used for strategy persistence.
    func currentKey() -> String {
        if let spaceId = probeSpaceIdentifier() {
            degraded = false
            StrategyStore.shared.spaceDetectionDegraded = false
            lastProbeNote = "Using probed space id: \(spaceId)"
            return "space:\(spaceId)"
        }
        degraded = true
        StrategyStore.shared.spaceDetectionDegraded = true
        lastProbeNote = "No stable public Space id — using named profile '\(StrategyStore.shared.activeKey)'"
        return "profile:\(StrategyStore.shared.activeKey)"
    }

    /// Best-effort: look for kCGWindowWorkspace in window list (may be absent / unstable).
    private func probeSpaceIdentifier() -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Historically some builds exposed kCGWindowWorkspace; treat any consistent Int as a hint only.
        var ids = Set<Int>()
        for win in info {
            if let ws = win["kCGWindowWorkspace"] as? Int {
                ids.insert(ws)
            } else if let ws = win["Workspace"] as? Int {
                ids.insert(ws)
            }
        }
        // Require a single non-zero workspace value to even consider it "usable".
        // On modern macOS this key is typically missing → nil → degraded mode.
        if ids.count == 1, let only = ids.first, only != 0 {
            return String(only)
        }
        return nil
    }
}
