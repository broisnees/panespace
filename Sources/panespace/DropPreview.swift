import AppKit
import QuartzCore

/// The translucent area shown while a tiled window is dragged: where it lands if let go now. Click-through,
/// above other windows, glides from one target to the next and fades in and out.
final class DropPreview {
    private let window: NSWindow
    private var target: CGRect?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 2
        window.contentView = view
    }

    /// `r` in Accessibility coordinates (top-left origin); nil hides it.
    func show(_ r: CGRect?) {
        guard r != target else { return }
        guard let r else { return hide() }
        let wasShown = target != nil
        target = r
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height).insetBy(dx: 8, dy: 8)
        if let layer = window.contentView?.layer {  // follows the accent color the user picked
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        }
        if wasShown {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.14
                c.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(f, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            window.setFrame(f, display: true)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.1
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard target != nil else { return }
        target = nil
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.1
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.target == nil else { return }  // shown again meanwhile
            self.window.orderOut(nil)
        })
    }
}
