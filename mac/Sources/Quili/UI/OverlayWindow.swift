import AppKit

/// A panel that never becomes key or main, so clicking it leaves keyboard focus in the field below.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the collapsed round button, and — as `expansion` goes 0 → 1 — a white pill growing to its left
/// with the action buttons (Settings, Tone, Summarize, Translate to English, Paraphrase).
private final class OverlayView: NSView {
    static let actionWidth: CGFloat = 36
    var onAction: ((TextAction) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    /// The pointer moved onto (true) or off (false) the Tone button.
    var onToneHover: ((Bool) -> Void)?
    /// The pointer moved onto (true) or off (false) the Paraphrase button; the History bar follows it.
    var onParaphraseHover: ((Bool) -> Void)?
    /// The tooltip text for the part under the pointer, or nil when there is none (the pointer left, or is pressing).
    var onTooltip: ((String?) -> Void)?
    /// Dragging: called once when a drag starts, then with each movement in screen points (Cocoa coordinates).
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    private var dragLast = NSPoint.zero, dragOrigin = NSPoint.zero
    private var dragging = false
    private static let dragThreshold: CGFloat = 4
    /// While busy, the round button turns into "Cancel" on hover. The click that started the request must
    /// not cancel it, so the pointer has to leave the button first.
    private var cancelReady = false
    var busy = false {
        didSet {
            needsDisplay = true
            if busy {
                hovered = nil
                pressed = nil
                let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
                cancelReady = mouse.map { region(at: $0) != .circle } ?? true
                startSpinning()
            } else {
                spinTimer?.invalidate()
                spinTimer = nil
            }
        }
    }

    // Hover / press feedback so the buttons read as clickable.
    private enum Region: CaseIterable { case settings, tone, summarize, translate, paraphrase, circle }
    private var hovered: Region? {
        didSet {
            guard hovered != oldValue else { return }
            startHoverAnimation()
            updateCursor()
            if (hovered == .tone) != (oldValue == .tone) { onToneHover?(hovered == .tone) }
            if (hovered == .paraphrase) != (oldValue == .paraphrase) { onParaphraseHover?(hovered == .paraphrase) }
            onTooltip?(hovered.map(tooltipText) ?? nil)
        }
    }
    private var pressed: Region? { didSet { if pressed != oldValue { startHoverAnimation() } } }
    private var hoverAmount: [Region: CGFloat] = [:]   // 0…1, eased toward the target each frame
    private var pressAmount: [Region: CGFloat] = [:]
    private var hoverTimer: Timer?
    private var spinAngle: CGFloat = 90
    private var spinTimer: Timer?
    var expansion: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Which edge of the field the pill is docked to; the corners touching the field are squared off.
    enum Dock { case floating, belowField, aboveField }
    /// Outer corner radius when docked: a slightly softened edge rather than a pill.
    static let dockedRadius: CGFloat = 5
    var dock = Dock.floating { didSet { needsDisplay = true } }
    /// The actions fade in a beat after the pill starts opening (and out first when closing).
    private var actionAlpha: CGFloat { min(1, max(0, (expansion - 0.3) / 0.7)) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The sparkle paraphrases and EN translates to English; the round button ("Text Tool") only cancels a running request.
    /// What each part is called, shown as its tooltip. The round button reads "Cancel" while a request runs.
    private func tooltipText(_ region: Region) -> String? {
        switch region {
        case .settings: return "Settings"
        case .tone: return "Tone"
        case .summarize: return "Summarize"
        case .translate: return "Translate to English"
        case .paraphrase: return "Paraphrase"
        case .circle: return busy ? "Cancel" : "Text Tool"
        }
    }

    /// The hovered part's rectangle in Cocoa screen coordinates (nil when nothing is hovered).
    var hoveredScreenRect: NSRect? {
        guard let hovered, let window else { return nil }
        let h = bounds.height, w = Self.actionWidth
        let x: CGFloat
        switch hovered {
        case .circle: x = bounds.width - h
        case .paraphrase: x = paraphraseMinX
        case .translate: x = paraphraseMinX - w
        case .summarize: x = paraphraseMinX - 2 * w
        case .tone: x = paraphraseMinX - 3 * w
        case .settings: x = paraphraseMinX - 4 * w
        }
        let width = hovered == .circle ? h : w
        return window.convertToScreen(convert(NSRect(x: x, y: 0, width: width, height: h), to: nil))
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragLast = dragOrigin
        dragging = false
        onTooltip?(nil)
        if busy {
            if hovered == .circle { pressed = .circle }
            return
        }
        pressed = region(at: convert(event.locationInWindow, from: nil))
    }

    // Press and move more than a few points to pick the button up; a click without movement runs the action.
    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if !dragging {
            guard abs(now.x - dragOrigin.x) >= Self.dragThreshold || abs(now.y - dragOrigin.y) >= Self.dragThreshold else { return }
            dragging = true
            pressed = nil
            onDragStart?()
        }
        updateCursor()
        onDrag?(now.x - dragLast.x, now.y - dragLast.y)
        dragLast = now
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
        if dragging { dragging = false; return }
        if busy {
            if hovered == .circle { onCancel?() }
            return
        }
        // Only the action buttons start work; the green button is a drag handle (and Cancel while busy).
        switch region(at: convert(event.locationInWindow, from: nil)) {
        case .settings: onSettings?()
        case .translate: onAction?(.translateToEnglish)
        case .summarize: onAction?(.summarizeText)
        case .paraphrase: onAction?(.paraphrase)
        default: break
        }
    }

    private func region(at point: NSPoint) -> Region? {
        if point.x >= bounds.width - bounds.height { return .circle }
        guard expansion > 0.5 else { return nil }
        if point.x >= paraphraseMinX { return .paraphrase }
        if point.x >= paraphraseMinX - Self.actionWidth { return .translate }
        if point.x >= paraphraseMinX - 2 * Self.actionWidth { return .summarize }
        if point.x >= paraphraseMinX - 3 * Self.actionWidth { return .tone }
        if point.x >= paraphraseMinX - 4 * Self.actionWidth { return .settings }
        return nil
    }

    /// Always the regular arrow. The panel never becomes key and the app is usually inactive, so the app underneath
    /// would otherwise keep its own cursor (the text I-beam) over the button; it is claimed on every pointer event.
    private func updateCursor() { NSCursor.arrow.set() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepHover() }
        }
    }

    private func stepHover() {
        var settled = true
        for region in Region.allCases {
            if !approach(&hoverAmount[region, default: 0], to: hovered == region ? 1 : 0, step: 0.13) { settled = false }
            if !approach(&pressAmount[region, default: 0], to: pressed == region ? 1 : 0, step: 0.24) { settled = false }
        }
        needsDisplay = true
        if settled { hoverTimer?.invalidate(); hoverTimer = nil }
    }

    /// Moves `value` one step toward `target`; true once it has arrived.
    private func approach(_ value: inout CGFloat, to target: CGFloat, step: CGFloat) -> Bool {
        if abs(target - value) <= step { value = target; return true }
        value += value < target ? step : -step
        return false
    }

    /// Grows a hovered button and shrinks a pressed one, around `center`.
    private func drawScaled(_ region: Region, around center: NSPoint, _ body: () -> Void) {
        let hover = hoverAmount[region] ?? 0, press = pressAmount[region] ?? 0
        // Idle while a request runs; docked to a field, the green button doesn't zoom either.
        let still = busy || (region == .circle && dock != .floating)
        let scale = still ? 1 : (1 + (region == .circle ? 0.08 : 0.10) * hover) * (1 - 0.12 * press)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.scale(by: scale)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var paraphraseMinX: CGFloat { bounds.width - bounds.height - Self.actionWidth }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        updateCursor()
        onHover?(true)
        mouseMoved(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        updateCursor()
        let region = region(at: convert(event.locationInWindow, from: nil))
        if busy {
            if region != .circle { cancelReady = true }
            hovered = cancelReady && region == .circle ? .circle : nil
        } else {
            hovered = region
        }
    }
    override func mouseExited(with event: NSEvent) {
        cancelReady = true
        hovered = nil
        pressed = nil
        onHover?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height

        if expansion > 0.01 {
            let r = dock == .floating ? h / 2 : Self.dockedRadius
            let pill = Self.roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5),
                                        top: dock == .belowField ? 0 : r, bottom: dock == .aboveField ? 0 : r)
            NSColor.white.withAlphaComponent(expansion).setFill()
            pill.fill()
            NSColor.black.withAlphaComponent(0.15 * expansion).setStroke()
            pill.lineWidth = 1
            pill.stroke()

            // Actions are anchored to the round button, so they slide out with the pill. Each is 36×26, centred.
            let paraphrase = NSRect(x: paraphraseMinX, y: 1, width: Self.actionWidth, height: h - 2)
            let translate = paraphrase.offsetBy(dx: -Self.actionWidth, dy: 0)
            let summarize = translate.offsetBy(dx: -Self.actionWidth, dy: 0)
            let tone = summarize.offsetBy(dx: -Self.actionWidth, dy: 0)
            let settings = tone.offsetBy(dx: -Self.actionWidth, dy: 0)

            for (region, rect) in [(Region.paraphrase, paraphrase), (Region.translate, translate), (Region.summarize, summarize),
                                      (Region.tone, tone), (Region.settings, settings)] {
                drawScaled(region, around: NSPoint(x: rect.midX, y: rect.midY)) {
                    // A soft green highlight fades in behind the hovered action; same corners as the pill:
                    // square on the side docked to the field, soft on the other.
                    Brand.green.withAlphaComponent(0.18 * (hoverAmount[region] ?? 0) * actionAlpha).setFill()
                    let r = dock == .floating ? rect.height / 2 : Self.dockedRadius
                    Self.roundedPath(rect, top: dock == .belowField ? 0 : r, bottom: dock == .aboveField ? 0 : r).fill()

                    let color = Brand.green.withAlphaComponent(actionAlpha)
                    func glyph(_ path: NSBezierPath, _ side: CGFloat) {
                        Glyph.fill(path, in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                                   color: color, viewBox: 24)
                    }
                    switch region {
                    case .paraphrase: glyph(Glyph.sparkle, 18)
                    case .settings: glyph(Glyph.gear, 17)
                    case .tone: glyph(Glyph.tune, 17)
                    case .summarize: glyph(Glyph.notes, 17)
                    default:
                        let label = NSAttributedString(string: "EN", attributes: [
                            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: color,
                        ])
                        let size = label.size()
                        label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                    }
                }
            }
        }

        // The green button starts 1 point below the pill's top and is 2 points shorter than the pill.
        let circle = NSRect(x: bounds.width - h, y: 0, width: h, height: h).insetBy(dx: 1, dy: 1)
        drawScaled(.circle, around: NSPoint(x: circle.midX, y: circle.midY)) { drawCircleButton(circle) }
    }

    private func drawCircleButton(_ circle: NSRect) {
        let cancel = busy ? hoverAmount[.circle] ?? 0 : 0
        (Brand.green.blended(withFraction: cancel, of: Brand.red) ?? Brand.green).setFill()
        let radius = dock == .floating ? min(circle.width, circle.height) / 2 : Self.dockedRadius
        Self.roundedPath(circle, top: dock == .belowField ? 0 : radius, bottom: dock == .aboveField ? 0 : radius).fill()

        if busy {
            // A 14-point ring stroked 2 wide: the stroke is centred on a circle of radius 6.
            let spinner = circle.insetBy(dx: 7, dy: 7)
            let center = NSPoint(x: spinner.midX, y: spinner.midY)
            let radius = spinner.width / 2

            let track = NSBezierPath(ovalIn: spinner)
            track.lineWidth = 2
            Brand.robotInk.withAlphaComponent(0.2 * (1 - cancel)).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: spinAngle, endAngle: spinAngle + 105, clockwise: false)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            Brand.robotInk.withAlphaComponent(1 - cancel).setStroke()
            arc.stroke()

            if cancel > 0 {
                let mark = circle.insetBy(dx: 8.5, dy: 8.5) // a 12-point cross with 1.5 of margin, as on Windows
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: mark.minX, y: mark.minY)); cross.line(to: NSPoint(x: mark.maxX, y: mark.maxY))
                cross.move(to: NSPoint(x: mark.minX, y: mark.maxY)); cross.line(to: NSPoint(x: mark.maxX, y: mark.minY))
                cross.lineWidth = 2
                cross.lineCapStyle = .round
                NSColor.white.withAlphaComponent(cancel).setStroke()
                cross.stroke()
            }
        } else {
            Glyph.drawRobot(in: circle.insetBy(dx: 5, dy: 5))
        }
    }

    private func startSpinning() {
        guard spinTimer == nil else { return }
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.spinAngle -= 7 // clockwise
                self.needsDisplay = true
            }
        }
    }

    /// Rounded rect whose top corners share one radius and bottom corners another (Cocoa: y grows upward).
    private static func roundedPath(_ rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX + top, y: rect.maxY))
        p.line(to: NSPoint(x: rect.maxX - top, y: rect.maxY))
        if top > 0 { p.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX, y: rect.maxY - top), radius: top) }
        p.line(to: NSPoint(x: rect.maxX, y: rect.minY + bottom))
        if bottom > 0 { p.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX - bottom, y: rect.minY), radius: bottom) }
        p.line(to: NSPoint(x: rect.minX + bottom, y: rect.minY))
        if bottom > 0 { p.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX, y: rect.minY + bottom), radius: bottom) }
        p.line(to: NSPoint(x: rect.minX, y: rect.maxY - top))
        if top > 0 { p.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX + top, y: rect.maxY), radius: top) }
        p.close()
        return p
    }
}

