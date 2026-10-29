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
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = decoded
        } else if let data = try? Data(contentsOf: url),
                  let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Migrate once from v0 profile-based prefs if present.
            var prefs = AppPreferences()
            if let s = legacy["currentStrategy"] as? String {
                prefs.currentStrategy = s
            } else if let s = legacy["defaultStrategy"] as? String {
                prefs.currentStrategy = s
            }
            if let v = legacy["autoRetile"] as? Bool { prefs.autoRetile = v }
            if let v = legacy["paused"] as? Bool { prefs.paused = v }
            if let v = legacy["halfOnLeft"] as? Bool { prefs.halfOnLeft = v }
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

    var halfOnLeft: Bool {
        get { preferences.halfOnLeft }
        set { preferences.halfOnLeft = newValue }
    }

    var currentStrategy: StrategyID {
        get { preferences.strategy }
        set { preferences.currentStrategy = newValue.rawValue }
    }

    func setStrategy(_ strategy: StrategyID) {
        currentStrategy = strategy
    }
}
