import CoreGraphics

/// i3 tree operations scoped to one workspace.
extension Workspace {
    /// Inserts a tiled node after (or before) `anchor`, defaulting to the focused tiled node.
    func attachTiled(_ node: Node, near anchor: Node? = nil, before: Bool = false) {
        if let a = anchor ?? selected ?? mostRecentTiled, a !== node, let p = a.parent, let i = a.index {
            p.insert(node, at: before ? i : i + 1)
        } else {
            root.append(node)
        }
    }

    /// Hyprland's dwindle: the new node splits the focused tile in two along its longer side, so windows spiral
    /// in without a split key. Falls back to `attachTiled` inside tabbed/stacking or before the first layout.
    func attachDwindle(_ node: Node) {
        // Halving the focused tile over and over spirals into slivers. When the focused tile is less than half the
        // largest one, the largest is split instead: the spiral for the first few windows, never a sliver.
        func area(_ n: Node) -> CGFloat { n.rect.width * n.rect.height }
        let focused = selected ?? mostRecentTiled
        let largest = root.windows.max { area($0) < area($1) }
        let pick = focused.map { f in largest.map { area(f) * 2 < area($0) ? $0 : f } ?? f }
        guard let a = pick, a !== node, let p = a.parent, let i = a.index, p.layout.isSplit,
              a.rect.width > 0, a.rect.height > 0 else { return attachTiled(node) }
        let o: Orientation = a.rect.width >= a.rect.height ? .horizontal : .vertical
        if p.layout.orientation == o || p.children.count == 1 {
            p.layout = .split(o)
            p.insert(node, at: i + 1)
        } else {
            let c = Container(layout: .split(o))
            p.replace(a, with: c)
            c.insert(a, at: 0)
            c.insert(node, at: 1)
        }
    }

    func detachTiled(_ node: Node) {
        node.parent?.remove(node)
        normalize()
    }

    /// Drops empty containers, flattens single-child containers (except pending splits),
    /// and lets the root absorb a lone child container.
    func normalize() {
        normalize(root)
        if root.children.count == 1, let only = root.children[0] as? Container {
            root.layout = only.layout
            let kids = only.children
            root.remove(only)
            for k in kids { root.insert(k, at: root.children.count, keepWeight: true) }
        }
        if let s = selected, s === root || s.treeRoot !== root { selected = nil }
        if let f = fullscreen, f.workspace !== self { fullscreen = nil }
    }

    private func normalize(_ c: Container) {
        for case let cc as Container in c.children { normalize(cc) }
        for case let cc as Container in c.children {
            if cc.children.isEmpty {
                c.remove(cc)
            } else if cc.children.count == 1 && !cc.pendingSplit {
                c.replace(cc, with: cc.children[0])
            }
        }
    }

    // MARK: Focus

    /// Next window from `node` in `dir`, staying inside this workspace.
    func neighborWindow(of node: Node, _ dir: Direction) -> WindowNode? {
        var cur = node
        while let p = cur.parent {
            if p.layout.orientation == dir.orientation, let i = cur.index {
                let j = dir.isForward ? i + 1 : i - 1
                if p.children.indices.contains(j) { return descend(p.children[j], dir, from: node.rect) }
            }
            cur = p
        }
        return nil
    }

    /// Walks down to a window, entering from the side opposite to `dir`.
    func descend(_ start: Node, _ dir: Direction, from src: CGRect) -> WindowNode? {
        var n = start
        while let c = n as? Container {
            guard !c.children.isEmpty else { return nil }
            if !c.layout.isSplit {
                n = mostRecentChild(of: c) ?? c.children[0]
            } else if c.layout.orientation == dir.orientation {
                n = dir.isForward ? c.children[0] : c.children[c.children.count - 1]
            } else {
                // Perpendicular split: pick the child lined up with where we came from.
                let horizontal = dir.orientation == .horizontal
                let p = horizontal ? src.midY : src.midX
                func dist(_ r: CGRect) -> CGFloat {
                    let (lo, hi) = horizontal ? (r.minY, r.maxY) : (r.minX, r.maxX)
                    return p < lo ? lo - p : (p > hi ? p - hi : 0)
                }
                let recent = mostRecentChild(of: c)
                n = c.children.min { a, b in
                    let (da, db) = (dist(a.rect), dist(b.rect))
                    return da != db ? da < db : a === recent
                }!
            }
        }
        return n as? WindowNode
    }

    // MARK: Move

