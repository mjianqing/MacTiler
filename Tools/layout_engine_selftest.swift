#!/usr/bin/env swift
import Foundation
import CoreGraphics

// Minimal mirrors of StrategyID + LayoutEngine for offline verification.
enum StrategyID: String {
    case twoHalves = "two-halves"
    case threeThirds = "three-thirds"
    case quartersQuartersHalf = "quarters-quarters-half"
    case halfQuartersQuarters = "half-quarters-quarters"
    case quarterHalfQuarter = "quarter-half-quarter"
    var maxWindows: Int { self == .twoHalves ? 2 : 3 }
    var stripFractions: [CGFloat] {
        switch self {
        case .twoHalves: return [0.5, 0.5]
        case .threeThirds: return [1.0/3, 1.0/3, 1.0/3]
        case .quartersQuartersHalf: return [0.25, 0.25, 0.5]
        case .halfQuartersQuarters: return [0.5, 0.25, 0.25]
        case .quarterHalfQuarter: return [0.25, 0.5, 0.25]
        }
    }
}

struct LayoutEngine {
    static func frames(strategy: StrategyID, windowCount: Int, workArea: CGRect)
        -> (frames: [CGRect], effective: StrategyID, overflowHint: Int?) {
        guard windowCount > 0 else { return ([], strategy, nil) }
        var effective = strategy
        var overflow: Int? = nil
        if windowCount == 2 && strategy != .twoHalves { effective = .twoHalves }
        if windowCount > effective.maxWindows { overflow = effective.maxWindows }
        let allSlots = verticalStrips(workArea: workArea, fractions: effective.stripFractions)
        let count = min(windowCount, allSlots.count)
        return (Array(allSlots.prefix(count)), effective, overflow)
    }
    private static func verticalStrips(workArea: CGRect, fractions: [CGFloat]) -> [CGRect] {
        var rects: [CGRect] = []
        let y = floor(workArea.minY)
        let height = max(1, floor(workArea.height))
        var x = floor(workArea.minX)
        let maxX = floor(workArea.maxX)
        let totalW = max(1, maxX - x)
        for i in 0..<fractions.count {
            let width: CGFloat = (i == fractions.count - 1)
                ? max(1, maxX - x)
                : max(1, floor(totalW * fractions[i]))
            rects.append(CGRect(x: x, y: y, width: width, height: height))
            x += width
        }
        return rects
    }
}

func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 1) -> Bool { abs(a - b) <= tol }

var failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("PASS \(name)") }
    else { print("FAIL \(name)"); failed += 1 }
}

let wa = CGRect(x: 0, y: 0, width: 1440, height: 900)

// 1 window + two-halves → left half only, NOT full workArea
let r1 = LayoutEngine.frames(strategy: .twoHalves, windowCount: 1, workArea: wa)
check("1win two-halves count=1", r1.frames.count == 1)
check("1win two-halves not full", !approx(r1.frames[0].width, wa.width) && approx(r1.frames[0].width, 720))
check("1win two-halves left", approx(r1.frames[0].minX, 0))

// 2 windows → two halves
let r2 = LayoutEngine.frames(strategy: .twoHalves, windowCount: 2, workArea: wa)
check("2win count=2", r2.frames.count == 2)
check("2win left half", approx(r2.frames[0].width, 720))
check("2win right half", approx(r2.frames[1].width, 720))
check("2win abut", approx(r2.frames[0].maxX, r2.frames[1].minX))
check("2win cover", approx(r2.frames[1].maxX, wa.maxX))

// 1 window + three-thirds → first third only
let r3 = LayoutEngine.frames(strategy: .threeThirds, windowCount: 1, workArea: wa)
check("1win thirds ~1/3", r3.frames.count == 1 && approx(r3.frames[0].width, floor(1440.0/3)))

// 4 windows overflow hint
let r4 = LayoutEngine.frames(strategy: .twoHalves, windowCount: 4, workArea: wa)
check("overflow hint", r4.overflowHint == 2 && r4.frames.count == 2)

// 2 windows + three-thirds degrades to two-halves
let r5 = LayoutEngine.frames(strategy: .threeThirds, windowCount: 2, workArea: wa)
check("2win thirds→halves", r5.effective == .twoHalves && r5.frames.count == 2)

// Odd workArea width: halves differ by ≤1pt, abut, and cover full workArea (Anna equal+fill)
let waOdd = CGRect(x: -604, y: 900, width: 2561, height: 1440)
let rOdd = LayoutEngine.frames(strategy: .twoHalves, windowCount: 2, workArea: waOdd)
check("odd count=2", rOdd.frames.count == 2)
check("odd abut", approx(rOdd.frames[0].maxX, rOdd.frames[1].minX))
check("odd cover", approx(rOdd.frames[1].maxX, waOdd.maxX))
check("odd left at minX", approx(rOdd.frames[0].minX, waOdd.minX))
let dw = abs(rOdd.frames[0].width - rOdd.frames[1].width)
check("odd equal≤1pt", dw <= 1)
check("odd sum=work", approx(rOdd.frames[0].width + rOdd.frames[1].width, floor(waOdd.maxX) - floor(waOdd.minX)))

if failed == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("FAILED \(failed)")
    exit(1)
}
