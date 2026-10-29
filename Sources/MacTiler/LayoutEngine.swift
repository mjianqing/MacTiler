import Foundation
import CoreGraphics

struct LayoutEngine {
    /// Vertical-strip tiles L→R inside AppKit `workArea` (PRD v1.2).
    static func frames(
        strategy: StrategyID,
        windowCount: Int,
        workArea: CGRect
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
        let fractions: [CGFloat]
        switch effective {
        case .twoHalves:
            fractions = [0.5, 0.5]
        case .threeThirds:
            fractions = [1.0/3, 1.0/3, 1.0/3]
        case .quartersQuartersHalf:
            fractions = [0.25, 0.25, 0.5]
        case .halfQuartersQuarters:
            fractions = [0.5, 0.25, 0.25]
        case .quarterHalfQuarter:
            fractions = [0.25, 0.5, 0.25]
        }

        return (verticalStrips(workArea: workArea, fractions: fractions, count: count), effective, overflow)
    }

    private static func verticalStrips(workArea: CGRect, fractions: [CGFloat], count: Int) -> [CGRect] {
        var rects: [CGRect] = []
        var x = workArea.minX
        let n = min(count, fractions.count)
        for i in 0..<n {
            let isLast = (i == n - 1)
            let width = isLast ? (workArea.maxX - x) : (workArea.width * fractions[i])
            rects.append(CGRect(x: x, y: workArea.minY, width: width, height: workArea.height))
            x += width
        }
        return rects
    }
}
