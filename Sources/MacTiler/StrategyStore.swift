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

    var activeKey: String {
        get { preferences.activeProfileKey }
        set { preferences.activeProfileKey = newValue }
    }

    var spaceDetectionDegraded: Bool {
        get { preferences.spaceDetectionDegraded }
        set { preferences.spaceDetectionDegraded = newValue }
    }

    func strategy(for key: String) -> StrategyID {
        preferences.strategy(for: key)
    }

    func setStrategy(_ strategy: StrategyID, for key: String) {
        preferences.setStrategy(strategy, for: key)
    }

    func ensureProfile(_ name: String) {
        if !preferences.profileNames.contains(name) {
            preferences.profileNames.append(name)
        }
    }
}
