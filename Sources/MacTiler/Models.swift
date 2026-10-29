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

/// MVP prefs: one global current strategy; no per-Space / profile memory (PRD v1.1).
struct AppPreferences: Codable, Equatable {
    var currentStrategy: String = StrategyID.twoHalves.rawValue
    var autoRetile: Bool = true
    var paused: Bool = false
    /// For half-two-quarters: true = half on left; false = half on right
    var halfOnLeft: Bool = true
    /// MVP does not remember per-desktop strategy (Anna 2026-10-29).
    var spaceMemoryDisabled: Bool = true

    var strategy: StrategyID {
        StrategyID(rawValue: currentStrategy) ?? .twoHalves
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
