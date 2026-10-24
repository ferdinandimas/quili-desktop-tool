import AppKit

private final class ChipBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A rounded white card with a row of text chips (the tone choices, or Undo / Original).
private final class ChipBarView: NSView {
    static let padX: CGFloat = 6, padY: CGFloat = 5, chipPadX: CGFloat = 9, chipGap: CGFloat = 4, chipHeight: CGFloat = 24
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var chips: [String] = [] { didSet { hovered = nil; needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hovered: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func width(of chip: String) -> CGFloat {
        ceil((chip as NSString).size(withAttributes: [.font: font]).width) + chipPadX * 2
    }

    static func size(for chips: [String]) -> NSSize {
        let widths = chips.reduce(CGFloat(0)) { $0 + width(of: $1) }
        return NSSize(width: widths + chipGap * CGFloat(max(0, chips.count - 1)) + padX * 2, height: chipHeight + padY * 2)
    }

    private func chipRects() -> [NSRect] {
        var x = Self.padX
        return chips.map { chip in
            let rect = NSRect(x: x, y: Self.padY, width: Self.width(of: chip), height: Self.chipHeight)
            x = rect.maxX + Self.chipGap
            return rect
        }
    }

    private func index(at point: NSPoint) -> Int? { chipRects().firstIndex { $0.contains(point) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Always the regular arrow, claimed on every pointer event: the panel never becomes key and the app is usually
    /// inactive, so the app underneath would otherwise keep its own cursor (the text I-beam) over the bar.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        onHover?(false)
    }
    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        let now = index(at: convert(event.locationInWindow, from: nil))
        if now != hovered {
            hovered = now
            needsDisplay = true
        }
    }
    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onSelect?(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        card.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        card.lineWidth = 1
        card.stroke()

        for (i, rect) in chipRects().enumerated() {
            let isHovered = hovered == i
            if isHovered {
                Brand.greenTint.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: isHovered ? Brand.greenInk : Brand.ink]
            let label = chips[i] as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: rect.minX + Self.chipPadX, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// A small always-on-top card with a row of text chips next to the overlay. It takes clicks but is never activated,
/// so focus stays in the text field it belongs to.
@MainActor
final class ChipBarWindow {
    private static let gap: CGFloat = 6
    private let panel: ChipBarPanel
    private let view = ChipBarView(frame: .zero)

    /// A chip was clicked (its index in the list given to `show`).
    var onSelect: ((Int) -> Void)? { didSet { view.onSelect = onSelect } }
    /// The pointer entered (true) or left (false) the bar.
    var onHover: ((Bool) -> Void)? { didSet { view.onHover = onHover } }
    var isShown: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = ChipBarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Shows `chips` above `anchor` (Cocoa screen coordinates, usually the overlay's frame), right-aligned with it,
    /// or below it when `preferAbove` is false or there is no room. `centered` centres it on `anchor` instead.
    func show(_ chips: [String], anchor: NSRect, preferAbove: Bool, centered: Bool = false) {
        view.chips = chips
        let size = ChipBarView.size(for: chips)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = centered ? anchor.midX - size.width / 2 : anchor.maxX - size.width
        var y = preferAbove ? anchor.maxY + Self.gap : anchor.minY - Self.gap - size.height
        if y + size.height > visible.maxY { y = anchor.minY - Self.gap - size.height }
        if y < visible.minY { y = anchor.maxY + Self.gap }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
