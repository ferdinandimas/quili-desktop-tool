import AppKit

/// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
/// read → paraphrase → review → replace when the button is clicked.
@MainActor
final class ParaphraseController {
    private let settings: Settings
    private let tracker = FocusTracker()
    private let caret = CaretTracker()
    private let secretWatcher = SecretWatcher()
    private var hints = FieldHints()
    private let overlay = OverlayWindow()
    private let bubble = BubbleWindow()
    private let threadWatcher = ThreadWatcher()
    private let threadButton = ThreadButtonWindow()
    private var threadPane: ThreadPane?
    private var summaryDismissed = false // the × was clicked while the summary was still being made
    private var current: TextTarget?
    private var request: Task<Void, Never>?
    private var previewing = false // late streamed updates must not re-show the bubble after the request ended
    private var writing = false // once the field is being written, cancelling would leave it half-replaced

    // Tone chips (hover the Tone button), History (hover the Paraphrase button) and Undo / Original (after a replace).
    private let toneBar = ChipBarWindow()
    private let historyBar = ChipBarWindow()
    private let undoBar = ChipBarWindow()
    private enum HoverBar { case tone, history }
    private var wantedBar: HoverBar?
    private var toneButtonHovered = false, toneBarHovered = false
    private var historyButtonHovered = false, historyBarHovered = false
    private var barGrace: Task<Void, Never>?
    private static let barGraceMilliseconds: UInt64 = 250, undoSeconds: UInt64 = 15
    private static let undoChips = ["Undo", "Original"], historyChips = ["History"]
    private lazy var historyWindow = HistoryWindow(settings: settings)

    /// A paraphrase or translation waiting in the review bubble for Apply: nothing has been written to the field yet.
    private struct PendingReview {
        let element: AXUIElement
        let app: NSRunningApplication?
        let field: FieldText
        let result: String
        let action: TextAction
    }
    private var pending: PendingReview?

    /// What the last replace changed, so it can be undone or compared: the field as it was read and what was written.
    private struct UndoState {
        let element: AXUIElement
        let app: NSRunningApplication?
        let field: FieldText
        let result: String
    }
    private var undoState: UndoState?
    private var undoExpiry: Task<Void, Never>?
    private var showingOriginal = false

    init(settings: Settings) {
        self.settings = settings
        overlay.onAction = { [weak self] action in
            guard let self, self.request == nil, self.current != nil, !self.overlay.isBusy else { return }
            self.request = Task { await self.run(action) }
        }
        overlay.onSettings = { [weak self] in self?.onOpenSettings?() }
        overlay.onToneHover = { [weak self] inside in
            self?.toneButtonHovered = inside
            self?.hoverChanged()
        }
        overlay.onParaphraseHover = { [weak self] inside in
            self?.historyButtonHovered = inside
            self?.hoverChanged()
        }
        toneBar.onHover = { [weak self] inside in
            self?.toneBarHovered = inside
            self?.hoverChanged()
        }
        historyBar.onHover = { [weak self] inside in
            self?.historyBarHovered = inside
            self?.hoverChanged()
        }
        historyBar.onSelect = { [weak self] _ in
            guard let self else { return }
            self.wantedBar = nil
            self.updateBars()
            self.historyWindow.show()
        }
        toneBar.onSelect = { [weak self] index in
            guard let self, self.request == nil, self.current != nil, !self.overlay.isBusy, Tone.all.indices.contains(index) else { return }
            let tone = Tone.all[index]
            DebugLog.write("tone chip clicked: \(tone.id)")
            self.settings.tone = tone.id // the tone stays selected (also for the ✦ button and in Settings)
            self.wantedBar = nil
            self.updateBars()
            self.request = Task { await self.run(.paraphrase) }
        }
        undoBar.onSelect = { [weak self] index in
            guard let self else { return }
            if index == 0 { self.undo() } else { self.toggleOriginal() }
        }
        tracker.appAllowed = { [settings] names in
            AppFilter.allows(names, mode: settings.appFilterMode, list: settings.appFilterList)
        }
        overlay.onCancel = { [weak self] in
            guard let self, !self.writing else { return }
            DebugLog.write("cancel requested; dropping the connection")
            self.request?.cancel()
        }
        tracker.onChange = { [weak self] target in self?.targetChanged(target) }
        caret.onChange = { [weak self] box in self?.overlay.avoid(caret: box) }
        secretWatcher.onChange = { [weak self] hints in
            self?.hints = hints
            self?.applyHints()
        }
        bubble.onApply = { [weak self] in self?.applyPending() }
        bubble.onDiscard = { [weak self] in self?.clearPending(fade: true) }
        bubble.onClose = { [weak self] in
            guard let self else { return }
            if self.pending != nil { self.clearPending(fade: true); return } // the × of a review bubble discards it
            DebugLog.write("summary bubble closed (previewing=\(self.previewing))")
            // Clicked before the summary finished: stop the request too, and let the fade finish the job. Streamed
            // updates that are still on their way must not bring the bubble back.
            if self.previewing { self.summaryDismissed = true; self.request?.cancel() }
            self.showingOriginal = false
            self.bubble.fadeOut()
        }
        threadWatcher.onChange = { [weak self] pane in self?.threadPaneChanged(pane) }
        threadButton.onClick = { [weak self] in
            guard let self, let pane = self.threadPane else { return }
            self.summarizeThread(in: pane.app, below: self.threadButton.frame)
        }
    }

