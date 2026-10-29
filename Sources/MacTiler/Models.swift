import Foundation
import CoreGraphics
import ApplicationServices

enum StrategyID: String, CaseIterable, Codable, Equatable {
    case twoHalves = "two-halves"
    case threeThirds = "three-thirds"
    case quartersQuartersHalf = "quarters-quarters-half" // 1/4 | 1/4 | 1/2
    case halfQuartersQuarters = "half-quarters-quarters" // 1/2 | 1/4 | 1/4
    case quarterHalfQuarter = "quarter-half-quarter"     // 1/4 | 1/2 | 1/4

    var displayName: String {
        switch self {
        case .twoHalves: return "1/2 | 1/2"
        case .threeThirds: return "1/3 | 1/3 | 1/3"
        case .quartersQuartersHalf: return "1/4 | 1/4 | 1/2"
        case .halfQuartersQuarters: return "1/2 | 1/4 | 1/4"
        case .quarterHalfQuarter: return "1/4 | 1/2 | 1/4"
        }
    }

    var maxWindows: Int {
        switch self {
        case .twoHalves: return 2
        default: return 3
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

    /// Migrate legacy strategy ids from older prefs / interim names.
    static func migrated(from raw: String) -> StrategyID {
        if let s = StrategyID(rawValue: raw) { return s }
        switch raw {
        case "half-two-quarters", "half-left":
            return .halfQuartersQuarters
        case "quarters-left":
            return .quartersQuartersHalf
        case "half-center":
            return .quarterHalfQuarter
        default:
            return .twoHalves
        }
    }
}

/// PRD v1.2: one current strategy; no per-Space memory; no halfOnLeft mirror.
struct AppPreferences: Codable, Equatable {
    var currentStrategy: String = StrategyID.twoHalves.rawValue
    var autoRetile: Bool = true
    var paused: Bool = false
    var spaceMemoryDisabled: Bool = true

    var strategy: StrategyID {
        StrategyID.migrated(from: currentStrategy)
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
