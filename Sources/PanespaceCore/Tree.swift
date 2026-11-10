import CoreGraphics
import Foundation

public typealias WindowID = UInt32
public typealias MonitorID = UInt32

public enum Orientation: String {
    case horizontal, vertical
    public var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Layout: String, CaseIterable {
    case splitH = "splith", splitV = "splitv", tabbed, stacking

    /// tabbed behaves horizontally and stacking vertically, as in i3.
    public var orientation: Orientation {
        switch self {
        case .splitH, .tabbed: return .horizontal
        case .splitV, .stacking: return .vertical
        }
    }
    public var isSplit: Bool { self == .splitH || self == .splitV }
    public static func split(_ o: Orientation) -> Layout { o == .horizontal ? .splitH : .splitV }
}

public enum Direction: String, CaseIterable {
    case left, right, up, down
    public var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// right/down walk towards higher child indices.
    public var isForward: Bool { self == .right || self == .down }
}

public class Node {
    public internal(set) weak var parent: Container?
    /// Share of the parent's length along its split axis, relative to siblings' weights.
    public internal(set) var weight: CGFloat = 1
    /// Rect assigned by the last layout pass (global, top-left origin).
    public internal(set) var rect: CGRect = .zero

    public var index: Int? { parent?.children.firstIndex { $0 === self } }

    /// Topmost container this node hangs from (nil for a detached window).
    var treeRoot: Container? {
        var n: Node = self
        while let p = n.parent { n = p }
        return n as? Container
    }

    func isInside(_ c: Node) -> Bool {
        var n: Node? = self
        while let x = n {
            if x === c { return true }
            n = x.parent
        }
        return false
    }
}

public final class Container: Node {
    public var layout: Layout {
        didSet { if layout.isSplit { lastSplit = layout } }
    }
    /// Split layout to return to from tabbed/stacking.
    public private(set) var lastSplit: Layout
    public internal(set) var children: [Node] = []
    /// Created by `split` and still waiting for its second child; survives normalization.
    var pendingSplit = false
    /// Set only on a workspace's root container.
    public internal(set) weak var owner: Workspace?

    public init(layout: Layout) {
        self.layout = layout
        self.lastSplit = layout.isSplit ? layout : .splitH
    }

    /// Inserts `n` (detaching it from any previous parent). A new child gets the average sibling weight.
    func insert(_ n: Node, at i: Int, keepWeight: Bool = false) {
        n.parent?.remove(n)
        if !keepWeight {
            n.weight = children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / CGFloat(children.count)
        }
        n.parent = self
        children.insert(n, at: max(0, min(i, children.count)))
        if children.count > 1 { pendingSplit = false }
    }

    func append(_ n: Node) { insert(n, at: children.count) }

    func remove(_ n: Node) {
        guard let i = children.firstIndex(where: { $0 === n }) else { return }
        children.remove(at: i)
        n.parent = nil
    }

    /// Puts `new` in `old`'s slot, inheriting its weight.
    func replace(_ old: Node, with new: Node) {
        guard old.parent === self else { return }
        new.parent?.remove(new)
        guard let i = old.index else { return }
        new.weight = old.weight
        children[i] = new
        new.parent = self
        old.parent = nil
    }

    /// All windows below this container, depth-first in visual order.
    public var windows: [WindowNode] {
        children.flatMap { ($0 as? Container)?.windows ?? [$0 as! WindowNode] }
    }
}

public struct WindowInfo: Equatable {
    public var app: String
    public var bundleID: String
    public var title: String
    public var pid: Int32
    public init(app: String, bundleID: String = "", title: String = "", pid: Int32 = 0) {
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.pid = pid
    }
}

public final class WindowNode: Node {
    /// Changes only when a native tab takes over its sibling's place (`Model.replaceWindow`).
    public internal(set) var id: WindowID
    public var info: WindowInfo
    public internal(set) var isFloating = false
    /// Desired frame while floating (global coords). Synced from the real window by the app layer.
    public internal(set) var floatingFrame: CGRect?
    /// Set when the model moved/resized a floating window and the app layer must apply `floatingFrame`.
    public internal(set) var floatingFrameDirty = false
    /// Window came from (or lives in) the scratchpad.
    public internal(set) var isScratchpad = false
    /// Smallest size the app was seen to accept; tiling gives it at least this much when there's room.
    public internal(set) var minSize: CGSize = .zero
    /// Pseudotiled: keeps its own size (`preferredSize`), centered in its tile, instead of filling it.
    public internal(set) var isPseudo = false
    /// The size the window wants when pseudotiled: its size when first seen or last floating.
    public internal(set) var preferredSize: CGSize?
    /// Pinned: a floating window that stays on screen whichever workspace its display shows.
    public internal(set) var isPinned = false
    weak var floatingWorkspace: Workspace?

    public init(id: WindowID, info: WindowInfo) {
        self.id = id
        self.info = info
    }

    public var workspace: Workspace? { isFloating ? floatingWorkspace : treeRoot?.owner }
}

public final class Workspace {
    public let name: String
    public let root: Container
    public internal(set) var floating: [WindowNode] = []
    /// Most-recently-focused first. Includes floating windows.
    public internal(set) var mru: [WindowNode] = []
    public internal(set) var fullscreen: WindowNode? {
        // A floating window leaving full screen goes back to its own frame, which has to be written again.
        didSet { if let old = oldValue, old !== fullscreen, old.isFloating { old.floatingFrameDirty = true } }
    }
    /// The display (by name) this workspace belongs on. It survives the display being unplugged, so the
    /// workspace goes back there when it's plugged in again.
    var homeMonitor: String?
    /// Container selected via `focus parent`; nil when a window is focused.
    public internal(set) var selected: Container?
    public internal(set) var monitorID: MonitorID

    init(name: String, monitorID: MonitorID, layout: Layout) {
        self.name = name
        self.monitorID = monitorID
        self.root = Container(layout: layout)
        root.owner = self
    }

    /// Leading number of the name ("3: web" → 3), used for `workspace number` and sorting.
    public var number: Int? { Int(String(name.prefix { $0.isASCII && $0.isNumber })) }
    public var isEmpty: Bool { root.children.isEmpty && floating.isEmpty }
    public var focusedWindow: WindowNode? { mru.first }
    public var focusedNode: Node? { selected ?? mru.first }
    public var mostRecentTiled: WindowNode? { mru.first { !$0.isFloating } }
    public var tiledWindows: [WindowNode] { root.windows }
    public var allWindows: [WindowNode] { root.windows + floating }

    func touch(_ w: WindowNode) {
        mru.removeAll { $0 === w }
        mru.insert(w, at: 0)
    }

    func forget(_ w: WindowNode) {
        mru.removeAll { $0 === w }
        if fullscreen === w { fullscreen = nil }
    }

    /// Child of `c` on the path to the most recently focused window inside it.
    public func mostRecentChild(of c: Container) -> Node? {
        for w in mru where !w.isFloating {
            var n: Node = w
            while let p = n.parent {
                if p === c { return n }
                n = p
            }
        }
        return c.children.first
    }
}
