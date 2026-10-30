import Foundation

final class StrategyStore {
    static let shared = StrategyStore()

    private let url: URL
    private(set) var preferences: AppPreferences {
        didSet { save() }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacTiler", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("preferences.json")

        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var prefs = AppPreferences()
            if let s = obj["currentStrategy"] as? String {
                prefs.currentStrategy = StrategyID.migrated(from: s).rawValue
            } else if let s = obj["defaultStrategy"] as? String {
                prefs.currentStrategy = StrategyID.migrated(from: s).rawValue
            }
            if let v = obj["autoRetile"] as? Bool { prefs.autoRetile = v }
            if let v = obj["paused"] as? Bool { prefs.paused = v }
            if let v = obj["saveScreenshotToDesktop"] as? Bool { prefs.saveScreenshotToDesktop = v }
            if let hk = obj["screenshotRegionHotKey"] as? [String: Any],
               let kc = hk["keyCode"] as? Int,
               let mods = hk["carbonModifiers"] as? Int {
                prefs.screenshotRegionHotKey = HotKeySpec(keyCode: UInt32(kc), carbonModifiers: UInt32(mods))
            }
            if let hk = obj["screenshotDisplayHotKey"] as? [String: Any],
               let kc = hk["keyCode"] as? Int,
               let mods = hk["carbonModifiers"] as? Int {
                prefs.screenshotDisplayHotKey = HotKeySpec(keyCode: UInt32(kc), carbonModifiers: UInt32(mods))
            }
            // Reject persisted ⌘⇧3/4/5 as region/display defaults
            if prefs.screenshotRegionHotKey.looksLikeSystemScreenshotDefault {
                prefs.screenshotRegionHotKey = .defaultRegion
            }
            if prefs.screenshotDisplayHotKey.looksLikeSystemScreenshotDefault {
                prefs.screenshotDisplayHotKey = .defaultDisplay
            }
            // drop halfOnLeft / profile fields
            preferences = prefs
            save()
        } else {
            preferences = AppPreferences()
            save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("MacTiler: failed to save preferences: \(error)")
        }
    }

    var isPaused: Bool {
        get { preferences.paused }
        set { preferences.paused = newValue }
    }

    var autoRetile: Bool {
        get { preferences.autoRetile }
        set { preferences.autoRetile = newValue }
    }

    var currentStrategy: StrategyID {
        get { preferences.strategy }
        set { preferences.currentStrategy = newValue.rawValue }
    }

    var saveScreenshotToDesktop: Bool {
        get { preferences.saveScreenshotToDesktop }
        set { preferences.saveScreenshotToDesktop = newValue }
    }

    var screenshotRegionHotKey: HotKeySpec {
        get { preferences.screenshotRegionHotKey }
        set {
            var v = newValue
            if v.looksLikeSystemScreenshotDefault { v = .defaultRegion }
            preferences.screenshotRegionHotKey = v
        }
    }

    var screenshotDisplayHotKey: HotKeySpec {
        get { preferences.screenshotDisplayHotKey }
        set {
            var v = newValue
            if v.looksLikeSystemScreenshotDefault { v = .defaultDisplay }
            preferences.screenshotDisplayHotKey = v
        }
    }

    func setStrategy(_ strategy: StrategyID) {
        currentStrategy = strategy
    }
}
