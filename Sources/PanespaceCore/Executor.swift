import CoreGraphics

extension Model {
    /// Runs an i3 command string. `windowID` sets the context window (for_window rules);
    /// otherwise commands apply to criteria matches or the focused node.
    @discardableResult
    public func run(_ text: String, on windowID: WindowID? = nil) -> CommandResult {
        var result = CommandResult()
        let parsed: [ParsedCommand]
        do { parsed = try CommandParser.parse(text) } catch {
            result.errors.append("\(error)")
            return result
        }
        _ = placements()  // fresh rects for geometry-based commands
        for pc in parsed {
            var targets: [WindowNode?] = [nil]
            if let c = pc.criteria {
                let crit = (try? Criteria.parse(c)) ?? Criteria()
                targets = windows.values.filter { crit.matches($0) }.sorted { $0.id < $1.id }
            } else if let id = windowID {
                guard let w = windows[id] else { continue }
                targets = [w]
            }
            for t in targets {
                do { result.effects += try execute(pc.command, target: t) } catch {
                    result.errors.append("\(error)")
                }
            }
        }
        return result
    }

    func execute(_ cmd: Command, target: WindowNode?) throws -> [Effect] {
        let ws: Workspace = target?.workspace ?? focusedWorkspace
        let node: Node? = target ?? ws.focusedNode
        let win: WindowNode? = target ?? ws.focusedWindow

        switch cmd {
        case .exec(let s): return [.exec(s)]
        case .nop: break
        case .reload: return [.reload]
        case .exit: return [.exit]
        case .immersive(let t): return [.immersive(t)]
        case .switcher: return [.switcher]
        case .kill:
            return node.map { windows(in: $0).map { .close($0.id) } } ?? []
        case .mode(let m):
            guard m == "default" || config.modes[m] != nil else { throw ParseError("no mode named '\(m)'") }
            mode = m

        case .focus(let dir): focusDirection(dir, from: node, in: ws)
        case .focusTarget:
            if let t = target { osFocused(t.id) }
        case .focusParent:
            if let p = node?.parent, p !== ws.root { ws.selected = p }
        case .focusChild:
            if let s = ws.selected { ws.selected = ws.mostRecentChild(of: s) as? Container }
        case .focusModeToggle:
            let wantFloating = !(win?.isFloating ?? true)
            if let w = ws.mru.first(where: { $0.isFloating == wantFloating }) { setFocus(w) }
        case .focusFloating:
            if let w = ws.mru.first(where: { $0.isFloating }) { setFocus(w) }
        case .focusTiling:
            if let w = ws.mostRecentTiled { setFocus(w) }
        case .focusOutput(let t):
            if let m = resolveOutput(t), let v = visible[m.id] { switchTo(v) }

        case .move(let dir, let px):
            guard let node else { break }
            if let w = node as? WindowNode, w.isFloating {
                let d = CGFloat(px ?? 10)
                var f = w.floatingFrame ?? w.rect
                switch dir {
                case .left: f.origin.x -= d
                case .right: f.origin.x += d
                case .up: f.origin.y -= d
                case .down: f.origin.y += d
                }
                setFloatingFrame(w, f)
            } else if !ws.move(node, dir), let m = monitor(ws.monitorID).flatMap({ monitor(in: dir, from: $0) }),
                      let dst = visible[m.id] {
                let anchor = dst.descend(dst.root, dir, from: node.rect)
                moveNode(node, to: dst, anchor: anchor, before: dir.isForward)
                switchTo(dst)
                if let c = node as? Container { dst.selected = c } else if let w = node as? WindowNode { setFocus(w) }
            }

        case .moveToWorkspace(let t):
            guard let node else { break }
            var dst = resolveWorkspace(t, create: true)
            if dst === ws, config.autoBackAndForth, case .name = t { dst = resolveWorkspace(.backAndForth, create: true) }
            if dst === ws, config.autoBackAndForth, case .number = t { dst = resolveWorkspace(.backAndForth, create: true) }
            if let dst { moveNode(node, to: dst) }

        case .moveToOutput(let t):
            guard let node, let m = resolveOutput(t), let dst = visible[m.id], dst !== ws else { break }
            moveNode(node, to: dst)
            switchTo(dst)
            if let w = node as? WindowNode { setFocus(w) }

        case .moveWorkspaceToOutput(let t):
            moveWorkspace(focusedWorkspace, to: t)

        case .moveToScratchpad:
            if let w = win { hideToScratchpad(w) }

        case .scratchpadShow:
            if let t = target {
                if t.workspace === focusedWorkspace && focusedWorkspace.focusedWindow === t && t.isScratchpad {
                    hideToScratchpad(t)
                } else {
                    showScratchpad(t)
                }
            } else if let f = focusedWorkspace.focusedWindow, f.isScratchpad, f.isFloating {
                hideToScratchpad(f)
            } else if let first = scratchpad.first {
                showScratchpad(first)
            }

        case .movePositionCenter:
            guard let w = win, w.isFloating, let m = monitor(ws.monitorID) else { break }
            let f = w.floatingFrame ?? w.rect
            setFloatingFrame(w, centered(size: f.size, in: m.visibleFrame))

        case .workspace(let t, let noAuto):
            var dst = resolveWorkspace(t, create: true)
            if dst === focusedWorkspace, config.autoBackAndForth, !noAuto {
                switch t {
                case .name, .number: dst = resolveWorkspace(.backAndForth, create: true)
                default: break
                }
            }
            if let dst { switchTo(dst) }

        case .workspaceOnOutput(let t, let o):
            // One monitor (or no such output): an ordinary switch.
            guard let m = resolveOutput(o) ?? monitor(focusedWorkspace.monitorID),
                  let dst = resolveWorkspace(t, create: true) else { break }
            if dst.monitorID != m.id {
                place(dst, on: m)
                if dst !== focusedWorkspace { previousWorkspaceName = focusedWorkspace.name }
                focusedWorkspace = dst
                gc()
            } else {
                switchTo(dst)
            }

        case .split(let o):
            guard let node, node.parent != nil else { break }
            ws.split(node, o ?? node.parent!.layout.orientation.opposite)

        case .layout(let arg):
            guard let node else { break }
            let c: Container = (node === ws.selected ? node as? Container : nil) ?? node.parent ?? ws.root
            switch arg {
            case .set(let l): c.layout = l
            case .defaultSplit: c.layout = c.lastSplit
            case .toggleSplit:
                c.layout = c.layout == .splitH ? .splitV : (c.layout == .splitV ? .splitH : c.lastSplit)
            case .toggleAll:
                let order: [Layout] = [.splitH, .splitV, .stacking, .tabbed]
                c.layout = order[((order.firstIndex(of: c.layout) ?? 0) + 1) % order.count]
            case .cycle(let items):
                let cur = items.firstIndex { $0 == c.layout } ?? items.firstIndex { $0 == nil && c.layout.isSplit }
                c.layout = items[((cur ?? -1) + 1) % items.count] ?? c.lastSplit
            }

        case .fullscreen(let tg):
            guard let w = win else { break }
            let on = tg == .toggle ? ws.fullscreen !== w : tg == .enable
            ws.fullscreen = on ? w : (ws.fullscreen === w ? nil : ws.fullscreen)

        case .floating(let tg):
            guard let w = win else { break }
            setFloating(w, tg == .toggle ? !w.isFloating : tg == .enable)

        case .resize(let r):
            guard let node else { break }
            let sign: CGFloat = r.grow ? 1 : -1
            if let w = node as? WindowNode, w.isFloating {
                let v = (monitor(ws.monitorID) ?? focusedMonitor).visibleFrame
                var f = w.floatingFrame ?? w.rect
                let horizontal: Bool
                switch r.dimension {
                case .width: horizontal = true
                case .height: horizontal = false
                case .edge(let d): horizontal = d.orientation == .horizontal
                }
                let d = sign * CGFloat(r.px ?? r.ppt.map { Int((horizontal ? v.width : v.height) * CGFloat($0) / 100) } ?? 10)
                switch r.dimension {
                case .width, .edge(.right): f.size.width += d
                case .height, .edge(.down): f.size.height += d
                case .edge(.left): f.origin.x -= d; f.size.width += d
                case .edge(.up): f.origin.y -= d; f.size.height += d
                }
                f.size.width = max(f.width, 50)
                f.size.height = max(f.height, 50)
                setFloatingFrame(w, f)
            } else {
                let amount: ResizeAmount = r.ppt.map { .ppt(sign * CGFloat($0)) }
                    ?? r.px.map { .px(sign * CGFloat($0)) } ?? .ppt(sign * 10)
                switch r.dimension {
                case .width: ws.resize(node, axis: .horizontal, amount: amount, towardStart: nil, inner: config.gaps.inner)
                case .height: ws.resize(node, axis: .vertical, amount: amount, towardStart: nil, inner: config.gaps.inner)
                case .edge(let d):
                    ws.resize(node, axis: d.orientation, amount: amount, towardStart: !d.isForward, inner: config.gaps.inner)
                }
            }

        case .balance:
            ws.balance()
        }
        return []
    }

