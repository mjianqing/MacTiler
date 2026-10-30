import Foundation
import CoreGraphics

struct LayoutEngine {
    /// Vertical-strip tiles L→R inside AppKit `workArea` (PRD v1.2).
    /// Slot count comes from the strategy, not from how many windows are visible:
    /// fewer windows only fill the leading slots; empty slots stay empty (never
    /// collapse the sole window to the full workArea).
    /// Strip widths are integerized (floor); the last *strategy* strip eats the
    /// remainder so full layouts never overlap or leave a sub-pixel gap.
    static func frames(
        strategy: StrategyID,
        windowCount: Int,
        workArea: CGRect
    ) -> (frames: [CGRect], effective: StrategyID, overflowHint: Int?) {
        guard windowCount > 0 else {
            return ([], strategy, nil)
        }

        var effective = strategy
        var overflow: Int? = nil
        // With exactly 2 windows, 3-slot strategies degrade to two-halves.
        // maximize (1 slot) must NOT degrade — only first window fills workArea.
        if windowCount == 2 && strategy.maxWindows >= 3 {
            effective = .twoHalves
        }
        if windowCount > effective.maxWindows {
            overflow = effective.maxWindows
        }

        let fractions = effective.stripFractions
        let allSlots = verticalStrips(workArea: workArea, fractions: fractions)
        let count = min(windowCount, allSlots.count)
        return (Array(allSlots.prefix(count)), effective, overflow)
    }

    /// Lay out every strategy strip. Last strip absorbs flooring remainder of workArea.
    private static func verticalStrips(workArea: CGRect, fractions: [CGFloat]) -> [CGRect] {
        var rects: [CGRect] = []
        let y = floor(workArea.minY)
        let height = max(1, floor(workArea.height))
        var x = floor(workArea.minX)
        let maxX = floor(workArea.maxX)
        let totalW = max(1, maxX - x)
        let n = fractions.count
        for i in 0..<n {
            let isLast = (i == n - 1)
            let width: CGFloat
            if isLast {
                width = max(1, maxX - x)
            } else {
                width = max(1, floor(totalW * fractions[i]))
            }
            rects.append(CGRect(x: x, y: y, width: width, height: height))
            x += width
        }
        return rects
    }
}
