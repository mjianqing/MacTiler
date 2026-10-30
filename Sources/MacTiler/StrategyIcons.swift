import AppKit

enum StrategyIcons {
    /// Menu / status-bar sized wireframe for a strategy (template image).
    static func image(for strategy: StrategyID, size: CGSize = CGSize(width: 22, height: 14), forStatusBar: Bool = false) -> NSImage {
        let fractions = strategy.stripFractions
        let imgSize = forStatusBar ? CGSize(width: 18, height: 12) : size
        let image = NSImage(size: imgSize, flipped: false) { rect in
            let inset: CGFloat = forStatusBar ? 0.5 : 1
            let outer = rect.insetBy(dx: inset, dy: inset)
            let stroke = NSBezierPath(roundedRect: outer, xRadius: 1.5, yRadius: 1.5)
            stroke.lineWidth = 1
            NSColor.black.setStroke()
            stroke.stroke()

            // Divider lines between strips (not after last).
            var x = outer.minX
            for (i, f) in fractions.enumerated() {
                let w = outer.width * f
                if i < fractions.count - 1 {
                    let divX = x + w
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: divX, y: outer.minY))
                    line.line(to: NSPoint(x: divX, y: outer.maxY))
                    line.lineWidth = 1
                    line.stroke()
                }
                x += w
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = strategy.accessibilityLabel
        return image
    }
}

extension StrategyID {
    /// Left→right strip widths summing to 1.
    var stripFractions: [CGFloat] {
        switch self {
        case .maximize: return [1.0]
        case .twoHalves: return [0.5, 0.5]
        case .threeThirds: return [1.0/3, 1.0/3, 1.0/3]
        case .quartersQuartersHalf: return [0.25, 0.25, 0.5]
        case .halfQuartersQuarters: return [0.5, 0.25, 0.25]
        case .quarterHalfQuarter: return [0.25, 0.5, 0.25]
        }
    }

    /// Short menu title: hotkey only (no fractions). Icon carries the layout.
    var menuTitle: String {
        switch self {
        case .maximize: return "⌃⌥⌘1"
        case .twoHalves: return "⌃⌥⌘2"
        case .threeThirds: return "⌃⌥⌘3"
        case .quartersQuartersHalf: return "⌃⌥⌘4"
        case .halfQuartersQuarters: return "⌃⌥⌘5"
        case .quarterHalfQuarter: return "⌃⌥⌘6"
        }
    }

    var menuKeyEquivalent: String {
        switch self {
        case .maximize: return "1"
        case .twoHalves: return "2"
        case .threeThirds: return "3"
        case .quartersQuartersHalf: return "4"
        case .halfQuartersQuarters: return "5"
        case .quarterHalfQuarter: return "6"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .maximize: return "铺满整屏"
        case .twoHalves: return "两等分竖条"
        case .threeThirds: return "三等分竖条"
        case .quartersQuartersHalf: return "窄窄宽竖条"
        case .halfQuartersQuarters: return "宽窄窄竖条"
        case .quarterHalfQuarter: return "窄宽窄竖条"
        }
    }
}
