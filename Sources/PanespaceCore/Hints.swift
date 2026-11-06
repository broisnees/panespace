import CoreGraphics

/// One window label of `hints`: type `key` to pick the window.
public struct Hint: Equatable {
    public let id: WindowID
    public let key: Character
    /// The window's frame on screen (top-left origin).
    public let frame: CGRect
    public let pid: pid_t
}

extension Model {
    /// Home row first, then the rows above and below: the easiest keys go to the most windows.
    static let hintKeys = Array("asdfghjklqwertyuiopzxcvbnm")

    /// Every window the user can see right now, on every display: a full-screen window alone on its display, a tab
    /// group's shown tab only, floating windows too. Labelled display by display (left to right), then in reading
    /// order. At most 26.
    public func hints() -> [Hint] {
        _ = placements()  // fresh rects
        var seen: [(WindowNode, CGRect, Int)] = []
        for (i, m) in monitors.enumerated() {
            guard let ws = visible[m.id] else { continue }
            if let fs = ws.fullscreen {
                seen.append((fs, m.visibleFrame, i))
                continue
            }
            for w in ws.root.windows where isShownTab(w, in: ws) { seen.append((w, w.rect, i)) }
            for w in ws.floating { if let f = w.floatingFrame { seen.append((w, f, i)) } }
        }
        seen.sort { a, b in
            if a.2 != b.2 { return a.2 < b.2 }
            if abs(a.1.minY - b.1.minY) > 8 { return a.1.minY < b.1.minY }
            return a.1.minX < b.1.minX
        }
        return zip(seen, Self.hintKeys).map { s, k in Hint(id: s.0.id, key: k, frame: s.1, pid: s.0.info.pid) }
    }

    /// Not hidden behind another tab of a tabbed or stacked container.
    func isShownTab(_ w: WindowNode, in ws: Workspace) -> Bool {
        var n: Node = w
        while let p = n.parent {
            if !p.layout.isSplit, ws.mostRecentChild(of: p) !== n { return false }
            n = p
        }
        return true
    }

    /// `hints` picked `id`: focus it, or with `swap`, trade places with the focused window (tiled windows, any
    /// display). Focus ends on the picked window's spot either way.
    public func pickHint(_ id: WindowID, swap: Bool) {
        guard let t = windows[id] else { return }
        if swap, let f = focusedWindow, f !== t, !f.isFloating, !t.isFloating, let dst = t.workspace {
            drop(f.id, DropTarget(workspace: dst.name, zone: .swap(t.id), preview: t.rect))
        } else {
            osFocused(id)
        }
    }
}