    func setFloatingFrame(_ w: WindowNode, _ f: CGRect) {
        w.floatingFrame = f
        w.floatingFrameDirty = true
    }

    func setFloating(_ w: WindowNode, _ on: Bool) {
        guard w.isFloating != on, let ws = w.workspace else { return }
        if on {
            if w.floatingFrame == nil || !(monitor(ws.monitorID)?.visibleFrame.intersects(w.floatingFrame!) ?? true) {
                w.floatingFrame = w.rect
            }
            ws.detachTiled(w)
            w.isFloating = true
            w.floatingWorkspace = ws
            ws.floating.append(w)
            if ws.fullscreen === w { ws.fullscreen = nil }
            // A floated window should look floated: shrink a little and center.
            if let m = monitor(ws.monitorID), let f = w.floatingFrame {
                let v = m.visibleFrame
                setFloatingFrame(w, centered(size: CGSize(width: min(f.width, v.width * 0.7),
                                                          height: min(f.height, v.height * 0.7)), in: v))
            }
        } else {
            ws.floating.removeAll { $0 === w }
            w.isFloating = false
            w.isScratchpad = false
            w.floatingWorkspace = nil
            ws.attachTiled(w)
        }
        ws.touch(w)
    }

    func moveWorkspace(_ ws: Workspace, to t: OutputTarget) {
        guard let m = resolveOutput(t), m.id != ws.monitorID else { return }
        place(ws, on: m)
        focusedWorkspace = ws
        gc()
    }

