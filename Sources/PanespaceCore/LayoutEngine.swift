import CoreGraphics

public struct Gaps: Equatable {
    public var inner: CGFloat = 0
    public var top: CGFloat = 0
    public var bottom: CGFloat = 0
    public var left: CGFloat = 0
    public var right: CGFloat = 0
    public init() {}
}

enum LayoutEngine {
    /// Splits `length` by weight, but gives no child less than its minimum; the others make up the difference in
    /// proportion. When the minimums can't all fit, plain proportions: overlap is unavoidable either way.
    static func distribute(_ length: CGFloat, weights: [CGFloat], mins: [CGFloat]) -> [CGFloat] {
        let total = weights.reduce(0, +)
        guard mins.reduce(0, +) <= length, mins.contains(where: { $0 > 0 }) else { return weights.map { length * $0 / total } }
        var sizes = [CGFloat](repeating: 0, count: weights.count)
        var open = Array(weights.indices)
        var left = length
        while true {
            let share = open.reduce(0) { $0 + weights[$1] }
            let short = open.filter { left * weights[$0] / share < mins[$0] }
            if short.isEmpty {
                for i in open { sizes[i] = left * weights[i] / share }
                return sizes
            }
            for i in short {
                sizes[i] = mins[i]
                left -= mins[i]
            }
            open.removeAll { short.contains($0) }
        }
    }

    /// The least room `n` needs along one axis, from the minimum sizes its windows were seen to refuse to go below.
    static func minLength(_ n: Node, horizontal: Bool, inner: CGFloat) -> CGFloat {
        if let w = n as? WindowNode { return horizontal ? w.minSize.width : w.minSize.height }
        guard let c = n as? Container, !c.children.isEmpty else { return 0 }
        let mins = c.children.map { minLength($0, horizontal: horizontal, inner: inner) }
        if c.layout.isSplit, (c.layout.orientation == .horizontal) == horizontal {
            return mins.reduce(0, +) + inner * CGFloat(c.children.count - 1)
        }
        return mins.max() ?? 0  // across the split, or stacked/tabbed: every child spans the whole container
    }

    /// Frames for every tiled window of `ws` on `monitor` (plus a fullscreen window, if any).
    /// Also records each node's rect for geometry-based commands.
    static func layout(_ ws: Workspace, on monitor: Monitor, config: Config) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        let tiledCount = ws.root.windows.count
        let g = config.smartGaps && tiledCount <= 1 ? Gaps() : config.gaps
        let v = monitor.visibleFrame
        let area = CGRect(x: v.minX + g.left, y: v.minY + g.top,
                          width: max(1, v.width - g.left - g.right), height: max(1, v.height - g.top - g.bottom))
        place(ws.root, area, ws: ws, inner: g.inner, padding: config.accordionPadding, into: &out)
        if let fs = ws.fullscreen { out[fs.id] = v }
        return out
    }

    /// A pseudotiled window's frame: its preferred size (never past the tile, never under its minimum), centered.
    /// The size is settled when pseudo is turned on (`Model.pseudoSize`), so it never jumps between layouts.
    static func pseudoFrame(_ w: WindowNode, in r: CGRect) -> CGRect {
        var s = w.preferredSize ?? CGSize(width: r.width * 2 / 3, height: r.height * 2 / 3)
        // Never below what the app accepts, even if that spills past the tile: squeezing it further makes the
        // app push back every time, and the window flickers between the two sizes.
        s.width = max(min(s.width, r.width), w.minSize.width)
        s.height = max(min(s.height, r.height), w.minSize.height)
        return CGRect(x: (r.midX - s.width / 2).rounded(), y: (r.midY - s.height / 2).rounded(),
                      width: s.width.rounded(), height: s.height.rounded())
    }

    private static func place(_ n: Node, _ r: CGRect, ws: Workspace, inner: CGFloat, padding: CGFloat,
                              into out: inout [WindowID: CGRect]) {
        n.rect = r
        if let w = n as? WindowNode {
            out[w.id] = w.isPseudo ? pseudoFrame(w, in: r) : r
            return
        }
        guard let c = n as? Container, !c.children.isEmpty else { return }
        let k = c.children.count
        let horizontal = c.layout.orientation == .horizontal

        if c.layout.isSplit {
            let length = (horizontal ? r.width : r.height) - inner * CGFloat(k - 1)
            let sizes = distribute(length, weights: c.children.map { max($0.weight, 0.0001) },
                                   mins: c.children.map { minLength($0, horizontal: horizontal, inner: inner) })
            var pos = horizontal ? r.minX : r.minY
            for (i, child) in c.children.enumerated() {
                let end = horizontal ? r.maxX : r.maxY
                let size = i == k - 1 ? end - pos : sizes[i].rounded()
                let cr = horizontal
                    ? CGRect(x: pos, y: r.minY, width: size, height: r.height)
                    : CGRect(x: r.minX, y: pos, width: r.width, height: size)
                place(child, cr, ws: ws, inner: inner, padding: padding, into: &out)
                pos += size + inner
            }
            return
        }

        // tabbed / stacking: accordion. Every child covers the container, offset so neighbours' edges peek out.
        let focused = ws.mostRecentChild(of: c).flatMap { f in c.children.firstIndex { $0 === f } } ?? 0
        for (i, child) in c.children.enumerated() {
            let (lead, trail): (CGFloat, CGFloat)
            if k == 1 { (lead, trail) = (0, 0) }
            else if i == 0 { (lead, trail) = (0, padding) }
            else if i == k - 1 { (lead, trail) = (padding, 0) }
            else if i == focused - 1 { (lead, trail) = (0, 2 * padding) }
            else if i == focused + 1 { (lead, trail) = (2 * padding, 0) }
            else { (lead, trail) = (padding, padding) }
            let cr = horizontal
                ? CGRect(x: r.minX + lead, y: r.minY, width: r.width - lead - trail, height: r.height)
                : CGRect(x: r.minX, y: r.minY + lead, width: r.width, height: r.height - lead - trail)
            place(child, cr, ws: ws, inner: inner, padding: padding, into: &out)
        }
    }
}