@MainActor
final class OverlayWindow {
    private static let size: CGFloat = 28, expandedWidth: CGFloat = 210, margin: CGFloat = 6, wideFieldFactor: CGFloat = 10, dockOffset: CGFloat = 6, edgeSearch = 14
    // Time-based easing (not a fixed step per tick) so the pill glides at the display's frame rate.
    private static let expandDuration: TimeInterval = 0.23, collapseDuration: TimeInterval = 0.17

    private let panel: OverlayPanel
    private let view: OverlayView
    private var animation: Timer?
    private var animFrom: CGFloat = 0, animTarget: CGFloat = 0
    private var animStart = Date(), animDuration: TimeInterval = 0.2

    // Origin of the round button (Cocoa coordinates); the pill grows to the left of it.
    private var anchor = NSPoint.zero
    /// Where the overlay currently is, in AX coordinates (top-left origin); null until first shown. Edge detection skips it.
    private var overlayArea = CGRect.null
    private var expansion: CGFloat = 0
    private var hovered = false
    private var userMoved = false   // the user dragged the button; keep it there until focus moves to another field
    // Stepping aside for the typing caret: `baseAnchor` is the default place, `shifted` says the button is one button
    // width to the right of it because the caret was under it.
    private var baseAnchor = NSPoint.zero
    private var shifted = false
    private var lastCaret: CGRect?   // AX coordinates
    private var restX: CGFloat = 0   // where the button is, or is sliding to, horizontally
    private static let caretGap: CGFloat = 5
    private var slide: Timer?
    private var slideFrom: CGFloat = 0, slideTo: CGFloat = 0, slideStart = Date()
    private static let slideDuration: TimeInterval = 0.16