    /// i3 `move <dir>`. Returns false when `node` is already at the workspace edge.
    @discardableResult
    func move(_ node: Node, _ dir: Direction) -> Bool {
        guard let parent = node.parent else { return false }
        let o = dir.orientation

        // 1. Swap with, or move into, the sibling in that direction.
        if parent.layout.orientation == o, let i = node.index {
            let j = dir.isForward ? i + 1 : i - 1
            if parent.children.indices.contains(j) {
                if let c = parent.children[j] as? Container {
                    let anchor = mostRecentChild(of: c)
                    parent.remove(node)
                    if c.layout.orientation == o {
                        c.insert(node, at: dir.isForward ? 0 : c.children.count)
                    } else {
                        c.insert(node, at: (anchor?.index).map { $0 + 1 } ?? c.children.count)
                    }
                } else {
                    parent.children.swapAt(i, j)
                }
                normalize()
                return true
            }
        }

        // 2. Leave the parent: go next to the closest ancestor branch that splits along `o`.
        var cur: Node = parent
        while let p = cur.parent {
            if p.layout.orientation == o, let i = cur.index {
                node.parent?.remove(node)
                p.insert(node, at: dir.isForward ? i + 1 : i)
                normalize()
                return true
            }
            cur = p
        }

        // 3. Root splits the other way: re-orient the workspace around the node (i3's ws_force_orientation).
        if root.layout.orientation != o && root.windows.count > 1 {
            let wrapper = Container(layout: root.layout)
            for k in root.children { wrapper.insert(k, at: wrapper.children.count, keepWeight: true) }
            root.layout = .split(o)
            root.append(wrapper)
            node.parent?.remove(node)
            root.insert(node, at: dir.isForward ? 1 : 0)
            normalize()
            return true
        }
        return false
    }

    // MARK: Split / layout

    func split(_ node: Node, _ o: Orientation) {
        guard let p = node.parent else { return }
        if p.children.count == 1 {
            p.layout = .split(o)
            return
        }
        if p.layout == .split(o) { return }
        let c = Container(layout: .split(o))
        c.pendingSplit = true
        p.replace(node, with: c)
        c.insert(node, at: 0)
    }

    /// Exchanges two tiled nodes; slot sizes stay where they are.
    func swap(_ a: Node, _ b: Node) {
        guard let pa = a.parent, let pb = b.parent, let ia = a.index, let ib = b.index, a !== b else { return }
        let (wa, wb) = (a.weight, b.weight)
        if pa === pb {
            pa.children.swapAt(ia, ib)
        } else {
            pa.children[ia] = b
            pb.children[ib] = a
            a.parent = pb
            b.parent = pa
        }
        a.weight = wb
        b.weight = wa
    }

    // MARK: Resize

    /// Grows `node` along `axis` by `amount` (negative shrinks), taking space from one neighbour.
    /// `towardStart`: true = left/up neighbour, false = right/down, nil = right/down if any.
    @discardableResult
    func resize(_ node: Node, axis: Orientation, amount: ResizeAmount, towardStart: Bool?, inner: CGFloat) -> Bool {
        var cur = node
        while let p = cur.parent {
            if p.layout == .split(axis), p.children.count > 1, let i = cur.index {
                let k = p.children.count
                let j: Int?
                switch towardStart {
                case true?: j = i > 0 ? i - 1 : nil
                case false?: j = i < k - 1 ? i + 1 : nil
                case nil: j = i < k - 1 ? i + 1 : i - 1
                }
                if let j {
                    var len = (axis == .horizontal ? p.rect.width : p.rect.height) - inner * CGFloat(k - 1)
                    if len <= 0 { len = 1000 }
                    // Start from the sizes on screen, which already honour the apps' minimum sizes.
                    let mins = p.children.map { LayoutEngine.minLength($0, horizontal: axis == .horizontal, inner: inner) }
                    var sizes = LayoutEngine.distribute(len, weights: p.children.map { max($0.weight, 0.0001) }, mins: mins)
                    var d: CGFloat
                    switch amount {
                    case .px(let v): d = v
                    case .ppt(let v): d = v * len / 100
                    }
                    let least = max(len * 0.05, 40)
                    d = min(d, sizes[j] - max(least, mins[j]))
                    d = max(d, max(least, mins[i]) - sizes[i])
                    sizes[i] += d
                    sizes[j] -= d
                    for (n, s) in zip(p.children, sizes) { n.weight = s }
                    return true
                }
            }
            cur = p
        }
        return false
    }

    func balance() {
        func go(_ n: Node) {
            n.weight = 1
            (n as? Container)?.children.forEach(go)
        }
        go(root)
    }
}

public enum ResizeAmount: Equatable {
    case px(CGFloat), ppt(CGFloat)
}