    /// Shows `ws` on monitor `m`. The monitor it leaves, if it was showing it, shows another workspace.
    func place(_ ws: Workspace, on m: Monitor) {
        let oldID = ws.monitorID
        ws.homeMonitor = m.name  // the user put it there
        let wasVisible = isVisible(ws)
        translateFloating(ws, from: monitor(oldID), to: m)
        ws.monitorID = m.id
        visible[m.id] = ws
        if wasVisible, let old = monitor(oldID) {
            let left = workspaces.filter { $0.monitorID == oldID && $0 !== ws && !$0.isEmpty }
            visible[oldID] = recentlyShown.lazy.compactMap { name in left.first { $0.name == name } }.first
                ?? left.first
                ?? makeWorkspace(name: initialWorkspaceName(for: old), on: old)
        }
    }

    func focusDirection(_ dir: Direction, from node: Node?, in ws: Workspace) {
        let floatingWin = (node as? WindowNode).flatMap { $0.isFloating ? $0 : nil }
        if let node, floatingWin == nil, let w = ws.neighborWindow(of: node, dir) {
            setFocus(w)
            return
        }
        if let fw = floatingWin {
            let src = fw.floatingFrame ?? fw.rect
            let cands = ws.allWindows.filter { $0 !== fw }.map { ($0, $0.isFloating ? ($0.floatingFrame ?? $0.rect) : $0.rect) }
            if let w = geometricNeighbor(from: src, dir, among: cands) { setFocus(w); return }
        }
        let src = floatingWin.flatMap { $0.floatingFrame } ?? node?.rect ?? focusedMonitor.visibleFrame
        if let cur = monitor(ws.monitorID), let m = monitor(in: dir, from: cur), let dst = visible[m.id] {
            switchTo(dst)
            if let w = dst.descend(dst.root, dir, from: src) ?? dst.focusedWindow { setFocus(w) }
            return
        }
        if config.focusWrapping, let node, floatingWin == nil,
           let w = ws.descend(ws.root, dir, from: node.rect), w !== node {
            setFocus(w)
        }
    }

    func geometricNeighbor(from r: CGRect, _ dir: Direction, among cands: [(WindowNode, CGRect)]) -> WindowNode? {
        func score(_ c: CGRect) -> CGFloat? {
            let (dx, dy) = (c.midX - r.midX, c.midY - r.midY)
            let (along, across): (CGFloat, CGFloat)
            switch dir {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            return along > 1 ? along + 2 * abs(across) : nil
        }
        return cands.compactMap { c in score(c.1).map { (c.0, $0) } }.min { $0.1 < $1.1 }?.0
    }
}
