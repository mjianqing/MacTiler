import Foundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

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

/// Carbon-style hotkey (keyCode + modifiers). Defaults avoid ⌘⇧3/4 (PRD).
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultRegion = HotKeySpec(keyCode: 1, carbonModifiers: UInt32(controlKey | optionKey | cmdKey)) // S
    static let defaultDisplay = HotKeySpec(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey | cmdKey)) // A

    var displayString: String {
        var parts: [String] = []
        let m = Int(carbonModifiers)
        if m & controlKey != 0 { parts.append("⌃") }
        if m & optionKey != 0 { parts.append("⌥") }
        if m & shiftKey != 0 { parts.append("⇧") }
        if m & cmdKey != 0 { parts.append("⌘") }
        parts.append(Self.keyCodeName(keyCode))
        return parts.joined()
    }

    /// Forbidden as MacTiler defaults: system screenshot chords ⌘⇧3 / ⌘⇧4 / ⌘⇧5.
    var looksLikeSystemScreenshotDefault: Bool {
        let m = Int(carbonModifiers)
        let cmdShift = (m & cmdKey != 0) && (m & shiftKey != 0) && (m & controlKey == 0) && (m & optionKey == 0)
        return cmdShift && (keyCode == 20 || keyCode == 21 || keyCode == 23) // 3,4,5
    }

    private static func keyCodeName(_ code: UInt32) -> String {
        // Common ANSI letter/digit map (Carbon virtual key codes).
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
            28: "8", 29: "0", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return map[code] ?? "⌨\(code)"
    }
}

/// PRD v1.2: one current strategy; no per-Space memory; no halfOnLeft mirror.
struct AppPreferences: Codable, Equatable {
    var currentStrategy: String = StrategyID.twoHalves.rawValue
    var autoRetile: Bool = true
    var paused: Bool = false
    var spaceMemoryDisabled: Bool = true
    var saveScreenshotToDesktop: Bool = false
    var screenshotRegionHotKey: HotKeySpec = .defaultRegion
    var screenshotDisplayHotKey: HotKeySpec = .defaultDisplay

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
    /// Successful retile — always presented (never silent).
    case retiled(count: Int)
    case none
}
