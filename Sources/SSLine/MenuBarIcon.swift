import AppKit

/// The line in miniature: a taut line with two cards clipped to it. Drawn
/// as a template image so it follows the menu bar's light and dark looks.
enum MenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { bounds in
            NSColor.black.setFill()
            let lineThickness: CGFloat = 1.8
            let lineTop = bounds.maxY - 2.5
            NSRect(x: 0, y: lineTop - lineThickness, width: bounds.width, height: lineThickness).fill()

            let cardTop = lineTop - lineThickness - 1.6
            let cardSize = NSSize(width: 6.5, height: 8)
            let clipHeight: CGFloat = 2.6
            for (centerX, tilt) in [(bounds.width * 0.28, -4.0), (bounds.width * 0.72, 3.0)] {
                let card = NSRect(x: centerX - cardSize.width / 2, y: cardTop - cardSize.height,
                                  width: cardSize.width, height: cardSize.height)
                let path = NSBezierPath(roundedRect: card, xRadius: 1.3, yRadius: 1.3)
                path.appendRect(NSRect(x: card.midX - 0.8, y: card.maxY - 0.3, width: 1.6, height: clipHeight))
                let pivot = NSPoint(x: card.midX, y: card.maxY + clipHeight)
                var transform = AffineTransform(translationByX: pivot.x, byY: pivot.y)
                transform.rotate(byDegrees: tilt)
                transform.translate(x: -pivot.x, y: -pivot.y)
                path.transform(using: transform)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SSLine"
        return image
    }
}
