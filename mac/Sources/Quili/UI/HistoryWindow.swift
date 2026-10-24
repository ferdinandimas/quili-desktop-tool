import AppKit

// "Recent rewrites", opened from the History chip that shows when the pointer is on the Paraphrase button
// (windows/src/UI/HistoryWindow.xaml is its twin): the last 10 requests, newest first, each with Copy buttons.
// Built from the same pieces as the Settings card.

/// A small outlined chip that copies a text to the clipboard and reads "Copied" for a moment.
final class CopyChip: ClickView {
    private var title: String
    private let original: String
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let height: CGFloat = 24, padX: CGFloat = 12

    init(title: String, copying text: String) {
        self.title = title
        original = title
        let width = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + Self.padX * 2
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 84), height: Self.height))
        onClick = { [weak self] in
            TextAccess.setPasteboard(text)
            self?.title = "Copied"
            self?.needsDisplay = true
            Task { @MainActor [weak self] in
                await Pause.milliseconds(1500)
                self?.title = self?.original ?? ""
                self?.needsDisplay = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (hovered || title == "Copied" ? Brand.greenTint : NSColor.white).setFill()
        shape.fill()
        shape.lineWidth = 1
        (title == "Copied" ? Brand.green : Brand.line).setStroke()
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: hovered || title == "Copied" ? Brand.greenInk : Brand.ink,
        ]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// One request in the list.
private final class HistoryRow: FlippedView {
    init(entry: HistoryEntry, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 14

        func lineHeight(_ font: NSFont) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }
        /// A wrapped label of at most `lines` lines (cut with an ellipsis).
        func paragraph(_ text: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = font
            field.textColor = color
            field.maximumNumberOfLines = lines
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.preferredMaxLayoutWidth = width
            // The wrapped height: the cell reports one line for a truncating label, so measure the text itself.
            let full = ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 10_000),
                                                             options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
            field.frame = NSRect(x: 0, y: y, width: width, height: min(full, lineHeight(font) * CGFloat(lines)))
            y = field.frame.maxY + 6
            addSubview(field)
            return field
        }

        let title = NSMutableAttributedString(string: entry.title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: Brand.ink,
        ])
        title.append(NSAttributedString(string: " · " + HistoryRow.when(entry.time) + (entry.app.map { " · " + $0 } ?? ""), attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Brand.muted,
        ]))
        let header = NSTextField(labelWithAttributedString: title)
        header.lineBreakMode = .byTruncatingTail
        header.frame = NSRect(x: 0, y: y, width: width, height: ceil(header.fittingSize.height))
        addSubview(header)
        y = header.frame.maxY + 4

        if !entry.original.isEmpty { _ = paragraph(entry.original, font: .systemFont(ofSize: 13.5), color: Brand.muted, lines: 2) }
        _ = paragraph(entry.result, font: .systemFont(ofSize: 14), color: Brand.ink, lines: 3)

        var x: CGFloat = 0
        var chips = [CopyChip(title: "Copy result", copying: entry.result)]
        if !entry.original.isEmpty { chips.append(CopyChip(title: "Copy original", copying: entry.original)) }
        for chip in chips {
            chip.frame.origin = NSPoint(x: x, y: y + 2)
            addSubview(chip)
            x = chip.frame.maxX + 6
        }
        y += CopyChip.height + 2 + 14

        let line = NSView(frame: NSRect(x: 0, y: y - 1, width: width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = Brand.hex(0xE6ECE8).cgColor
        addSubview(line)
        frame.size.height = y
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Today 11:42", "Yesterday 09:10" or "24 Oct 11:42", in local time.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "Today " + time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time.string(from: date) }
        let day = DateFormatter()
        day.dateFormat = "d MMM HH:mm"
        return day.string(from: date)
    }
}

@MainActor
final class HistoryWindow: NSObject {
    private let settings: Settings
    private let window: SettingsPanel
    private let scroll = NSScrollView()
    private let listWidth: CGFloat = 464

    init(settings: Settings) {
        self.settings = settings

        let width: CGFloat = 520, pad: CGFloat = 28, inner: CGFloat = 464

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.sizeToFit()
            return l
        }

        let content = FlippedView(frame: .zero)

        // Header: 90 tall.
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 90))
        let robot = RobotBadge(frame: NSRect(x: pad, y: 20, width: 50, height: 50))
        let title = label("Quili", size: 23, weight: .bold, color: Brand.ink)
        let subtitle = label("Recent rewrites", size: 15, color: Brand.muted)
        let titleTop = 20 + (50 - (title.frame.height + subtitle.frame.height)) / 2
        title.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop))
        subtitle.setFrameOrigin(NSPoint(x: pad + 50 + 16, y: titleTop + title.frame.height))
        let close = IconButton(path: Glyph.close, side: 34, glyph: 14, color: Brand.hex(0x44514A))
        close.frame.origin = NSPoint(x: width - 18 - 34, y: 20)
        [robot, title, subtitle, close].forEach(header.addSubview)
        content.addSubview(header)

        var y: CGFloat = 90 + 16

        scroll.frame = NSRect(x: pad, y: y, width: inner, height: 420)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        content.addSubview(scroll)
        y += 420 + 18

        let divider = NSView(frame: NSRect(x: pad, y: y, width: inner, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Brand.hex(0xE6ECE8).cgColor
        content.addSubview(divider)
        y += 1 + 18

        let clearButton = PillButton(title: "Clear history", primary: false, size: NSSize(width: 150, height: 46))
        let closeButton = PillButton(title: "Close", primary: true, size: NSSize(width: 130, height: 46), icon: false)
        let glow = PillButton.glow
        clearButton.frame.origin = NSPoint(x: pad - glow, y: y - glow)
        closeButton.frame.origin = NSPoint(x: pad + inner - 130 - glow, y: y - glow)
        content.addSubview(clearButton); content.addSubview(closeButton)
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
        window.title = "Quili – Recent rewrites"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        super.init()

        window.onCancel = { [weak self] in self?.window.close() }
        close.onClick = { [weak self] in self?.window.close() }
        closeButton.onClick = { [weak self] in self?.window.close() }
        clearButton.onClick = { [weak self] in
            HistoryStore.shared.clear()
            self?.reload()
        }
    }

    /// Rebuilds the list from the store.
    private func reload() {
        let entries = HistoryStore.shared.entries()
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: listWidth, height: 0))
        if entries.isEmpty {
            let message = "Nothing here yet. Your last 10 rewrites will show up here."
                + (settings.keepHistory ? "" : "\nHistory is turned off in Privacy & apps.")
            let note = NSTextField(wrappingLabelWithString: message)
            note.font = .systemFont(ofSize: 14)
            note.textColor = Brand.muted
            note.alignment = .center
            note.frame = NSRect(x: 0, y: 150, width: listWidth, height: 40)
            document.addSubview(note)
            document.frame.size.height = 420
        } else {
            var y: CGFloat = 0
            for entry in entries {
                let row = HistoryRow(entry: entry, width: listWidth - 12) // room for the scroller
                row.frame.origin = NSPoint(x: 0, y: y)
                document.addSubview(row)
                y = row.frame.maxY
            }
            document.frame.size.height = y
        }
        scroll.documentView = document
        document.scroll(.zero)
    }

    func show() {
        reload()
        window.center()
        window.level = .normal // raised once below; a normal window, so other apps' windows can cover it later
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