    /// The gear in the pill was clicked.
    var onOpenSettings: (() -> Void)?

    func start() {
        tracker.start()
        caret.start()
        secretWatcher.start()
        threadWatcher.start()
    }

    /// Puts the field's hints on the button: the ! when the text holds a secret (and the warning is on), and the
    /// suggested next button.
    private func applyHints() {
        overlay.setWarning(settings.warnSecrets && hints.secrets > 0)
        overlay.setSuggestion(hints.suggestion)
    }

    var paused: Bool {
        get { tracker.paused }
        set {
            tracker.paused = newValue
            threadWatcher.paused = newValue
            if newValue { overlay.hide(); bubble.hide(); threadButton.hide(); wantedBar = nil; pending = nil; clearUndo(); updateBars() }
        }
    }

    /// A thread pane opened, moved or closed in Slack: keep the Summarize button on it.
    private func threadPaneChanged(_ pane: ThreadPane?) {
        let appeared = (pane != nil) != (threadPane != nil)
        threadPane = pane
        guard let pane else { if appeared { DebugLog.write("thread button: hidden") }; threadButton.hide(); return }
        if appeared { DebugLog.write("thread button: beside Slack's Summarize thread button, frame=\(pane.frame)") }
        threadButton.show(besideButton: pane.frame)
    }

    private func targetChanged(_ target: TextTarget?) {
        // Keep the button where it is while a request is running; the result is validated afterwards.
        if overlay.isBusy { return }
        // Same field as before (just moved or resized): a button the user dragged stays where they put it.
        let sameField = target != nil && current != nil && CFEqual(current!.element, target!.element)
        current = target
        caret.follow(target?.element)
        if let target { overlay.show(at: target.frame, sameField: sameField) } else { overlay.hide() }
        if !sameField {
            secretWatcher.follow(target?.element)
            if hints != FieldHints() { hints = FieldHints() }
            applyHints()
            wantedBar = nil
            toneButtonHovered = false
            toneBarHovered = false
            historyButtonHovered = false
            historyBarHovered = false
            // Undo, and a review waiting for Apply, only make sense in the field they were made in.
            if let state = undoState, target == nil || !CFEqual(state.element, target!.element) { clearUndo() }
            if let waiting = pending, target == nil || !CFEqual(waiting.element, target!.element) { clearPending() }
        }
        updateBars()
    }

    // MARK: Tone and history bars, review, undo and compare

    /// The pointer moved over or off the Tone button, the Paraphrase button or one of their bars: the bar shows at once
    /// and hides after a short grace period, so crossing the gap between the button and the bar does not close it.
    private func hoverChanged() {
        barGrace?.cancel()
        if toneButtonHovered || toneBarHovered {
            wantedBar = .tone
            updateBars()
        } else if historyButtonHovered || historyBarHovered {
            wantedBar = .history
            updateBars()
        } else {
            barGrace = Task { [weak self] in
                await Pause.milliseconds(Self.barGraceMilliseconds)
                guard let self, !Task.isCancelled else { return }
                self.wantedBar = nil
                self.updateBars()
            }
        }
    }

