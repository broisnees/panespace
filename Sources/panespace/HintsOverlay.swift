import AppKit
import PanespaceCore

/// `hints`: a label on every window you can see, on every display; typing its letter picks that window.
/// Esc, any other key, or a click elsewhere cancels.
final class HintsOverlay: NSObject, NSWindowDelegate {
    private var labels: [NSPanel] = []
    private var catcher: KeyPanel?
    private var hints: [Hint] = []
    private var onPick: ((WindowID?) -> Void)?
    var isOpen: Bool { onPick != nil }

    /// `pick` gets the chosen window, or nil when cancelled.
    func show(_ hints: [Hint], pick: @escaping (WindowID?) -> Void) {
        if isOpen { return finish(nil) }  // the same key again closes it
        guard !hints.isEmpty else { return pick(nil) }
        self.hints = hints
        onPick = pick
        let h = NSScreen.screens.first?.frame.height ?? 0
        for hint in hints {
            let label = Self.label(hint)
            let s = label.frame.size
            let f = hint.frame
            label.setFrameOrigin(NSPoint(x: (f.midX - s.width / 2).rounded(), y: (h - f.midY - s.height / 2).rounded()))
            label.alphaValue = 0
            label.orderFrontRegardless()
            labels.append(label)
        }
        let c = catcher ?? makeCatcher()
        catcher = c
        NSApp.activate(ignoringOtherApps: true)
        c.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            for l in labels { l.animator().alphaValue = 1 }
        }
    }

    private func finish(_ id: WindowID?) {
        guard let pick = onPick else { return }
        onPick = nil
        catcher?.orderOut(nil)
        let gone = labels
        labels = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            for l in gone { l.animator().alphaValue = 0 }
        }, completionHandler: { for l in gone { l.orderOut(nil) } })
        pick(id)
    }

    /// An invisible key window that takes the typed letter.
    private func makeCatcher() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.onKey = { [weak self] e in
            guard let self else { return true }
            let ch = e.charactersIgnoringModifiers?.lowercased().first
            finish(hints.first { $0.key == ch }?.id)
            return true
        }
        return p
    }

    func windowDidResignKey(_ notification: Notification) { finish(nil) }

    /// A blurred pill: the app's icon and the letter to type, on an accent-colored key cap.
    private static func label(_ hint: Hint) -> NSPanel {
        let height: CGFloat = 56, pad: CGFloat = 10, icon: CGFloat = 32, cap: CGFloat = 36
        let width = pad + icon + 10 + cap + pad
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .modalPanel
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        p.contentView = blur

        let iv = NSImageView(frame: NSRect(x: pad, y: (height - icon) / 2, width: icon, height: icon))
        iv.image = NSRunningApplication(processIdentifier: hint.pid)?.icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        blur.addSubview(iv)

        let keyCap = NSView(frame: NSRect(x: pad + icon + 10, y: (height - cap) / 2, width: cap, height: cap))
        keyCap.wantsLayer = true
        keyCap.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        keyCap.layer?.cornerRadius = 9
        keyCap.layer?.cornerCurve = .continuous
        blur.addSubview(keyCap)

        let letter = NSTextField(labelWithString: String(hint.key).uppercased())
        let base = NSFont.systemFont(ofSize: 21, weight: .bold)
        letter.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 21) } ?? base
        letter.textColor = .white
        letter.alignment = .center
        letter.sizeToFit()
        letter.frame = NSRect(x: 0, y: ((cap - letter.frame.height) / 2).rounded(), width: cap, height: letter.frame.height)
        keyCap.addSubview(letter)
        return p
    }
}
