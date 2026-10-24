import ApplicationServices
import Foundation

/// Follows the typing caret of the focused text field, so the ✦ button can step aside when the caret reaches it.
/// Polls the Accessibility API on its own queue (a slow app must not stall the UI) and reports the caret's box in
/// AX coordinates (top-left origin) on the main queue, only when it moves; nil when the app doesn't report one.
final class CaretTracker {
    /// Called on the main queue.
    var onChange: ((CGRect?) -> Void)?

    private let queue = DispatchQueue(label: "CaretTracker")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var element: AXUIElement?
    private var last: CGRect?   // confined to `queue`

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// The field to follow, or nil when no field is focused.
    func follow(_ field: AXUIElement?) {
        lock.lock(); element = field; lock.unlock()
        queue.async { [weak self] in self?.last = nil }
    }

    private func tick() {
        lock.lock(); let field = element; lock.unlock()
        guard let field else { return }
        let box = Self.caretBox(of: field)
        guard box != last else { return }
        last = box
        DispatchQueue.main.async { [onChange] in onChange?(box) }
    }

    /// A thin box at the caret (or at the end of the selection), rounded so tiny jitter does not count as movement.
    static func caretBox(of field: AXUIElement) -> CGRect? {
        guard let raw = AX.attr(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &selection) else { return nil }
        let caret = selection.location + selection.length

        func box(_ x: CGFloat, _ r: CGRect) -> CGRect {
            CGRect(x: x.rounded(), y: r.minY.rounded(), width: 0, height: r.height.rounded())
        }
        // 1. A zero-length range at the caret: exact where the app supports it.
        if let r = bounds(field, CFRange(location: caret, length: 0)), r.height > 0 { return box(r.minX, r) }
        // 2. Else the character before the caret, whose right edge is the caret (not after a line break: that
        //    character sits at the end of the previous line).
        if caret > 0, !isLineBreak(field, CFRange(location: caret - 1, length: 1)),
           let r = bounds(field, CFRange(location: caret - 1, length: 1)), r.height > 0 { return box(r.maxX, r) }
        // 3. Else the character after it: its left edge is the caret.
        if let r = bounds(field, CFRange(location: caret, length: 1)), r.height > 0 { return box(r.minX, r) }
        return nil
    }

    private static func bounds(_ field: AXUIElement, _ range: CFRange) -> CGRect? {
        var query = range
        guard let axRange = AXValueCreate(.cfRange, &query) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
              let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func isLineBreak(_ field: AXUIElement, _ range: CFRange) -> Bool {
        var query = range
        guard let axRange = AXValueCreate(.cfRange, &query) else { return false }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
              let text = out as? String else { return false }
        return text.contains("\n") || text.contains("\r") || text.contains("\u{2028}") || text.contains("\u{2029}")
    }
}
