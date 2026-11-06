import CoreGraphics

/// Where a tiled window dragged with the mouse lands, i3 style: on another window's middle it swaps with it,
/// near one of its edges it goes beside it on that side, and on an empty display it takes the whole display.
public struct DropTarget: Equatable {
    public enum Zone: Equatable {
        case swap(WindowID)
        case beside(WindowID, Direction)
        case workspace
    }
    public let workspace: String
    public let zone: Zone
    /// The area to highlight while dragging, in screen coordinates (top-left origin).
    public let preview: CGRect
}

extension Model {
    /// Where the tiled window `id` would land if dropped at `p`; nil = back to its own tile. `id` nil: a window
    /// that isn't tiled yet (a tab being torn off its window), which has no tile to go back to or swap with.
    public func dropTarget(for id: WindowID?, at p: CGPoint) -> DropTarget? {
        let w = id.flatMap { windows[$0] }
        if let w, w.isFloating || w.workspace == nil { return nil }
        if id != nil, w == nil { return nil }
        guard let m = monitor(containing: p), let ws = visible[m.id] else { return nil }
        let src = w?.workspace
        // What the user sees there: a full-screen window covers the display; in a tab group, the shown tab.
        var shown: [(WindowNode, CGRect)]
        if let fs = ws.fullscreen {
            shown = fs.isFloating ? [] : [(fs, m.visibleFrame)]
        } else {
            shown = ws.mru.filter { !$0.isFloating }.map { ($0, $0.rect) }
        }
        guard let (t, r) = shown.first(where: { $0.1.contains(p) }) else {
            guard ws !== src, ws.root.children.isEmpty else { return nil }
            return DropTarget(workspace: ws.name, zone: .workspace, preview: m.visibleFrame)
        }
        guard t !== w else { return nil }
        let u = (p.x - r.minX) / max(r.width, 1), v = (p.y - r.minY) / max(r.height, 1)
        if w != nil, abs(u - 0.5) < 0.25, abs(v - 0.5) < 0.25 {
            return DropTarget(workspace: ws.name, zone: .swap(t.id), preview: r)
        }
        let dir = [(u, Direction.left), (1 - u, .right), (v, .up), (1 - v, .down)].min { $0.0 < $1.0 }!.1
        // Beside a tab group, the window goes next to the whole group.
        let group = ws.fullscreen == nil ? t.parent.flatMap { $0.layout.isSplit ? nil : $0.rect } : nil
        return DropTarget(workspace: ws.name, zone: .beside(t.id, dir), preview: Self.half(group ?? r, dir))
    }

    static func half(_ r: CGRect, _ d: Direction) -> CGRect {
        switch d {
        case .left: return CGRect(x: r.minX, y: r.minY, width: (r.width / 2).rounded(), height: r.height)
        case .right: return CGRect(x: (r.midX).rounded(), y: r.minY, width: r.maxX - r.midX.rounded(), height: r.height)
        case .up: return CGRect(x: r.minX, y: r.minY, width: r.width, height: (r.height / 2).rounded())
        case .down: return CGRect(x: r.minX, y: r.midY.rounded(), width: r.width, height: r.maxY - r.midY.rounded())
        }
    }

    /// The user dragged the tiled window `id` and let go at `p` (see `dropTarget`). Focus follows it.
    public func userDropped(_ id: WindowID, at p: CGPoint) {
        if let d = dropTarget(for: id, at: p) { drop(id, d) }
    }

    /// A window torn off another one (a browser or terminal tab dragged out) and let go at `p`: it goes where the
    /// drop preview showed, else to the workspace on the display under `p`, not to the focused one.
    @discardableResult
    public func addTornOffWindow(_ id: WindowID, info: WindowInfo, at p: CGPoint) -> WindowNode {
        let d = dropTarget(for: nil, at: p)
        let w = addWindow(id, info: info, floating: false, frame: CGRect(origin: p, size: .zero), useMonitorOfFrame: true,
                          workspaceName: d?.workspace)
        if let d { drop(id, d) } else { setFocus(w) }
        return w
    }

    /// Puts tiled window `id` where `d` says. Focus follows it.
    public func drop(_ id: WindowID, _ d: DropTarget) {
        guard let w = windows[id], !w.isFloating, let src = w.workspace, let dst = workspace(named: d.workspace) else { return }
        switch d.zone {
        case .workspace:
            moveNode(w, to: dst)
        case .swap(let tid):
            guard let t = windows[tid], t !== w, t.workspace === dst else { return }
            src.swap(w, t)
            if src !== dst {
                // Each takes the other's place in its new workspace's focus history too.
                if let i = src.mru.firstIndex(where: { $0 === w }) { src.mru[i] = t }
                if let i = dst.mru.firstIndex(where: { $0 === t }) { dst.mru[i] = w }
                if src.fullscreen === w { src.fullscreen = nil }
                if dst.fullscreen === t { dst.fullscreen = nil }
                src.normalize()
                dst.normalize()
            }
        case .beside(let tid, let dir):
            guard let t = windows[tid], t !== w, t.workspace === dst else { return }
            src.detachTiled(w)
            dst.insert(w, beside: t, dir)
            if src !== dst {
                src.forget(w)
                dst.touch(w)
            }
        }
        setFocus(w)
        gc()
    }
}

extension Workspace {
    /// Puts `node` beside `target` on side `dir`: a sibling when they split that way, else `target`'s slot is
    /// split in two. Next to a tab or stack, it goes beside the whole group.
    func insert(_ node: Node, beside target: Node, _ dir: Direction) {
        var a = target
        if let p = a.parent, !p.layout.isSplit { a = p }
        let o = dir.orientation
        if let p = a.parent, let i = a.index {
            if p.layout == .split(o) {
                p.insert(node, at: dir.isForward ? i + 1 : i)
            } else if p.children.count == 1 {
                p.layout = .split(o)
                p.insert(node, at: dir.isForward ? 1 : 0)
            } else {
                let c = Container(layout: .split(o))
                p.replace(a, with: c)
                c.insert(a, at: 0)
                c.insert(node, at: dir.isForward ? 1 : 0)
            }
        } else {
            // `a` is a tabbed or stacked root: the whole group becomes one side of a new split.
            let group = Container(layout: root.layout)
            for k in root.children { group.insert(k, at: group.children.count, keepWeight: true) }
            root.layout = .split(o)
            root.append(group)
            root.insert(node, at: dir.isForward ? 1 : 0)
        }
        normalize()
    }
}
