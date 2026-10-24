import AppKit
import ApplicationServices

struct FieldText {
    let text: String
    let isSelection: Bool
    let range: AXValue?   // original selection, used to restore it before pasting
}

/// Reads and replaces text in the focused field. Reading prefers the Accessibility API; replacing goes
/// through the pasteboard + Cmd+A/V, which works in web and Electron editors where setting AXValue does not
/// trigger the page's input handlers. Deliberately not main-actor: the Accessibility calls can block for seconds
/// on an unresponsive target app, and that must not freeze the overlay's spinner and Cancel button.
enum TextAccess {
    static func read(_ el: AXUIElement) async -> FieldText {
        let selectionAttr = AX.attr(el, kAXSelectedTextAttribute)
        if let sel = selectionAttr as? String, !isBlank(sel) {
            let range = AX.attr(el, kAXSelectedTextRangeAttribute).map { $0 as! AXValue }
            // Web editors report emoji images as U+FFFC; the pasteboard copy carries the real characters.
            if TextHygiene.isUnreliable(sel) {
                DebugLog.write("AX selection damaged (\(TextHygiene.describe(sel))); reading via pasteboard")
                let copied = await copySelection()
                if !isBlank(copied) { return FieldText(text: copied, isSelection: true, range: range) }
            }
            return FieldText(text: sel, isSelection: true, range: range)
        }

        // No AX selection support: probe with Cmd+C.
        if selectionAttr == nil {
            let copied = await copySelection()
            if !isBlank(copied) { return FieldText(text: copied, isSelection: true, range: nil) }
        }

        if let whole = AX.string(el, kAXValueAttribute), !isBlank(whole) {
            if !TextHygiene.isUnreliable(whole) { return FieldText(text: whole, isSelection: false, range: nil) }
            DebugLog.write("AX text damaged (\(TextHygiene.describe(whole))); reading via pasteboard")
            pressCommand("a")
            let copied = await copySelection()
            return FieldText(text: isBlank(copied) ? whole : copied, isSelection: false, range: nil)
        }

        pressCommand("a")
        return FieldText(text: await copySelection(), isSelection: false, range: nil)
    }

    /// The text selected right now in the app `pid` (any element, editable or not): the focused element's selected
    /// text through the Accessibility API, else what Cmd+C copies. Empty when nothing is selected.
    static func readSelectedText(pid: pid_t) async -> String {
        let app = AXUIElementCreateApplication(pid)
        // Chromium / Electron / Firefox only build their accessibility tree when asked.
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
        }
        if let el = AX.focusedElement(ofApp: app), let sel = AX.attr(el, kAXSelectedTextAttribute) as? String,
           !isBlank(sel), !TextHygiene.isUnreliable(sel) {
            return sel
        }
        return await copySelection()
    }

    /// Whether a whole-field read is still what the field holds (so a reviewed result may replace it). A selection is
    /// checked when it is restored, and a field whose value cannot be read is given the benefit of the doubt.
    static func fieldUnchanged(_ field: FieldText, in el: AXUIElement) -> Bool {
        guard !field.isSelection, let now = AX.string(el, kAXValueAttribute) else { return true }
        return key(now) == key(field.text)
    }

    /// Pastes over the original selection, or over the whole field when nothing was selected.
    static func replace(_ field: FieldText, in el: AXUIElement, with text: String) async throws {
        // The user may have moved the selection while the request ran; put it back or give up.
        if field.isSelection, !(await restoreSelection(field, in: el)) {
            setPasteboard(text)
            throw ParaphraseError(message: "The selection changed while paraphrasing. The result was copied to the clipboard.")
        }

        try await paste(text, selectionOnly: field.isSelection, in: el)
    }

    /// Puts `original` back where `result` was written: over the whole field, or, when only a selection was replaced,
    /// over the first occurrence of `result` in the field (found through the Accessibility value and selected by its
    /// range). Throws, with the original left on the pasteboard, when the field no longer holds `result`.
    static func undo(_ field: FieldText, result: String, in el: AXUIElement) async throws {
        if field.isSelection {
            guard selectText(result, in: el) else {
                DebugLog.write("undo: could not find the result in the field")
                setPasteboard(field.text)
                throw ParaphraseError(message: "The original text was copied to the clipboard.")
            }
        }
        try await paste(field.text, selectionOnly: field.isSelection, in: el)
    }

    /// Selects the first occurrence of `text` in the field's value; false when it is not there or cannot be selected.
    private static func selectText(_ text: String, in el: AXUIElement) -> Bool {
        guard let value = AX.string(el, kAXValueAttribute) else { return false }
        let found = (value as NSString).range(of: text)
        guard found.location != NSNotFound else { return false }
        var range = CFRange(location: found.location, length: found.length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { return false }
        guard let now = AX.string(el, kAXSelectedTextAttribute), key(now, max: 30) == key(text, max: 30) else { return false }
        DebugLog.write("undo: result selected via AX range")
        return true
    }

    private static func paste(_ text: String, selectionOnly: Bool, in el: AXUIElement) async throws {
        let backup = NSPasteboard.general.string(forType: .string)
        setPasteboard(text)
        DebugLog.write("pasting (selectionOnly=\(selectionOnly))")
        if !selectionOnly { pressCommand("a") }
        pressCommand("v")
        await Pause.milliseconds(400) // let the target app read the pasteboard before restoring it

        // Confirm the paste landed; if not, leave the result on the pasteboard so it isn't lost.
        if let after = AX.string(el, kAXValueAttribute), !after.isEmpty, !key(after).contains(key(text, max: 15)) {
            DebugLog.write("paste did not land (field text unchanged)")
            throw ParaphraseError(message:
                "The text could not be replaced in this field. The result was copied to the clipboard; paste it with Cmd+V.")
        }
        DebugLog.write("paste verified")
        if let backup { setPasteboard(backup) }
    }

    private static func restoreSelection(_ field: FieldText, in el: AXUIElement) async -> Bool {
        if let range = field.range {
            if AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range) == .success {
                if let now = AX.string(el, kAXSelectedTextAttribute), !now.isEmpty, key(now, max: 30) == key(field.text, max: 30) {
                    DebugLog.write("selection restored via AX range")
                    return true
                }
                DebugLog.write("AX range select did not reproduce the selection; comparing via pasteboard")
            } else {
                DebugLog.write("range select failed")
            }
        }
        // No usable range: only proceed if the current selection is still the same text.
        let same = normalize(await copySelection()) == normalize(field.text)
        DebugLog.write("selection still the same via pasteboard: \(same)")
        return same
    }

    /// Letters/digits only, so emoji placeholders and whitespace differences don't matter when comparing.
    private static func key(_ s: String, max: Int = .max) -> String {
        String(s.filter { $0.isLetter || $0.isNumber }.prefix(max)).lowercased()
    }

    /// Cmd+C and return what landed on the pasteboard (empty if nothing was selected).
    private static func copySelection() async -> String {
        let pb = NSPasteboard.general
        let backup = pb.string(forType: .string)
        pb.clearContents()
        let before = pb.changeCount
        pressCommand("c")
        await Pause.milliseconds(200)
        let text = pb.changeCount != before ? (pb.string(forType: .string) ?? "") : ""
        if let backup { setPasteboard(backup) }
        return text
    }

    static func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Presses Cmd+letter, resolving the key from the current keyboard layout.
    private static func pressCommand(_ letter: Character) {
        let key = KeyboardLayout.keyCode(for: letter)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
