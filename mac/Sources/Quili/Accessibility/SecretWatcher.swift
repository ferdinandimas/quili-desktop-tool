import ApplicationServices
import Foundation

/// What the focused field's text looks like right now: how many distinct secrets it holds and which button is the
/// likely next step. Everything is worked out on this computer; nothing is sent.
struct FieldHints: Equatable {
    var secrets = 0
    var suggestion = ActionSuggestion.none
}

/// Polls the focused field's text every 600 ms on its own queue (a slow app must not stall the UI) and reports the
/// hints on the main queue, only when they change. Stops reporting (and reports nothing) while no field is followed.
final class SecretWatcher {
    private static let maxChars = 20_000

    /// Called on the main queue.
    var onChange: ((FieldHints) -> Void)?
    /// Whether emails count as secrets is decided by the setting; they never do for the warning.
    private let queue = DispatchQueue(label: "SecretWatcher")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var element: AXUIElement?
    private var lastText: String?       // confined to `queue`
    private var last = FieldHints()     // confined to `queue`

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(600))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// The field to watch, or nil when no field is focused (the hints reset).
    func follow(_ field: AXUIElement?) {
        lock.lock(); element = field; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lastText = nil
            guard self.last != FieldHints() else { return }
            self.last = FieldHints()
            DispatchQueue.main.async { [onChange] in onChange?(FieldHints()) }
        }
    }

    private func tick() {
        lock.lock(); let field = element; lock.unlock()
        guard let field else { return }
        var text = AX.string(field, kAXValueAttribute) ?? ""
        if text.count > Self.maxChars { text = String(text.prefix(Self.maxChars)) }
        guard text != lastText else { return }
        lastText = text
        let hints = FieldHints(secrets: Redactor.mask(text, emails: false).values.count,
                               suggestion: ActionSuggestion.forText(text))
        guard hints != last else { return }
        last = hints
        DispatchQueue.main.async { [onChange] in onChange?(hints) }
    }
}