    /// Shows the tone or history bar while it is wanted (and nothing is running), otherwise the Undo / Original bar
    /// while there is something to undo.
    private func updateBars() {
        let active = current != nil && !overlay.isBusy ? wantedBar : nil
        overlay.keepExpanded = active != nil // the pill stays open while the pointer is on the bar
        switch active {
        case .tone:
            if !toneBar.isShown {
                toneBar.show(Tone.all.map(\.label), anchor: overlay.toneArea, preferAbove: overlay.chipsPreferAbove, centered: true,
                             selected: Tone.all.firstIndex { $0.id == settings.tone })
            }
            historyBar.hide(); historyBarHovered = false
            undoBar.hide()
        case .history:
            if !historyBar.isShown {
                historyBar.show(Self.historyChips, anchor: overlay.paraphraseArea, preferAbove: overlay.chipsPreferAbove, centered: true)
            }
            toneBar.hide(); toneBarHovered = false
            undoBar.hide()
        case nil:
            toneBar.hide(); toneBarHovered = false
            historyBar.hide(); historyBarHovered = false
            if undoState != nil, current != nil, !overlay.isBusy {
                if !undoBar.isShown { undoBar.show(Self.undoChips, anchor: overlay.frame, preferAbove: overlay.chipsPreferAbove) }
            } else {
                undoBar.hide()
            }
        }
    }

    /// Drops a review that is waiting for Apply, and its bubble (faded out when `fade`).
    private func clearPending(fade: Bool = false) {
        guard pending != nil else { return }
        pending = nil
        if fade { bubble.fadeOut() } else { bubble.hide() }
    }

    /// The Apply button of the review bubble: writes the reviewed text into the field.
    private func applyPending() {
        guard let review = pending, request == nil, !overlay.isBusy else { return }
        pending = nil
        bubble.hide()
        request = Task { await self.runApply(review) }
    }

    private func runApply(_ review: PendingReview) async {
        defer { request = nil }
        overlay.setBusy(true)
        writing = true // the field is about to be written: no cancelling
        defer {
            writing = false
            overlay.setBusy(false)
            updateBars()
        }
        do {
            guard await regainFocus(review.element, app: review.app, clipboardText: review.result,
                                    what: "\(review.action.verb.lowercased())d") else { return }
            guard TextAccess.fieldUnchanged(review.field, in: review.element) else {
                DebugLog.write("apply: the field changed since it was read; nothing replaced")
                Notifier.show("Text changed", "The field changed while you were reviewing, so nothing was replaced. Run it again.")
                return
            }
            try await TextAccess.replace(review.field, in: review.element, with: review.result)
            DebugLog.write("field replaced (applied after review)")
            offerUndo(UndoState(element: review.element, app: review.app, field: review.field, result: review.result))
        } catch {
            DebugLog.write("\(review.action) apply failed: \(error.localizedDescription)")
            Notifier.show("\(review.action.verb) failed", error.localizedDescription)
        }
    }

    /// Adds a finished request to the History window's list (when "Keep my last 10 rewrites" is on).
    private func record(_ action: TextAction, app: String?, original: String, result: String) {
        guard settings.keepHistory else { return }
        HistoryStore.shared.add(kind: action.historyKind, app: app, original: original, result: result)
    }

