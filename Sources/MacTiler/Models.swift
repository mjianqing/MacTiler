import Foundation
import CoreGraphics
import ApplicationServices

enum StrategyID: String, CaseIterable, Codable, Equatable {
    case twoHalves = "two-halves"
    case threeThirds = "three-thirds"
    case halfTwoQuarters = "half-two-quarters"

    var displayName: String {
        switch self {
        case .twoHalves: return "1/2 + 1/2"
        case .threeThirds: return "1/3 × 3"
        case .halfTwoQuarters: return "1/2 + 1/4 + 1/4"
        }
    }

    var maxWindows: Int {
        switch self {
        case .twoHalves: return 2
        case .threeThirds, .halfTwoQuarters: return 3
        }
    }

    func next() -> StrategyID {
        let all = StrategyID.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    func previous() -> StrategyID {
        let all = StrategyID.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx - 1 + all.count) % all.count]
    }
}

struct AppPreferences: Codable, Equatable {
    /// Named profile / space key → strategy
    var strategiesByKey: [String: String] = [:]
    var autoRetile: Bool = true
    var paused: Bool = false
    /// For half-two-quarters: true = half on left; false = half on right
    var halfOnLeft: Bool = true
    var defaultStrategy: String = StrategyID.twoHalves.rawValue
    /// Active named profile when Space id is unavailable
    var activeProfileKey: String = "Default"
    var profileNames: [String] = ["Default", "Coding", "Writing"]
    /// true when we could not bind to real macOS Space ids
    var spaceDetectionDegraded: Bool = true

    func strategy(for key: String) -> StrategyID {
        if let raw = strategiesByKey[key], let s = StrategyID(rawValue: raw) {
            return s
        }
        return StrategyID(rawValue: defaultStrategy) ?? .twoHalves
    }

    mutating func setStrategy(_ strategy: StrategyID, for key: String) {
        strategiesByKey[key] = strategy.rawValue
    }
}

struct ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let frame: CGRect
    let isFocused: Bool
}

enum TilerMessage: Equatable {
    case needAccessibility
    case unsupportedWindow
    case tooManyWindows(max: Int)
    case paused
    case info(String)
    case none
}
