import Foundation
import CoreGraphics

struct LayoutEngine {
    /// Compute tile frames inside `workArea` (already excludes menu bar / Dock).
    /// `halfOnLeft` only affects half-two-quarters.
    static func frames(
        strategy: StrategyID,
        windowCount: Int,
        workArea: CGRect,
        halfOnLeft: Bool
    ) -> (frames: [CGRect], effective: StrategyID, overflowHint: Int?) {
        guard windowCount > 0 else {
            return ([], strategy, nil)
        }

        if windowCount == 1 {
            return ([workArea], strategy, nil)
        }

        var effective = strategy
        var overflow: Int? = nil

        if windowCount == 2 && strategy != .twoHalves {
            effective = .twoHalves
        }

        if windowCount > effective.maxWindows {
            overflow = effective.maxWindows
        }

        let count = min(windowCount, effective.maxWindows)
        let tiles: [CGRect]

        switch effective {
        case .twoHalves:
            tiles = twoHalves(workArea: workArea, count: count)
        case .threeThirds:
            tiles = threeThirds(workArea: workArea, count: count)
        case .halfTwoQuarters:
            tiles = halfTwoQuarters(workArea: workArea, count: count, halfOnLeft: halfOnLeft)
        }

        return (tiles, effective, overflow)
    }

    private static func twoHalves(workArea: CGRect, count: Int) -> [CGRect] {
        let w = workArea.width / 2
        let left = CGRect(x: workArea.minX, y: workArea.minY, width: w, height: workArea.height)
        let right = CGRect(x: workArea.minX + w, y: workArea.minY, width: workArea.width - w, height: workArea.height)
        if count == 1 { return [left] }
        return [left, right]
    }

    private static func threeThirds(workArea: CGRect, count: Int) -> [CGRect] {
        let w = workArea.width / 3
        var rects: [CGRect] = []
        for i in 0..<count {
            let x = workArea.minX + CGFloat(i) * w
            let width = (i == 2) ? (workArea.maxX - x) : w
            rects.append(CGRect(x: x, y: workArea.minY, width: width, height: workArea.height))
        }
        return rects
    }

    private static func halfTwoQuarters(workArea: CGRect, count: Int, halfOnLeft: Bool) -> [CGRect] {
        let halfW = workArea.width / 2
        let quarterH = workArea.height / 2
        let half: CGRect
        let q1: CGRect
        let q2: CGRect

        if halfOnLeft {
            half = CGRect(x: workArea.minX, y: workArea.minY, width: halfW, height: workArea.height)
            q1 = CGRect(x: workArea.minX + halfW, y: workArea.minY + quarterH, width: workArea.width - halfW, height: workArea.height - quarterH)
            q2 = CGRect(x: workArea.minX + halfW, y: workArea.minY, width: workArea.width - halfW, height: quarterH)
        } else {
            half = CGRect(x: workArea.minX + halfW, y: workArea.minY, width: workArea.width - halfW, height: workArea.height)
            q1 = CGRect(x: workArea.minX, y: workArea.minY + quarterH, width: halfW, height: workArea.height - quarterH)
            q2 = CGRect(x: workArea.minX, y: workArea.minY, width: halfW, height: quarterH)
        }

        // Main (half) first, then upper quarter, then lower quarter.
        // Note: Cocoa/AX often use bottom-left origin; we keep geometric order consistent with CG.
        switch count {
        case 1: return [half]
        case 2: return [half, q1]
        default: return [half, q1, q2]
        }
    }
}
