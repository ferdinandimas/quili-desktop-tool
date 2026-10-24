import AppKit

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card's content: white rounded rect with the text, showing the newest lines when it is too long.
private final class BubbleView: NSView {
    static let maxTextWidth: CGFloat = 320, maxTextHeight: CGFloat = 150, tallTextHeight: CGFloat = 440
    static let padX: CGFloat = 12, padY: CGFloat = 9
    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Brand.robotInk, .paragraphStyle: style]
    }()

    var text = "" { didSet { needsDisplay = true } }
    /// A tall bubble (a summary) reads from its first line instead of following the newest ones.
    var tall = false { didSet { needsDisplay = true } }
    /// Whether `**bold**` is rendered; a summary does, the original text shown by "Original" does not.
    var markdown = false { didSet { needsDisplay = true } }
    /// A closable bubble (the finished summary) reserves room for, and draws, a × at its top-right.
    var closable = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    /// A review bubble (a paraphrase or translation waiting to be applied): `highlights` (UTF-16 ranges of the text)
    /// are drawn in soft blue, and a footer holds the Discard and Apply buttons.
    var highlights: [NSRange] = [] { didSet { needsDisplay = true } }
    var actions = false { didSet { needsDisplay = true } }
    var onApply: (() -> Void)?
    var onDiscard: (() -> Void)?
    /// A muted note at the footer's left (what the review used as context); only drawn with `actions`.
    var footnote: String? { didSet { needsDisplay = true } }
    private var hoveredButton: Int? { didSet { if hoveredButton != oldValue { needsDisplay = true } } } // 0 Discard, 1 Apply
    static let footerHeight: CGFloat = 40, buttonHeight: CGFloat = 28, minActionsWidth: CGFloat = 210
    static let highlightFill = NSColor(srgbRed: 0xD6 / 255, green: 0xE8 / 255, blue: 0xFF / 255, alpha: 1)
    static let highlightInk = NSColor(srgbRed: 0x1F / 255, green: 0x4E / 255, blue: 0x8C / 255, alpha: 1)
    private var discardRect: NSRect { NSRect(x: applyRect.minX - 12 - 84, y: applyRect.minY, width: 84, height: Self.buttonHeight) }
    private var applyRect: NSRect {
        NSRect(x: bounds.maxX - Self.padX - 72, y: bounds.maxY - 8 - Self.buttonHeight, width: 72, height: Self.buttonHeight)
    }
    /// How far a tall bubble whose text is longer than the card has been scrolled with the mouse wheel.
    private var scrollOffset: CGFloat = 0
    static let closeExtra: CGFloat = 16, closeSize: CGFloat = 16
    private var closeRect: NSRect { NSRect(x: bounds.maxX - 8 - Self.closeSize, y: 8, width: Self.closeSize, height: Self.closeSize) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A closable bubble takes clicks, so it claims the regular arrow like the overlay does (see OverlayView).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func resetCursorRects() { if closable { addCursorRect(bounds, cursor: .arrow) } }
    override func cursorUpdate(with event: NSEvent) { if closable { NSCursor.arrow.set() } }
    override func mouseEntered(with event: NSEvent) { if closable { NSCursor.arrow.set() } }
    override func mouseExited(with event: NSEvent) { hoveredButton = nil }
    override func mouseMoved(with event: NSEvent) {
        if closable { NSCursor.arrow.set() }
        guard actions else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoveredButton = applyRect.contains(point) ? 1 : (discardRect.contains(point) ? 0 : nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if actions {
            if applyRect.contains(point) { onApply?(); return }
            if discardRect.contains(point) { onDiscard?(); return }
        }
        if closable, closeRect.insetBy(dx: -5, dy: -5).contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard tall else { return }
        scrollOffset -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        needsDisplay = true // draw() clamps the offset to the text
    }

    func resetScroll() {
        scrollOffset = 0
        needsDisplay = true
    }

    /// The text as drawn. With `markdown` (a summary) text between `**` pairs is bold and the markers are hidden; an
    /// unclosed `**` (the summary is still streaming) stays bold to the end. Other text is drawn as it is.
    static func attributed(_ text: String, markdown: Bool, highlights: [NSRange] = []) -> NSAttributedString {
        if !highlights.isEmpty {
            let drawn = NSMutableAttributedString(string: text, attributes: attributes)
            let whole = NSRange(location: 0, length: (text as NSString).length)
            for range in highlights {
                let clipped = NSIntersectionRange(range, whole)
                if clipped.length > 0 {
                    drawn.addAttributes([.backgroundColor: highlightFill, .foregroundColor: highlightInk], range: clipped)
                }
            }
            return drawn
        }
        guard markdown, text.contains("**") else { return NSAttributedString(string: text, attributes: attributes) }
        var bold: [NSAttributedString.Key: Any] = attributes
        bold[.font] = NSFont.boldSystemFont(ofSize: 13)
        let result = NSMutableAttributedString()
        var isBold = false
        for (index, piece) in text.components(separatedBy: "**").enumerated() {
            if index > 0 { isBold.toggle() }
            result.append(NSAttributedString(string: piece, attributes: isBold ? bold : attributes))
        }
        return result
    }

    private static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin]).height)
    }

    static let footnoteFont = NSFont.systemFont(ofSize: 12)
    static let footnoteInk = Brand.hex(0x6E7B73)

    /// The card size that fits `text`.
    static func size(for text: String, tall: Bool = false, closable: Bool = false, markdown: Bool? = nil,
                     actions: Bool = false, footnote: String? = nil) -> NSSize {
        let drawn = attributed(text, markdown: markdown ?? tall)
        let bounding = drawn.boundingRect(with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin])
        let height = min(tall ? tallTextHeight : maxTextHeight, textHeight(drawn, width: ceil(bounding.width)))
        let width = ceil(bounding.width) + padX * 2 + (closable ? closeExtra : 0)
        var footerWidth = minActionsWidth
        if actions, let footnote {
            // The note, a gap, then Discard and Apply (84 + 12 + 72), between the card's side paddings.
            footerWidth = max(footerWidth, ceil((footnote as NSString).size(withAttributes: [.font: footnoteFont]).width) + 12 + 168 + padX * 2)
        }
        return NSSize(width: actions ? max(width, footerWidth) : width,
                      height: height + padY * 2 + (actions ? footerHeight : 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        card.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        card.lineWidth = 1
        card.stroke()

        var inner = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        if closable {
            inner.size.width -= Self.closeExtra
            let x = closeRect.insetBy(dx: 3.5, dy: 3.5)
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: x.minX, y: x.minY)); cross.line(to: NSPoint(x: x.maxX, y: x.maxY))
            cross.move(to: NSPoint(x: x.maxX, y: x.minY)); cross.line(to: NSPoint(x: x.minX, y: x.maxY))
            cross.lineWidth = 1.6
            cross.lineCapStyle = .round
            Brand.muted.setStroke()
            cross.stroke()
        }
        if actions { inner.size.height -= Self.footerHeight }
        let drawn = Self.attributed(text, markdown: markdown, highlights: highlights)
        let full = Self.textHeight(drawn, width: inner.width)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inner).addClip()
        // Too long to fit: keep the newest lines in view.
        scrollOffset = max(0, min(scrollOffset, max(0, full - inner.height)))
        let top = tall ? inner.minY - scrollOffset : inner.minY + min(0, inner.height - full)
        drawn.draw(with: NSRect(x: inner.minX, y: top, width: inner.width, height: full), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        if actions { drawButtons() }
    }

    /// Discard (white, outlined) and Apply (green) in the footer; the hovered one is a shade stronger.
    private func drawButtons() {
        func pill(_ rect: NSRect, _ title: String, fill: NSColor, border: NSColor?, ink: NSColor) {
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: rect.height / 2, yRadius: rect.height / 2)
            fill.setFill()
            shape.fill()
            if let border {
                border.setStroke()
                shape.lineWidth = 1.5
                shape.stroke()
            }
            let label = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink])
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        if let footnote {
            let note = NSAttributedString(string: footnote, attributes: [.font: Self.footnoteFont, .foregroundColor: Self.footnoteInk])
            let size = note.size()
            note.draw(at: NSPoint(x: Self.padX, y: applyRect.midY - size.height / 2))
        }
        pill(discardRect, "Discard", fill: hoveredButton == 0 ? Brand.hex(0xF1F5F2) : .white, border: Brand.line, ink: Brand.ink)
        pill(applyRect, "Apply", fill: hoveredButton == 1 ? Brand.hex(0x1F9E43) : Brand.greenDeep, border: nil, ink: .white)
    }
}