    var onAction: ((TextAction) -> Void)? { didSet { view.onAction = onAction } }
    var onCancel: (() -> Void)? { didSet { view.onCancel = onCancel } }
    var onSettings: (() -> Void)? { didSet { view.onSettings = onSettings } }
    private let tooltip = TooltipWindow()
    private var tooltipTask: Task<Void, Never>?
    private static let tooltipDelay: UInt64 = 400_000_000
    /// Tooltip text for the part of the pill under the pointer. Which side it goes on is the opposite of the tone bar's
    /// for the Tone button, so the two never overlap.
    private func tooltipChanged(_ text: String?) {
        tooltipTask?.cancel()
        tooltip.hide()
        guard let text else { return }
        tooltipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.tooltipDelay)
            guard !Task.isCancelled, let self, let rect = self.view.hoveredScreenRect else { return }
            self.tooltip.show(text, near: rect, preferAbove: (text == "Tone" || text == "Paraphrase") && !self.chipsPreferAbove)
        }
    }

    /// The pointer entered (true) or left (false) the Tone button; the tone bar follows it.
    var onToneHover: ((Bool) -> Void)? { didSet { view.onToneHover = onToneHover } }
    /// The pointer entered (true) or left (false) the Paraphrase button; the History bar follows it.
    var onParaphraseHover: ((Bool) -> Void)? { didSet { view.onParaphraseHover = onParaphraseHover } }
    private(set) var isBusy = false
    /// Keeps the pill open while the pointer is on the tone bar (a separate window next to it); it collapses when the
    /// pointer is off the pill and the bar.
    var keepExpanded = false { didSet { if keepExpanded != oldValue { startAnimating() } } }
    /// Whether the tone bar goes above the pill: not when the pill is docked below its field, where "above" is the field.
    var chipsPreferAbove: Bool { view.dock != .belowField }

    /// The overlay's current frame in Cocoa screen coordinates; the preview bubble anchors to it.
    var frame: NSRect { panel.frame }
    /// Where the Tone button is (Cocoa screen coordinates): the fourth cell left of the round button.
    var toneArea: NSRect {
        NSRect(x: panel.frame.maxX - Self.size - 4 * OverlayView.actionWidth, y: panel.frame.minY,
               width: OverlayView.actionWidth, height: panel.frame.height)
    }
    /// Where the Paraphrase button is: the cell just left of the round button.
    var paraphraseArea: NSRect {
        NSRect(x: panel.frame.maxX - Self.size - OverlayView.actionWidth, y: panel.frame.minY,
               width: OverlayView.actionWidth, height: panel.frame.height)
    }

    init() {
        let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        view = OverlayView(frame: rect)
        panel = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view.onTooltip = { [weak self] text in self?.tooltipChanged(text) }
        view.onHover = { [weak self] inside in
            self?.hovered = inside
            self?.startAnimating()
        }
        // Dragging: docked (design 2) it turns into the floating pill (design 1) as soon as it is picked up.
        view.onDragStart = { [weak self] in
            self?.slide?.invalidate()
            self?.userMoved = true
            self?.view.dock = .floating
        }
        view.onDrag = { [weak self] dx, dy in self?.moveAnchor(dx: dx, dy: dy) }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        view.busy = busy
        startAnimating() // collapse while busy, re-expand if still hovered afterwards
    }

    private func moveAnchor(dx: CGFloat, dy: CGFloat) {
        var x = anchor.x + dx, y = anchor.y + dy
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let v = screen.visibleFrame
            x = max(v.minX + (Self.expandedWidth - Self.size), min(x, v.maxX - Self.size))
            y = max(v.minY, min(y, v.maxY - Self.size))
        }
        anchor = NSPoint(x: x, y: y)
        applyLayout()
        updateOverlayArea()
    }

    /// The window is always its full width in AX terms, as on Windows: the pill grows inside it.
    private func updateOverlayArea() {
        guard let primary = NSScreen.screens.first else { return }
        let s = Self.size, w = Self.expandedWidth
        overlayArea = CGRect(x: anchor.x - (w - s), y: primary.frame.height - (anchor.y + s), width: w, height: s)
    }

    func hide() {
        tooltipChanged(nil)
        overlayArea = .null
        slide?.invalidate()
        slide = nil
        shifted = false
        lastCaret = nil
        userMoved = false // focus lost: the next field starts from its default placement
        animation?.invalidate()
        animation = nil
        animTarget = 0
        hovered = false
        expansion = 0
        keepExpanded = false // after the reset, so it does not start a collapse animation
        view.expansion = 0
        panel.orderOut(nil)
    }

    /// Places the button at the right edge of `axFrame` (global coordinates, top-left origin): floating inside wide fields,
    /// docked below (or above) narrower ones.
    /// When `sameField` is true and the user has dragged the button, it stays where they put it.
    func show(at axFrame: CGRect, sameField: Bool = false) {
        if userMoved && sameField { return }
        userMoved = false
        if !sameField { lastCaret = nil }
        guard let primary = NSScreen.screens.first else { return }
        let s = Self.size
        // AX y grows downward from the primary screen's top edge; Cocoa y grows upward from its bottom edge.
        var x = axFrame.maxX - s - Self.margin
        var y: CGFloat
        var dock = OverlayView.Dock.floating

        if axFrame.width >= s * Self.wideFieldFactor {
            // Design 1, wide field: a free-floating pill inside it, centred on short fields and at the
            // bottom-right of taller ones.
            y = axFrame.height <= s * 3
                ? primary.frame.height - axFrame.midY - s / 2
                : primary.frame.height - (axFrame.maxY - Self.margin)
        } else {
            // Design 2, narrower field: the button would cover its text, so dock it to the bottom edge like a
            // tab (to the top edge when there is no room under it), with the corners that touch the field
            // squared off on both the green button and the pill.
            // The focused element is usually the inner input; the field's visible border is a little further out.
            // Look at the screen pixels just past the element to find it, and put the top of the pill on that border
            // (falling back to a fixed offset when nothing can be measured).
            dock = .belowField
            let edge = FieldEdge.find(axFrame, below: true, maxExtra: Self.edgeSearch, avoid: overlayArea)
                ?? Int(axFrame.maxY + Self.dockOffset)
            y = primary.frame.height - (CGFloat(edge) + s)
            let screenBottom = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: x, y: y + s)) })?.visibleFrame.minY ?? 0
            if y < screenBottom {
                let topEdge = FieldEdge.find(axFrame, below: false, maxExtra: Self.edgeSearch, avoid: overlayArea)
                    ?? Int(axFrame.minY - Self.dockOffset)
                y = primary.frame.height - CGFloat(topEdge + 1)
                dock = .aboveField
            }
        }
        view.dock = dock

        let probe = NSRect(x: x, y: y, width: s, height: s)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(probe) }) {
            let v = screen.visibleFrame
            x = max(v.minX, min(x, v.maxX - s))
            y = max(v.minY, min(y, v.maxY - s))
        }
        slide?.invalidate()
        baseAnchor = NSPoint(x: x, y: y)
        shifted = caretIsUnderButton()
        restX = shifted ? steppedAsideX() : x
        anchor = NSPoint(x: restX, y: y)
        applyLayout()
        updateOverlayArea()
        panel.orderFrontRegardless()
        DebugLog.write("overlay placed at \(Int(x)),\(Int(y)) size \(Int(s)) design=\(dock == .floating ? 1 : 2)")
    }

    // MARK: Stepping aside for the caret

    /// The typing caret moved (AX coordinates), or nil when it is unknown. While it is under the button the button
    /// slides one button width to the right so the text stays visible, and it slides back once the caret has left.
    func avoid(caret: CGRect?) {
        lastCaret = caret
        guard !userMoved, panel.isVisible, !isBusy else { return }
        let wanted = caretIsUnderButton()
        let target = wanted ? steppedAsideX() : baseAnchor.x
        // Also follows the caret while it keeps moving under the button, so the gap to it stays the same.
        guard wanted != shifted || abs(target - restX) > 0.5 else { return }
        shifted = wanted
        restX = target
        slideAnchor(to: target)
    }

    /// Whether the caret is at the button's default place (judged there, not where the button is now, so it does not
    /// flip back and forth around its own new position).
    private func caretIsUnderButton() -> Bool {
        guard let caret = lastCaret, let primary = NSScreen.screens.first else { return false }
        let s = Self.size
        let button = CGRect(x: baseAnchor.x, y: primary.frame.height - (baseAnchor.y + s), width: s, height: s)
            .insetBy(dx: -6, dy: -4)
        return button.intersects(caret.insetBy(dx: -2, dy: 0))
    }

    /// Where the button goes when the caret is under it: its left edge `caretGap` to the right of the caret (one button
    /// width to the right of the default place when the caret is unknown), never left of the default place, and kept
    /// on the screen.
    private func steppedAsideX() -> CGFloat {
        let s = Self.size
        var x = max(baseAnchor.x, (lastCaret?.maxX ?? baseAnchor.x + s - Self.caretGap) + Self.caretGap)
        let probe = NSRect(x: baseAnchor.x, y: baseAnchor.y, width: s, height: s)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(probe) }) { x = min(x, screen.visibleFrame.maxX - s) }
        return max(baseAnchor.x, x)
    }

    private func slideAnchor(to x: CGFloat) {
        slideFrom = anchor.x
        slideTo = x
        slideStart = Date()
        guard slide == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.slideTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        slide = timer
    }

    private func slideTick() {
        let t = min(1, Date().timeIntervalSince(slideStart) / Self.slideDuration)
        let eased = 1 - pow(1 - CGFloat(t), 3)
        anchor.x = slideFrom + (slideTo - slideFrom) * eased
        applyLayout()
        updateOverlayArea()
        if t >= 1 {
            slide?.invalidate()
            slide = nil
        }
    }

    private func applyLayout() {
        let s = Self.size
        // Whole-pixel frame: a fractional width/origin makes the round button shimmer while the pill grows.
        let width = (s + (Self.expandedWidth - s) * expansion).rounded()
        view.expansion = expansion
        panel.setFrame(NSRect(x: (anchor.x - (width - s)).rounded(), y: anchor.y.rounded(), width: width, height: s),
                       display: true)
    }

    /// Eases the pill toward open (hovered, idle) or closed, starting from where it is now.
    private func startAnimating() {
        let target: CGFloat = (hovered || keepExpanded) && !isBusy ? 1 : 0
        if animation != nil ? target == animTarget : target == expansion { return }

        animFrom = expansion
        animTarget = target
        animDuration = target > expansion ? Self.expandDuration : Self.collapseDuration
        animStart = Date()
        guard animation == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common) // keep animating while the mouse is tracked
        animation = timer
    }

    private func tick() {
        let t = min(1, Date().timeIntervalSince(animStart) / animDuration)
        let eased = 1 - pow(1 - CGFloat(t), 3) // ease-out cubic
        expansion = animFrom + (animTarget - animFrom) * eased
        applyLayout()
        if t >= 1 {
            animation?.invalidate()
            animation = nil
        }
    }
}
