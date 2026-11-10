import AppKit
import PanespaceCore

/// While a mode such as the leader is on, a panel at the bottom of the focused display lists its keys
/// (Neovim's which-key, Omarchy's cheat sheet). It never takes focus or clicks; it fades out when the mode ends.
final class WhichKeyPanel {
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var shownMode: String?

    /// `mode` nil hides it. A short delay first, so a quick leader + key never flashes the panel.
    func update(mode: String?, groups: [WhichKey.Group], on screen: NSScreen?) {
        pending?.cancel()
        guard let mode, !groups.isEmpty, let screen else { return hide() }
        if shownMode == mode, panel?.isVisible == true { return }
        let work = DispatchWorkItem { [weak self] in self?.show(mode, groups, screen) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0 : 0.18), execute: work)
    }

    private func hide() {
        shownMode = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: { if self.shownMode == nil { p.orderOut(nil) } })
    }

    private func show(_ mode: String, _ groups: [WhichKey.Group], _ screen: NSScreen) {
        shownMode = mode
        let view = WhichKeyView(title: mode.prefix(1).uppercased() + mode.dropFirst(), groups: groups)
        let size = view.fittingSize
        let p = panel ?? makePanel()
        panel = p
        let blur = p.contentView!
        blur.subviews.forEach { $0.removeFromSuperview() }
        view.frame = NSRect(origin: .zero, size: size)
        blur.addSubview(view)
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: (v.midX - size.width / 2).rounded(), y: v.minY + 48, width: size.width, height: size.height),
                   display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // flat: a hairline border, no drop shadow
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        // Solid, not see-through: over a light window a translucent panel washes out.
        let blur = NSView()
        blur.wantsLayer = true
        blur.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.97).cgColor
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        p.contentView = blur
        return p
    }
}

/// The panel's content: the mode's name, then one column per group (Move, Window, …), keycap beside label.
final class WhichKeyView: NSView {
    private let title: String
    private let groups: [WhichKey.Group]
    private let capFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let headFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private let pad: CGFloat = 18, rowH: CGFloat = 25, header: CGFloat = 44, colGap: CGFloat = 30, headH: CGFloat = 22

    init(title: String, groups: [WhichKey.Group]) {
        self.title = title
        self.groups = groups
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
    private func capW(_ g: WhichKey.Group) -> CGFloat { max(22, (g.entries.map { width($0.key, capFont) }.max() ?? 0) + 12) }
    private func colW(_ g: WhichKey.Group) -> CGFloat {
        max(capW(g) + 10 + (g.entries.map { width($0.label, labelFont) }.max() ?? 0), width(g.title.uppercased(), headFont))
    }
    private var rows: Int { groups.map(\.entries.count).max() ?? 0 }

    override var fittingSize: NSSize {
        NSSize(width: pad * 2 + groups.map(colW).reduce(0, +) + CGFloat(max(0, groups.count - 1)) * colGap,
               height: header + headH + CGFloat(rows) * rowH + pad - 6)
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.white.withAlphaComponent(0.42)
        (title as NSString).draw(at: NSPoint(x: pad, y: 15), withAttributes: [.font: titleFont, .foregroundColor: NSColor.white])
        let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let hint = "esc to close"
        (hint as NSString).draw(at: NSPoint(x: bounds.width - pad - width(hint, hintFont), y: 16),
                                withAttributes: [.font: hintFont, .foregroundColor: dim])
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: header - 4, width: bounds.width, height: 1).fill()

        var x = pad
        for g in groups {
            let head = NSAttributedString(string: g.title.uppercased(),
                                          attributes: [.font: headFont, .foregroundColor: dim, .kern: 0.8])
            head.draw(at: NSPoint(x: x, y: header + 4))
            let cw = capW(g)
            for (row, e) in g.entries.enumerated() {
                let y = header + headH + CGFloat(row) * rowH
                let cap = NSRect(x: x, y: y + 2, width: cw, height: rowH - 6)
                let shape = NSBezierPath(roundedRect: cap, xRadius: 4.5, yRadius: 4.5)
                NSColor.white.withAlphaComponent(0.1).setFill()
                shape.fill()
                let ks = e.key as NSString
                let kh = ks.size(withAttributes: [.font: capFont]).height
                ks.draw(at: NSPoint(x: cap.midX - width(e.key, capFont) / 2, y: cap.midY - kh / 2),
                        withAttributes: [.font: capFont, .foregroundColor: NSColor.white])
                let ls = e.label as NSString
                let lh = ls.size(withAttributes: [.font: labelFont]).height
                ls.draw(at: NSPoint(x: cap.maxX + 10, y: cap.midY - lh / 2),
                        withAttributes: [.font: labelFont, .foregroundColor: NSColor.white.withAlphaComponent(0.88)])
            }
            x += colW(g) + colGap
        }
    }
}