/// A small always-on-top card next to the overlay button that shows the rewritten text as it streams in,
/// before it replaces the field's text. Click-through and never activated, so focus stays in the field.
@MainActor
final class BubbleWindow {
    private static let gap: CGFloat = 6
    private let panel: BubblePanel
    private let view = BubbleView(frame: .zero)
    private static let fadeSeconds: TimeInterval = 0.25
    private var fadeID = 0 // bumped by show/hide so a fade that was overtaken does not hide the new bubble

    init() {
        panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Called when the × of a closable bubble is clicked.
    var onClose: (() -> Void)? { didSet { view.onClose = onClose } }
    /// The Apply / Discard buttons of a review bubble.
    var onApply: (() -> Void)? { didSet { view.onApply = onApply } }
    var onDiscard: (() -> Void)? { didSet { view.onDiscard = onDiscard } }

    /// Shows `text` above `anchor` (Cocoa screen coordinates), or below it when there is no room. A `closable`
    /// bubble has a × and takes clicks (it stays until closed); the others are click-through. `markdown` (default: the
    /// same as `tall`) turns `**bold**` into bold text.
    /// A review bubble passes `actions: true` and the UTF-16 ranges of the changed words as `highlights`; it takes clicks.
    func show(_ text: String, above anchor: NSRect, tall: Bool = false, closable: Bool = false, markdown: Bool? = nil,
              highlights: [NSRange] = [], actions: Bool = false, footnote: String? = nil) {
        cancelFade()
        view.footnote = footnote
        view.highlights = highlights
        view.actions = actions
        panel.ignoresMouseEvents = !closable
        view.closable = closable
        view.tall = tall
        view.markdown = markdown ?? tall
        view.text = text
        let size = BubbleView.size(for: text, tall: tall, closable: closable, markdown: markdown, actions: actions, footnote: footnote)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.maxX - size.width
        var y = anchor.maxY + Self.gap
        if y + size.height > visible.maxY { y = anchor.minY - Self.gap - size.height }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// Fades the bubble out, then hides it (the × and the 5 s auto-close); a `show` or `hide` meanwhile cancels the fade.
    func fadeOut() {
        guard panel.isVisible else { return }
        fadeID += 1
        let id = fadeID
        panel.ignoresMouseEvents = true // already closing: no more clicks
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeID == id else { return }
                self.hide()
            }
        })
    }

    /// Stops a running fade and makes the panel fully opaque again.
    private func cancelFade() {
        fadeID += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        cancelFade()
        view.resetScroll()
        view.closable = false
        view.actions = false
        view.highlights = []
        view.footnote = nil
        view.text = ""
        panel.orderOut(nil)
    }
}
