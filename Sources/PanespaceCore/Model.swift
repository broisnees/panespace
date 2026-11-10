import CoreGraphics
import Foundation

public struct Monitor: Equatable {
    public var id: MonitorID
    public var name: String
    /// Global coordinates, top-left origin (Accessibility API space).
    public var frame: CGRect
    /// `frame` minus menu bar and Dock.
    public var visibleFrame: CGRect
    public var isMain: Bool
    public init(id: MonitorID, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

/// Where the app layer should put a window.
public enum Placement: Equatable {
    case tiled(CGRect)
    /// `apply` = the model changed the frame and it must be written to the window.
    case floating(CGRect?, apply: Bool)
    case hidden(MonitorID)
}

/// Side effects the model can't perform itself.
public enum Effect: Equatable {
    case exec(String)
    case close(WindowID)
    case reload
    case exit
    case immersive(Toggle)
    case switcher
    case hints(swap: Bool)
    /// Put a window into (or out of) macOS full screen. nil: whichever window is in front.
    case nativeFullscreen(WindowID?, Toggle)
}

public struct CommandResult {
    public var errors: [String] = []
    public var effects: [Effect] = []
    public var ok: Bool { errors.isEmpty }
    public init() {}
}

public final class Model {
    public private(set) var config: Config
    public internal(set) var monitors: [Monitor] = []
    public internal(set) var workspaces: [Workspace] = []
    public internal(set) var visible: [MonitorID: Workspace] = [:]
    public internal(set) var focusedWorkspace: Workspace!
    public internal(set) var previousWorkspaceName: String?
    public internal(set) var windows: [WindowID: WindowNode] = [:]
    public internal(set) var scratchpad: [WindowNode] = []
    public internal(set) var mode = "default"

    public init(config: Config, monitors: [Monitor]) {
        precondition(!monitors.isEmpty, "need at least one monitor")
        self.config = config
        setMonitors(monitors)
    }

    public func setConfig(_ c: Config) {
        config = c
        if c.modes[mode] == nil { mode = "default" }
    }

    // MARK: Monitors

    public var focusedMonitor: Monitor { monitor(focusedWorkspace.monitorID) ?? monitors[0] }
    public var mainMonitor: Monitor { monitors.first { $0.isMain } ?? monitors[0] }

    public func monitor(_ id: MonitorID) -> Monitor? { monitors.first { $0.id == id } }

    public func monitor(containing p: CGPoint) -> Monitor? { monitors.first { $0.frame.contains(p) } }

    public func setMonitors(_ ms: [Monitor]) {
        guard !ms.isEmpty else { return }
        let old = monitors
        monitors = ms.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let ids = Set(ms.map(\.id))
        for id in visible.keys where !ids.contains(id) { visible[id] = nil }
        // Displaced: its display is gone. It keeps its home, to go back when the display returns.
        for ws in workspaces where !ids.contains(ws.monitorID) {
            let target = assignedMonitor(for: ws.name) ?? mainMonitor
            translateFloating(ws, from: old.first { $0.id == ws.monitorID }, to: target)
            ws.monitorID = target.id
        }
        // Back home: a display came back (or was re-identified), so its workspaces return to it.
        let added = monitors.filter { m in !old.contains { $0.id == m.id } }
        for m in added {
            for ws in workspaces where ws.monitorID != m.id {
                let pinned = assignedMonitor(for: ws.name)
                guard pinned?.id == m.id || (pinned == nil && ws.homeMonitor == m.name) else { continue }
                let from = monitor(ws.monitorID)
                if visible[ws.monitorID] === ws { visible[ws.monitorID] = nil }
                translateFloating(ws, from: from, to: m)
                ws.monitorID = m.id
                if visible[m.id] == nil || visible[m.id]?.isEmpty == true, !ws.isEmpty { visible[m.id] = ws }
            }
        }
        // A display whose shown workspace left with the others shows another of its own.
        for (mid, ws) in visible where ws.monitorID != mid { visible[mid] = nil }
        for m in [mainMonitor] + monitors.filter({ !$0.isMain && $0.id != mainMonitor.id }) where visible[m.id] == nil {
            if let ws = workspaces.first(where: { $0.monitorID == m.id && !$0.isEmpty }) {
                visible[m.id] = ws
            } else {
                visible[m.id] = makeWorkspace(name: initialWorkspaceName(for: m), on: m)
            }
        }
        if focusedWorkspace == nil || !isVisible(focusedWorkspace) {
            focusedWorkspace = visible[focusedWorkspace?.monitorID ?? mainMonitor.id] ?? visible[mainMonitor.id]
        }
        carryPinned()
        gc()
    }

    /// Resolves an i3 output spec: primary/main, secondary, 1-based index (left to right), or a name substring.
    public func monitor(matching spec: String) -> Monitor? {
        let s = spec.lowercased()
        switch s {
        case "primary", "main": return mainMonitor
        case "secondary": return monitors.first { !$0.isMain }
        default:
            if let i = Int(s), monitors.indices.contains(i - 1) { return monitors[i - 1] }
            return monitors.first { $0.name.lowercased() == s } ?? monitors.first { $0.name.lowercased().contains(s) }
        }
    }

    func assignedMonitor(for workspaceName: String) -> Monitor? {
        config.workspaceOutputs[workspaceName]?.lazy.compactMap { self.monitor(matching: $0) }.first
    }

    func monitor(in dir: Direction, from m: Monitor) -> Monitor? {
        let f = m.frame
        let others = monitors.filter { $0.id != m.id }
        let edge = others.filter {
            switch dir {
            case .left: return $0.frame.maxX <= f.minX + 1
            case .right: return $0.frame.minX >= f.maxX - 1
            case .up: return $0.frame.maxY <= f.minY + 1
            case .down: return $0.frame.minY >= f.maxY - 1
            }
        }
        func d(_ o: Monitor) -> CGFloat { hypot(o.frame.midX - f.midX, o.frame.midY - f.midY) }
        return edge.min { d($0) < d($1) }
    }

    func resolveOutput(_ t: OutputTarget) -> Monitor? {
        let cur = focusedMonitor
        switch t {
        case .direction(let d): return monitor(in: d, from: cur)
        case .next, .prev:
            guard let i = monitors.firstIndex(where: { $0.id == cur.id }), monitors.count > 1 else { return nil }
            return monitors[(i + (t == .next ? 1 : monitors.count - 1)) % monitors.count]
        case .name(let n): return monitor(matching: n)
        }
    }

    // MARK: Workspaces

    public func isVisible(_ ws: Workspace) -> Bool { visible[ws.monitorID] === ws }

    public func workspace(named name: String) -> Workspace? { workspaces.first { $0.name == name } }

    public var sortedWorkspaces: [Workspace] {
        workspaces.sorted { ($0.number ?? Int.max, $0.name) < ($1.number ?? Int.max, $1.name) }
    }

    func defaultLayout(for m: Monitor) -> Layout {
        if let l = config.workspaceLayout { return l }
        switch config.defaultOrientation {
        case .horizontal: return .splitH
        case .vertical: return .splitV
        case .auto: return m.visibleFrame.width >= m.visibleFrame.height ? .splitH : .splitV
        }
    }

    @discardableResult
    func makeWorkspace(name: String, on m: Monitor) -> Workspace {
        let ws = Workspace(name: name, monitorID: m.id, layout: defaultLayout(for: m))
        ws.homeMonitor = m.name
        workspaces.append(ws)
        return ws
    }

    func workspace(named name: String, create: Bool) -> Workspace? {
        if let ws = workspace(named: name) { return ws }
        guard create, !name.isEmpty else { return nil }
        return makeWorkspace(name: name, on: assignedMonitor(for: name) ?? focusedMonitor)
    }

    func initialWorkspaceName(for m: Monitor) -> String {
        let assigned = config.workspaceOutputOrder.filter { assignedMonitor(for: $0)?.id == m.id }
        if let n = assigned.first(where: { workspace(named: $0) == nil }) { return n }
        var i = 1
        while workspaces.contains(where: { $0.number == i }) || config.workspaceOutputs[String(i)] != nil
            && assignedMonitor(for: String(i))?.id != m.id { i += 1 }
        return String(i)
    }

    func resolveWorkspace(_ t: WorkspaceTarget, create: Bool) -> Workspace? {
        switch t {
        case .name(let n): return workspace(named: n, create: create)
        case .number(let s):
            let num = Int(String(s.prefix { $0.isASCII && $0.isNumber }))
            if let num, let ws = sortedWorkspaces.first(where: { $0.number == num }) { return ws }
            return workspace(named: s, create: create)
        case .next, .prev, .nextOnOutput, .prevOnOutput:
            let onOutput = t == .nextOnOutput || t == .prevOnOutput
            let list = sortedWorkspaces.filter { !onOutput || $0.monitorID == focusedWorkspace.monitorID }
            guard let i = list.firstIndex(where: { $0 === focusedWorkspace }), list.count > 1 else { return nil }
            let fwd = t == .next || t == .nextOnOutput
            return list[(i + (fwd ? 1 : list.count - 1)) % list.count]
        case .backAndForth:
            return previousWorkspaceName.flatMap { workspace(named: $0, create: create) }
        }
    }

    /// Shows `ws` (on its own monitor) and focuses it.
    func switchTo(_ ws: Workspace) {
        guard ws !== focusedWorkspace else { return }
        noteShown(focusedWorkspace)
        noteShown(ws)
        previousWorkspaceName = focusedWorkspace.name
        if !isVisible(ws) {
            if monitor(ws.monitorID) == nil { ws.monitorID = focusedMonitor.id }
            visible[ws.monitorID] = ws
        }
        focusedWorkspace = ws
        carryPinned()
        gc()
    }

    /// Pinned windows go with whatever workspace their display now shows, behind its own windows in focus order.
    func carryPinned() {
        for w in windows.values where w.isPinned {
            guard let src = w.workspace, !isVisible(src), let dst = visible[src.monitorID] else { continue }
            src.floating.removeAll { $0 === w }
            src.forget(w)
            dst.floating.append(w)
            dst.mru.append(w)
            w.floatingWorkspace = dst
            w.floatingFrameDirty = true  // it may have been parked off screen with the old workspace
        }
    }

    /// Workspace names, most recently shown first: what a display falls back to when its workspace leaves.
    var recentlyShown: [String] = []
    func noteShown(_ ws: Workspace) {
        recentlyShown.removeAll { $0 == ws.name }
        recentlyShown.insert(ws.name, at: 0)
        if recentlyShown.count > 32 { recentlyShown.removeLast() }
    }

    /// Drops empty workspaces nobody is looking at.
    func gc() {
        workspaces.removeAll { $0.isEmpty && !isVisible($0) && $0 !== focusedWorkspace }
    }

    func translateFloating(_ ws: Workspace, from a: Monitor?, to b: Monitor) {
        guard a?.id != b.id else { return }
        for w in ws.floating { moveFloating(w, from: a, to: b) }
    }

    func moveFloating(_ w: WindowNode, from a: Monitor?, to b: Monitor) {
        guard a?.id != b.id else { return }
        let v = b.visibleFrame
        var f = w.floatingFrame ?? centered(size: CGSize(width: v.width * 0.6, height: v.height * 0.6), in: v)
        if let a {
            f.origin.x += v.minX - a.visibleFrame.minX
            f.origin.y += v.minY - a.visibleFrame.minY
        }
        f.size.width = min(f.width, v.width)
        f.size.height = min(f.height, v.height)
        f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        w.floatingFrame = f
        w.floatingFrameDirty = true
    }

    func centered(size: CGSize, in r: CGRect) -> CGRect {
        CGRect(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    // MARK: Windows (driven by the app layer)

    /// Registers a newly seen window. `frame` is its current frame; with `useMonitorOfFrame`
    /// it joins the workspace visible on that monitor (startup), otherwise the focused one.
    /// `workspaceName` (restored session state) overrides both and `assign` rules.
    @discardableResult
    public func addWindow(_ id: WindowID, info: WindowInfo, floating: Bool, frame: CGRect?,
                          useMonitorOfFrame: Bool = false, workspaceName: String? = nil,
                          near neighbor: WindowID? = nil, before: Bool = false) -> WindowNode {
        if let w = windows[id] { return w }
        let w = WindowNode(id: id, info: info)
        w.preferredSize = frame?.size
        windows[id] = w
        var ws: Workspace = focusedWorkspace
        // At startup every window joins the workspace shown on its display. A new floating window (a dialog, a
        // panel, picture in picture) stays where its app put it, so it too joins the workspace shown there:
        // filed under the focused one on another display, it would hover over the wrong workspace.
        if useMonitorOfFrame || floating, let f = frame, let m = monitor(containing: CGPoint(x: f.midX, y: f.midY)),
           let v = visible[m.id] {
            ws = v
        }
        if let name = workspaceName, let target = workspace(named: name, create: true) {
            ws = target
        } else if let a = config.assignments.first(where: { $0.criteria.matches(w) }),
                  let target = resolveWorkspace(a.workspace, create: true) {
            ws = target
        }
        if floating {
            w.isFloating = true
            w.floatingWorkspace = ws
            w.floatingFrame = frame
            ws.floating.append(w)
        } else if let n = neighbor.flatMap({ windows[$0] }), n.workspace === ws, !n.isFloating {
            ws.attachTiled(w, near: n, before: before)  // back where it was
        } else if config.autoSplit {
            _ = placements()  // the focused tile's real shape, even when several windows arrive in one scan
            ws.attachDwindle(w)
        } else {
            ws.attachTiled(w)
        }
        ws.touch(w)
        return w
    }

    public func removeWindow(_ id: WindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        scratchpad.removeAll { $0 === w }
        if let ws = w.workspace {
            if w.isFloating { ws.floating.removeAll { $0 === w } } else { ws.detachTiled(w) }
            ws.forget(w)
        }
        gc()
    }

    public func updateInfo(_ id: WindowID, _ info: WindowInfo) { windows[id]?.info = info }

    /// Where a tiled window sits, so it can come back to the same place (after full screen, minimize, hide):
    /// a neighbouring window and which side of it.
    public func tileSpot(_ id: WindowID) -> (neighbor: WindowID, before: Bool)? {
        guard let w = windows[id], !w.isFloating, let p = w.parent, let i = w.index else { return nil }
        func window(_ n: Node, last: Bool) -> WindowNode? {
            n as? WindowNode ?? (n as? Container).flatMap { last ? $0.windows.last : $0.windows.first }
        }
        if i + 1 < p.children.count, let n = window(p.children[i + 1], last: false) { return (n.id, true) }
        if i > 0, let n = window(p.children[i - 1], last: true) { return (n.id, false) }
        return nil
    }

    /// The other windows that show together with `id` in a tabbed or stacked layout: when its tab holds a split,
    /// all of that split comes to the front, not just the focused window.
    public func tabMates(_ id: WindowID) -> [WindowID] {
        guard let w = windows[id], !w.isFloating else { return [] }
        var n: Node = w
        while let p = n.parent {
            if p.layout == .tabbed || p.layout == .stacking {
                return (n as? Container)?.windows.filter { $0 !== w }.map(\.id) ?? []
            }
            n = p
        }
        return []
    }

    /// Another window took `old`'s place on screen (the user picked a different native tab of the same tab
    /// group): it keeps the same tile, size, focus and workspace. No-op if `new` is already managed.
    public func replaceWindow(_ old: WindowID, with new: WindowID, info: WindowInfo) {
        guard old != new, windows[new] == nil, let w = windows.removeValue(forKey: old) else { return }
        w.id = new
        w.info = info
        windows[new] = w
    }

    /// The OS focused a window (click, Cmd-Tab, app activation). Follows it to its workspace.
    public func osFocused(_ id: WindowID) {
        guard let w = windows[id] else { return }
        if scratchpad.contains(where: { $0 === w }) { showScratchpad(w); return }
        setFocus(w)
    }

    /// A window came out bigger than its tile: the app has a minimum size. Tiles are laid out around it from now
    /// on. Returns whether that changed anything.
    @discardableResult
    public func noteMinimumSize(_ id: WindowID, actual: CGSize, wanted: CGSize) -> Bool {
        guard let w = windows[id], !w.isFloating else { return false }
        var m = w.minSize
        if actual.width > wanted.width + 2 { m.width = max(m.width, actual.width) }
        if actual.height > wanted.height + 2 { m.height = max(m.height, actual.height) }
        guard m != w.minSize else { return false }
        w.minSize = m
        return true
    }

    /// Records the real frame of a visible floating window.
    public func syncFloatingFrame(_ id: WindowID, _ f: CGRect) {
        guard let w = windows[id], w.isFloating, !w.floatingFrameDirty else { return }
        w.floatingFrame = f
        w.preferredSize = f.size
    }

    public func clearDirty(_ id: WindowID) { windows[id]?.floatingFrameDirty = false }

    /// A floating window came back (unhidden, unminimized): put it at the frame it had.
    public func restoreFloatingFrame(_ id: WindowID, _ f: CGRect) {
        guard let w = windows[id], w.isFloating else { return }
        w.floatingFrame = f
        w.floatingFrameDirty = true
    }

    /// Where every window lives, in visual order, for saving the session. Scratchpad windows have no workspace.
    public func sessionSnapshot() -> [(id: WindowID, workspace: String?, floating: Bool)] {
        sortedWorkspaces.flatMap { ws in ws.allWindows.map { ($0.id, Optional(ws.name), $0.isFloating) } }
            + scratchpad.map { ($0.id, nil, true) }
    }

    /// Restores a saved focus: shows `name` on its monitor and focuses it.
    public func restoreFocus(workspace name: String) {
        if let ws = workspace(named: name) { switchTo(ws) }
    }

    /// The user finished dragging a floating window to `f`. If it now sits on another monitor,
    /// it joins the workspace shown there (position kept as dropped).
    public func floatingWindowDropped(_ id: WindowID, frame f: CGRect) {
        guard let w = windows[id], w.isFloating, let src = w.workspace else { return }
        w.floatingFrame = f
        w.floatingFrameDirty = false
        guard let m = monitor(containing: CGPoint(x: f.midX, y: f.midY)), m.id != src.monitorID,
              let dst = visible[m.id] else { return }
        src.floating.removeAll { $0 === w }
        src.forget(w)
        dst.floating.append(w)
        w.floatingWorkspace = dst
        setFocus(w)
        gc()
    }

    public var focusedWindow: WindowNode? { focusedWorkspace.focusedWindow }

    /// The window the user sees under `p` (floating before tiled, most recent first).
    public func window(at p: CGPoint) -> WindowNode? {
        guard let m = monitor(containing: p), let ws = visible[m.id] else { return nil }
        if let fs = ws.fullscreen { return fs }
        return ws.mru.first { $0.isFloating && ($0.floatingFrame?.contains(p) ?? false) }
            ?? ws.mru.first { !$0.isFloating && $0.rect.contains(p) }
    }

    func setFocus(_ w: WindowNode) {
        guard let ws = w.workspace else { return }
        if ws !== focusedWorkspace { switchTo(ws) }
        ws.touch(w)
        ws.selected = nil
        if let fs = ws.fullscreen, fs !== w, !w.isFloating { ws.fullscreen = nil }
    }

    /// The user resized a tiled window with the mouse: turn the new edges into weights.
    /// `from` is the window's real frame before this step. Apps that snap their size (terminals) never quite
    /// match `rect`, so diffing against `rect` would read that snap as a drag. Without `from`, `rect` is used
    /// with a little slack.
    public func userResized(_ id: WindowID, from: CGRect? = nil, to f: CGRect) {
        guard let w = windows[id], !w.isFloating, let ws = w.workspace, ws.fullscreen !== w else { return }
        if w.isPseudo {  // its edges are its own size, not the split's: it stays centered in the tile
            w.preferredSize = f.size
            return
        }
        let old = from ?? w.rect
        let slack: CGFloat = from == nil ? 2 : 0.5
        let inner = config.gaps.inner
        if abs(f.minX - old.minX) > slack {
            ws.resize(w, axis: .horizontal, amount: .px(old.minX - f.minX), towardStart: true, inner: inner)
        } else if abs(f.maxX - old.maxX) > slack {
            ws.resize(w, axis: .horizontal, amount: .px(f.maxX - old.maxX), towardStart: false, inner: inner)
        }
        if abs(f.minY - old.minY) > slack {
            ws.resize(w, axis: .vertical, amount: .px(old.minY - f.minY), towardStart: true, inner: inner)
        } else if abs(f.maxY - old.maxY) > slack {
            ws.resize(w, axis: .vertical, amount: .px(f.maxY - old.maxY), towardStart: false, inner: inner)
        }
    }

    // MARK: Placement

    /// Computes where every window belongs. Also refreshes node rects.
    public func placements() -> [WindowID: Placement] {
        var out: [WindowID: Placement] = [:]
        for ws in workspaces {
            if isVisible(ws), let m = monitor(ws.monitorID) {
                for w in ws.floating { out[w.id] = .floating(w.floatingFrame, apply: w.floatingFrameDirty) }
                for (id, r) in LayoutEngine.layout(ws, on: m, config: config) { out[id] = .tiled(r) }
            } else {
                for w in ws.allWindows { out[w.id] = .hidden(ws.monitorID) }
            }
        }
        for w in scratchpad { out[w.id] = .hidden(focusedMonitor.id) }
        return out
    }

    // MARK: Moving nodes between workspaces

    func windows(in n: Node) -> [WindowNode] { (n as? Container)?.windows ?? [n as! WindowNode] }

    func workspace(of n: Node) -> Workspace? { (n as? WindowNode)?.workspace ?? n.treeRoot?.owner }

    func moveNode(_ node: Node, to dst: Workspace, anchor: Node? = nil, before: Bool = false) {
        guard let src = workspace(of: node), src !== dst else { return }
        let moved = src.mru.filter { $0.isInside(node) }
        let rest = windows(in: node).filter { w in !moved.contains { $0 === w } }
        if let w = node as? WindowNode, w.isFloating {
            src.floating.removeAll { $0 === w }
            dst.floating.append(w)
            w.floatingWorkspace = dst
            if src.monitorID != dst.monitorID, let b = monitor(dst.monitorID) {
                moveFloating(w, from: monitor(src.monitorID), to: b)
            }
        } else {
            src.detachTiled(node)
            if anchor == nil, config.autoSplit { dst.attachDwindle(node) } else { dst.attachTiled(node, near: anchor, before: before) }
            dst.normalize()
        }
        for w in (moved + rest).reversed() {
            src.forget(w)
            dst.touch(w)
        }
        if src.selected === node { src.selected = nil }
        gc()
    }

    // MARK: Scratchpad

    func hideToScratchpad(_ w: WindowNode) {
        guard let ws = w.workspace else { return }
        if w.isFloating {
            ws.floating.removeAll { $0 === w }
        } else {
            ws.detachTiled(w)
            let v = (monitor(ws.monitorID) ?? focusedMonitor).visibleFrame
            let size = w.rect.width > 0 ? w.rect.size : CGSize(width: v.width * 0.6, height: v.height * 0.6)
            w.floatingFrame = centered(size: CGSize(width: min(size.width, v.width * 0.8),
                                                    height: min(size.height, v.height * 0.8)), in: v)
        }
        ws.forget(w)
        w.isFloating = true
        w.isPinned = false
        w.floatingWorkspace = nil
        w.isScratchpad = true
        scratchpad.append(w)
        gc()
    }

    func showScratchpad(_ w: WindowNode) {
        let ws = focusedWorkspace!
        if let cur = w.workspace, cur !== ws {
            moveNode(w, to: ws)
        } else if w.workspace == nil {
            scratchpad.removeAll { $0 === w }
            w.isFloating = true
            w.floatingWorkspace = ws
            ws.floating.append(w)
            let m = focusedMonitor
            if let f = w.floatingFrame, !m.visibleFrame.intersects(f) {
                moveFloating(w, from: monitors.first { $0.visibleFrame.intersects(f) }, to: m)
            } else if w.floatingFrame == nil {
                moveFloating(w, from: nil, to: m)
            }
            w.floatingFrameDirty = true
        }
        setFocus(w)
    }
}
