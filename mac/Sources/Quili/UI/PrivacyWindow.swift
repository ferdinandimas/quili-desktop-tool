import AppKit

// "Privacy & apps", opened from the Settings card (windows/src/UI/PrivacyWindow.xaml is its twin): what is hidden
// from the AI, and in which apps Quili's button appears. Built from the same pieces as the Settings card.

@MainActor
final class PrivacyWindow: NSObject {
    private let settings: Settings
    private let window: SettingsPanel
    private let redactSecrets = CheckRow(title: "Redact secrets before sending")
    private let redactEmails = CheckRow(title: "Also redact email addresses")
    private let onlyListed = CheckRow(title: "Only show Quili in the apps listed below")
    private let appsView = NSTextView()

    init(settings: Settings) {
        self.settings = settings

        let width: CGFloat = 520, pad: CGFloat = 28, inner: CGFloat = 464, labelX: CGFloat = 76, fieldWidth: CGFloat = 416

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.sizeToFit()
            return l
        }
        /// A wrapped muted paragraph `width` wide at (x, y); returns its bottom.
        func note(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, in content: NSView) -> CGFloat {
            let note = NSTextField(wrappingLabelWithString: text)
            note.font = .systemFont(ofSize: 13.5)
            note.textColor = Brand.muted
            let height = ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 36)
            note.frame = NSRect(x: x, y: y, width: width, height: height)
            content.addSubview(note)
            return note.frame.maxY
        }

        let content = FlippedView(frame: .zero)
        var frames: [FieldFrame] = []

        // Header: 90 tall.
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 90))
        let robot = RobotBadge(frame: NSRect(x: pad, y: 20, width: 50, height: 50))
        let title = label("Quili", size: 23, weight: .bold, color: Brand.ink)
        let subtitle = label("Privacy & apps", size: 15, color: Brand.muted)
        let titleTop = 20 + (50 - (title.frame.height + subtitle.frame.height)) / 2
        title.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop))
        subtitle.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop + title.frame.height))
        let close = IconButton(path: Glyph.close, side: 34, glyph: 14, color: Brand.hex(0x44514A))
        close.frame.origin = NSPoint(x: width - 18 - 34, y: 20)
        [robot, title, subtitle, close].forEach(header.addSubview)
        content.addSubview(header)

        var y: CGFloat = 90 + 24

        // Redaction
        let privacyBadge = BadgeView(Glyph.eyeOff)
        privacyBadge.frame.origin = NSPoint(x: pad, y: y)
        let privacyTitle = label("Before sending", size: 17, weight: .semibold, color: Brand.ink)
        privacyTitle.setFrameOrigin(NSPoint(x: labelX, y: y + (34 - privacyTitle.frame.height) / 2))
        [privacyBadge, privacyTitle].forEach(content.addSubview)
        y += 34 + 14

        redactSecrets.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(redactSecrets)
        y += 26 + 6
        y = note("Keys, tokens and passwords are swapped for placeholders before the text leaves your computer, and put back in the answer.",
                 x: pad + 2 + 26 + 14, y: y, width: inner - 2 - 26 - 14, in: content) + 14

        redactEmails.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(redactEmails)
        y += 26 + 24

        // Apps
        let appsBadge = BadgeView(Glyph.doc)
        appsBadge.frame.origin = NSPoint(x: pad, y: y)
        let appsTitle = label("Apps", size: 17, weight: .semibold, color: Brand.ink)
        appsTitle.setFrameOrigin(NSPoint(x: labelX, y: y + (34 - appsTitle.frame.height) / 2))
        [appsBadge, appsTitle].forEach(content.addSubview)
        y += 34 + 14

        onlyListed.frame.origin = NSPoint(x: pad + 2, y: y)
        content.addSubview(onlyListed)
        y += 26 + 6
        y = note("One per line, using the app's name or bundle id (for example: Slack, com.tinyspeck.slackmacgap). Quili's ✦ button is hidden in these apps — or shown only in them when the box above is ticked. The Summarize button for Slack threads is not affected.",
                 x: pad, y: y, width: inner, in: content) + 10

        let appsFrame = FieldFrame(frame: NSRect(x: pad, y: y, width: inner, height: 120))
        frames.append(appsFrame)
        content.addSubview(appsFrame)
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 12, width: inner - 18 - 10, height: 96))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        appsView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 96)
        appsView.minSize = NSSize(width: 0, height: 96)
        appsView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        appsView.isVerticallyResizable = true
        appsView.isHorizontallyResizable = false
        appsView.autoresizingMask = [.width]
        appsView.textContainer?.widthTracksTextView = true
        appsView.textContainer?.lineFragmentPadding = 0
        appsView.textContainerInset = .zero
        appsView.isRichText = false
        appsView.allowsUndo = true
        appsView.drawsBackground = false
        appsView.font = .systemFont(ofSize: 15)
        appsView.textColor = Brand.ink
        appsView.insertionPointColor = Brand.ink
        appsView.isAutomaticQuoteSubstitutionEnabled = false
        appsView.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = appsView
        appsFrame.addSubview(scroll)
        y += 120 + 22

        // Divider and footer
        let divider = NSView(frame: NSRect(x: pad, y: y, width: inner, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Brand.hex(0xE6ECE8).cgColor
        content.addSubview(divider)
        y += 1 + 18

        let cancelButton = PillButton(title: "Cancel", primary: false, size: NSSize(width: 108, height: 46))
        let saveButton = PillButton(title: "Save", primary: true, size: NSSize(width: 150, height: 46))
        let glow = PillButton.glow
        cancelButton.frame.origin = NSPoint(x: pad + inner - 108 - glow, y: y - glow)
        saveButton.frame.origin = NSPoint(x: pad + inner - 108 - 12 - 150 - glow, y: y - glow)
        content.addSubview(saveButton); content.addSubview(cancelButton)
        y += 46 + 22

        // The card, with its soft green shadow, inside a transparent window with room for it.
        let cardHeight = y
        let margin: CGFloat = 30
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: cardHeight + 2 * margin))
        let card = NSView(frame: NSRect(x: margin, y: margin, width: width, height: cardHeight))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 26
        card.layer?.shadowColor = Brand.greenInk.cgColor
        card.layer?.shadowOpacity = 0.20
        card.layer?.shadowRadius = 16
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        content.frame = card.bounds
        content.wantsLayer = true
        content.layer?.cornerRadius = 26
        content.layer?.masksToBounds = true
        card.addSubview(content)
        card.addSubview(CardBorder(frame: card.bounds))
        root.addSubview(card)

        window = SettingsPanel(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        window.title = "Quili – Privacy & apps"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.fieldFrames = frames
        super.init()

        window.onCancel = { [weak self] in self?.window.close() }
        close.onClick = { [weak self] in self?.window.close() }
        cancelButton.onClick = { [weak self] in self?.window.close() }
        saveButton.onClick = { [weak self] in self?.save() }
    }

    func show() {
        redactSecrets.checked = settings.redactSecrets
        redactEmails.checked = settings.redactEmails
        onlyListed.checked = settings.appFilterMode == AppFilter.onlyMode
        appsView.string = settings.appFilterList
        window.center()
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        _ = window.makeFirstResponder(appsView)
    }

    private func save() {
        settings.redactSecrets = redactSecrets.checked
        settings.redactEmails = redactEmails.checked
        settings.appFilterMode = onlyListed.checked ? AppFilter.onlyMode : AppFilter.hideMode
        settings.appFilterList = appsView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.write("privacy settings saved: redactSecrets=\(settings.redactSecrets) redactEmails=\(settings.redactEmails) appFilter=\(settings.appFilterMode) (\(AppFilter.parse(settings.appFilterList).count) entries)")
        window.close()
    }
}