    /// Remembers the replace that just happened for 15 seconds.
    private func offerUndo(_ state: UndoState) {
        undoState = state
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            await Pause.milliseconds(Self.undoSeconds * 1000)
            guard let self, !Task.isCancelled else { return }
            self.clearUndo()
            self.updateBars()
        }
    }

    private func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        undoState = nil
        undoBar.hide()
        if showingOriginal {
            showingOriginal = false
            bubble.hide()
        }
    }

    /// "Original": shows, or closes, the text as it was before the replace.
    private func toggleOriginal() {
        guard let state = undoState else { return }
        if showingOriginal {
            showingOriginal = false
            bubble.fadeOut()
            return
        }
        showingOriginal = true
        let anchor = undoBar.isShown ? overlay.frame.union(undoBar.frame) : overlay.frame
        bubble.show(state.field.text, above: anchor, tall: true, closable: true, markdown: false)
    }

    private func undo() {
        guard let state = undoState, request == nil, !overlay.isBusy else { return }
        DebugLog.write("undo clicked")
        clearUndo()
        request = Task { await self.runUndo(state) }
    }

    private func runUndo(_ state: UndoState) async {
        defer { request = nil }
        overlay.setBusy(true)
        writing = true // the field is about to be written: no cancelling
        defer {
            writing = false
            overlay.setBusy(false)
            updateBars()
        }
        do {
            guard await regainFocus(state.element, app: state.app, clipboardText: state.field.text, what: "original") else { return }
            try await TextAccess.undo(state.field, result: state.result, in: state.element)
            DebugLog.write("undo done")
        } catch {
            DebugLog.write("undo failed: \(error.localizedDescription)")
            Notifier.show("Couldn't undo automatically", "The original text was copied to the clipboard.")
        }
    }

    /// Makes sure `element` has the keyboard focus before it is written to, bringing its app forward when needed.
    /// When that fails `clipboardText` is left on the clipboard instead and false is returned.
    private func regainFocus(_ element: AXUIElement, app: NSRunningApplication?, clipboardText: String, what: String) async -> Bool {
        let (focused, front) = await FocusTracker.focusState(of: element)
        if focused && front { return true }
        DebugLog.write("target lost focus (focused=\(focused), foreground=\(front)); bringing it back")
        if await FocusTracker.restoreFocus(element, app: app) {
            DebugLog.write("focus restored")
            return true
        }
        DebugLog.write("could not restore focus; \(what) left on the clipboard")
        TextAccess.setPasteboard(clipboardText)
        Notifier.show("Focus changed", "The \(what) text was copied to the clipboard instead.")
        return false
    }

    /// Reads the Slack thread open in `app`'s window and shows its summary under `anchor` (the Summarize button, Cocoa
    /// screen coordinates). Never writes to Slack; the summary is also copied.
    func summarizeThread(in app: NSRunningApplication?, below anchor: NSRect) {
        guard request == nil, !overlay.isBusy else { return }
        request = Task { await self.runSummary(in: app, below: anchor) }
    }

    private func runSummary(in app: NSRunningApplication?, below anchor: NSRect) async {
        defer { request = nil }
        summaryDismissed = false
        clearUndo() // the summary takes over the bubble
        clearPending()
        let action = TextAction.summarizeThread
        guard AXIsProcessTrusted() else {
            Notifier.show("Accessibility permission needed",
                          "Allow Quili in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard let app, app.bundleIdentifier == ThreadReader.slackBundleId else {
            Notifier.show("Open a Slack thread first", "Switch to Slack, open the thread, then click the Summarize button.")
            return
        }
        DebugLog.write("summarize clicked (Slack pid \(app.processIdentifier))")
        previewing = true
        defer { previewing = false }
        // Closable from the start, so a slow summary can be dismissed (which also cancels it).
        bubble.show("Reading the thread…", above: anchor, tall: true, closable: true)

        do {
            let pid = app.processIdentifier
            let thread = await Task.detached { ThreadReader.read(pid: pid) }.value
            try Task.checkCancellation()
            guard let thread, thread.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
                bubble.hide()
                Notifier.show("No thread found", "Open the thread in Slack's side pane (click its replies link) and try again.")
                return
            }
            DebugLog.write("read \(thread.text.count) chars from the thread\(thread.truncated ? " (oldest messages dropped)" : "")")
            DebugLog.write("thread text to summarize:\n\(thread.text)")

            let result = try await ParaphraseClient.run(thread.text, settings: settings, action: action) { [weak self] partial in
                guard let self, self.previewing, !self.summaryDismissed else { return }
                self.bubble.show(partial, above: anchor, tall: true, closable: true)
            }
            guard !summaryDismissed else { return } // closed while the last of it was arriving
            TextAccess.setPasteboard(TextHygiene.slackMarkup(result))
            // The summary stays until it is closed with its ×.
            bubble.show(result, above: anchor, tall: true, closable: true)
            record(action, app: app.localizedName, original: "", result: result)
            Notifier.show("Thread summarized", "The summary was copied to the clipboard.")
        } catch is CancellationError {
            if !summaryDismissed { bubble.hide() } // a dismissed bubble is already fading out
        } catch let error as URLError where error.code == .cancelled {
            if !summaryDismissed { bubble.hide() }
        } catch {
            bubble.hide()
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
    }

    /// The ✦ / EN / Summarize buttons of the pill. A paraphrase or translation streams into a bubble and then waits
    /// there for Apply (the field is not touched until then); a summary stays in its bubble and is copied.
    private func run(_ action: TextAction) async {
        DebugLog.write("\(action) clicked (target=\(current == nil ? "none" : "set"), busy=\(overlay.isBusy))")
        // Declared first so every exit, including the guard below, frees the controller for the next click.
        defer { request = nil }
        guard let target = current, !overlay.isBusy else { return }
        overlay.setBusy(true)
        writing = false
        clearUndo() // a new request replaces what could be undone (and reuses the bubble)
        clearPending() // ... and a review that was still waiting
        barGrace?.cancel()
        wantedBar = nil
        updateBars()
        let targetApp = NSWorkspace.shared.frontmostApplication
        previewing = true
        var keepBubble = false // a review or a summary stays on screen after the request
        defer {
            previewing = false
            if !keepBubble { bubble.hide() }
            writing = false
            overlay.setBusy(false)
            updateBars()
        }

        do {
            let field = await TextAccess.read(target.element)
            DebugLog.write("read \(field.text.count) chars from field")
            guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Notifier.show("Nothing to \(action.verb.lowercased())", "The text field is empty.")
                return
            }

            if action == .summarizeText {
                keepBubble = true
                await summarize(text: field.text, app: targetApp?.localizedName, anchor: overlay.frame)
                return
            }

            // The text streams into a bubble beside the button while the model writes it; the field itself is
            // only touched once the final text is in and the user has pressed Apply.
            // With "Use the messages above as context" on, the last messages of the Slack conversation go along.
            var context: (text: String, count: Int)?
            if settings.useContext, action == .paraphrase || action == .translateToEnglish,
               targetApp?.bundleIdentifier == ThreadReader.slackBundleId {
                let pid = targetApp!.processIdentifier, input = target.element
                context = await Task.detached { ThreadReader.readContext(pid: pid, input: input) }.value
                try Task.checkCancellation()
            }
            let result = try await ParaphraseClient.run(field.text, settings: settings, action: action, context: context?.text) { [weak self] partial in
                guard let self, self.previewing else { return }
                self.bubble.show(partial, above: self.overlay.frame)
            }
            previewing = false
            record(action, app: targetApp?.localizedName, original: field.text, result: result)

            pending = PendingReview(element: target.element, app: targetApp, field: field, result: result, action: action)
            keepBubble = true
            bubble.show(result, above: overlay.frame, tall: true, closable: true, markdown: false,
                        highlights: TextDiff.changedRanges(original: field.text, result: result), actions: true,
                        footnote: context.map { $0.count == 1 ? "Used 1 message from Slack as context" : "Used \($0.count) messages from Slack as context" })
        } catch is CancellationError {
            DebugLog.write("\(action) cancelled by the user")
        } catch let error as URLError where error.code == .cancelled {
            DebugLog.write("\(action) cancelled by the user")
        } catch {
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
    }

    // MARK: Summarize selected text

    /// The menu-bar item "Summarize selected text": summarizes whatever is selected in the app in front (an editable
    /// field or not) and shows the summary next to the mouse pointer. Never writes anywhere; the summary is copied.
    func summarizeSelectedText() {
        guard request == nil, !overlay.isBusy else { return }
        request = Task { await self.runMenuSummary() }
    }

    private func runMenuSummary() async {
        defer { request = nil }
        guard AXIsProcessTrusted() else {
            Notifier.show("Accessibility permission needed",
                          "Allow Quili in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            Notifier.show("No text selected", "Select the text you want summarized in any app, then choose Summarize selected text.")
            return
        }
        let text = await TextAccess.readSelectedText(pid: front.processIdentifier)
        DebugLog.write("menu summarize: read \(text.count) chars selected in \(front.localizedName ?? "?")")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Notifier.show("No text selected", "Select the text you want summarized in any app, then choose Summarize selected text.")
            return
        }
        let pointer = NSEvent.mouseLocation
        await summarize(text: text, app: front.localizedName, anchor: NSRect(x: pointer.x, y: pointer.y, width: 1, height: 1))
    }

    /// Summarizes `text` into a tall, closable bubble at `anchor` (closing it before it is done cancels the request),
    /// copies the summary without its `**` markers and records it in the history.
    private func summarize(text: String, app: String?, anchor: NSRect) async {
        summaryDismissed = false
        clearUndo()
        clearPending()
        let action = TextAction.summarizeText
        previewing = true
        defer { previewing = false }
        bubble.show("Summarizing…", above: anchor, tall: true, closable: true)
        do {
            let result = try await ParaphraseClient.run(text, settings: settings, action: action) { [weak self] partial in
                guard let self, self.previewing, !self.summaryDismissed else { return }
                self.bubble.show(partial, above: anchor, tall: true, closable: true)
            }
            guard !summaryDismissed else { return } // closed while the last of it was arriving
            TextAccess.setPasteboard(result.replacingOccurrences(of: "**", with: ""))
            bubble.show(result, above: anchor, tall: true, closable: true)
            record(action, app: app, original: text, result: result)
            Notifier.show("Text summarized", "The summary was copied to the clipboard.")
        } catch is CancellationError {
            if !summaryDismissed { bubble.hide() }
        } catch let error as URLError where error.code == .cancelled {
            if !summaryDismissed { bubble.hide() }
        } catch {
            bubble.hide()
            DebugLog.write("\(action) failed: \(error.localizedDescription)")
            Notifier.show("\(action.verb) failed", error.localizedDescription)
        }
    }
}
