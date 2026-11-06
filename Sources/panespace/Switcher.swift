import AppKit
import PanespaceCore

/// The window switcher (leader + Space or K): a search box over every window, Spotlight/Raycast style.
/// Type to filter (fuzzy, app names count most), ↑/↓ or ⌃N/⌃P to pick, Return to jump there, Esc to leave.
final class SwitcherPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var panel: KeyPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No windows match")
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint?
    private var all: [SwitcherEntry] = []
    private var shown: [SwitcherEntry] = []
    private var icons: [pid_t: NSImage] = [:]
    private var onPick: ((WindowID?) -> Void)?
    private var screenFrame = NSRect.zero
    private var anchorTop: CGFloat = 0
    var isOpen: Bool { panel?.isVisible ?? false }

    private static let width: CGFloat = 640
    private static let rowHeight: CGFloat = 46
    private static let maxRows = 9
    private static let headerHeight: CGFloat = 54
    private static let listPadding: CGFloat = 6

    /// Opens on `screenFrame` (Cocoa coordinates). `pick` gets the chosen window, or nil when dismissed.
    func show(_ entries: [SwitcherEntry], on screenFrame: NSRect, pick: @escaping (WindowID?) -> Void) {
        if isOpen { return close(nil) }  // the same key again closes it
        all = entries
        shown = entries
        onPick = pick
        icons = [:]
        self.screenFrame = screenFrame
        anchorTop = screenFrame.minY + screenFrame.height * 0.68
        let p = panel ?? build()
        panel = p
        field.stringValue = ""
        reload()
        NSApp.activate(ignoringOtherApps: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            p.animator().alphaValue = 1
        }
    }

    private func build() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.level = .modalPanel
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.onKey = { [weak self] e in self?.key(e) ?? false }

        let bg = PanelBackground()
        p.contentView = bg
        let tint = Tint()
        tint.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(tint)

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        field.placeholderString = "Search windows…"
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = self
        field.cell?.isScrollable = true

        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let col = NSTableColumn(identifier: .init("w"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        empty.textColor = .tertiaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.alignment = .center

        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: bg.topAnchor),
            tint.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])
        for v in [glass, field, line, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        let h = Self.headerHeight
        let pad = Self.listPadding
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: h / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            line.topAnchor.constraint(equalTo: bg.topAnchor, constant: h),
            line.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: pad),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -pad),
            scrollHeight!,
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        return p
    }

    private func reload() {
        shown = Fuzzy.filter(field.stringValue, all)
        let rows = max(1, min(Self.maxRows, shown.count))
        scrollHeight?.constant = CGFloat(rows) * Self.rowHeight
        table.reloadData()
        empty.stringValue = field.stringValue.isEmpty ? "No windows" : "No windows match"
        empty.isHidden = !shown.isEmpty
        if !shown.isEmpty { select(0) }
        layoutPanel()
    }

    private func layoutPanel() {
        guard let p = panel else { return }
        let rows = max(1, min(Self.maxRows, shown.count))
        let height = Self.headerHeight + 1 + Self.listPadding * 2 + CGFloat(rows) * Self.rowHeight
        p.setFrame(NSRect(x: screenFrame.midX - Self.width / 2, y: anchorTop - height,
                          width: Self.width, height: height), display: true)
    }

    private func select(_ row: Int) {
        guard !shown.isEmpty else { return }
        let r = (row + shown.count) % shown.count
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    /// Navigation keys, wherever the focus is in the panel. True = handled.
    private func key(_ e: NSEvent) -> Bool {
        let ctrl = e.modifierFlags.contains(.control)
        switch (e.keyCode, ctrl, e.charactersIgnoringModifiers) {
        case (125, _, _), (_, true, "n"), (_, true, "j"): select(table.selectedRow + 1)
        case (126, _, _), (_, true, "p"), (_, true, "k"): select(table.selectedRow - 1)
        case (36, _, _), (76, _, _): close(shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].id : nil)
        case (53, _, _): close(nil)
        default: return false
        }
        return true
    }

    @objc private func clickedRow() {
        if shown.indices.contains(table.clickedRow) { close(shown[table.clickedRow].id) }
    }

    private func close(_ id: WindowID?) {
        guard let p = panel, p.isVisible else { return }
        let pick = onPick
        onPick = nil
        p.orderOut(nil)
        all = []
        shown = []
        icons = [:]
        pick?(id)
    }

    // Clicking elsewhere dismisses it.
    func windowDidResignKey(_ notification: Notification) { close(nil) }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SwitcherRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let cell = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? SwitcherRow) ?? SwitcherRow()
        cell.identifier = .init("row")
        let icon = icons[e.pid] ?? NSRunningApplication(processIdentifier: e.pid)?.icon
        icons[e.pid] = icon
        let redundantApp = e.title.compare(e.app, options: .caseInsensitive) == .orderedSame
        cell.set(icon: icon, title: e.title.isEmpty ? e.app : e.title,
                 detail: e.title.isEmpty || redundantApp ? "" : e.app,
                 badge: e.workspace ?? "scratch", floating: e.isFloating, query: field.stringValue)
        return cell
    }
}

/// The rounded, translucent sheet behind the switcher, with a hairline that follows the system appearance.
private final class PanelBackground: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }
}

/// A borderless panel that can take the keyboard and hands navigation keys to the switcher first.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

/// Inset, rounded highlight instead of the raw full-width table selection.
private final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}

/// A neutral tint over the blur: the wallpaper's color no longer decides whether text is readable.
private final class Tint: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class BadgeBackground: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5.5, yRadius: 5.5).fill()
    }
}

private final class SwitcherRow: NSTableCellView {
    private let icon = NSImageView()
    private let text = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let badgeBack = BadgeBackground()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        badge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        badge.textColor = .controlAccentColor
        badge.alignment = .center

        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(title)
        text.addArrangedSubview(detail)
        text.distribution = .fill

        for v in [icon, text, badgeBack, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [title, detail] {
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: badgeBack.leadingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badgeBack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBack.heightAnchor.constraint(equalToConstant: 19),
            badgeBack.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            badge.leadingAnchor.constraint(equalTo: badgeBack.leadingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: badgeBack.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: badgeBack.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(icon img: NSImage?, title t: String, detail d: String, badge b: String, floating: Bool, query: String) {
        icon.image = img
        title.attributedStringValue = Self.highlighted(t, query: query)
        let subtitle = d.isEmpty ? (floating ? "floating" : "") : (floating ? d + " · floating" : d)
        detail.stringValue = subtitle
        detail.isHidden = subtitle.isEmpty
        badge.stringValue = b
    }

    /// The query's characters in order, the ones that matched tinted with the accent color.
    private static func highlighted(_ text: String, query: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        var from = text.startIndex
        for ch in query where !ch.isWhitespace {
            guard let r = text.range(of: String(ch), options: .caseInsensitive, range: from..<text.endIndex) else { break }
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13.5, weight: .semibold), range: NSRange(r, in: text))
            from = r.upperBound
        }
        return s
    }
}
