import Foundation

/// One row of the window switcher.
public struct SwitcherEntry: Equatable {
    public let id: WindowID
    public let app: String
    public let bundleID: String
    public let pid: pid_t
    public let title: String
    /// nil = in the scratchpad.
    public let workspace: String?
    public let isFloating: Bool
}

extension Model {
    /// Every window, most useful first: the focused workspace's (most recent first), then the other shown
    /// workspaces', then the hidden ones in workspace order, then the scratchpad. The window already focused
    /// goes last, so Return on the first row always goes somewhere.
    public func switcherEntries() -> [SwitcherEntry] {
        func entry(_ w: WindowNode, _ ws: Workspace?) -> SwitcherEntry {
            SwitcherEntry(id: w.id, app: w.info.app, bundleID: w.info.bundleID, pid: w.info.pid, title: w.info.title,
                          workspace: ws?.name, isFloating: w.isFloating)
        }
        func ordered(_ ws: Workspace) -> [WindowNode] {
            ws.mru + ws.allWindows.filter { w in !ws.mru.contains { $0 === w } }
        }
        let shown = sortedWorkspaces.filter { isVisible($0) && $0 !== focusedWorkspace }
        let hidden = sortedWorkspaces.filter { !isVisible($0) }
        var out = ([focusedWorkspace] + shown + hidden).flatMap { ws in ordered(ws).map { entry($0, ws) } }
        out += scratchpad.filter { $0.workspace == nil }.map { entry($0, nil) }
        if let f = focusedWindow, let i = out.firstIndex(where: { $0.id == f.id }) { out.append(out.remove(at: i)) }
        return out
    }
}

/// Fuzzy matching for the switcher, VS Code style: the query's characters in order, anywhere in the text.
/// Higher scores for runs of consecutive characters, word starts and the app name; nil when it doesn't match.
public enum Fuzzy {
    public static func score(_ query: String, _ e: SwitcherEntry) -> Int? {
        let q = query.lowercased().filter { !$0.isWhitespace }
        if q.isEmpty { return 0 }
        // The app name counts more than the title; "3" or "ws3" finds windows on workspace 3.
        let app = score(q, in: e.app).map { $0 * 3 / 2 + 20 }
        let title = score(q, in: e.title)
        let both = score(q, in: e.app + " " + e.title)
        let ws = e.workspace.flatMap { name in score(q, in: name).map { _ in q.count <= name.count + 2 ? 30 : 0 } }
            ?? (q == e.workspace.map { "ws" + $0 } ? 30 : nil)
        return [app, title, both, ws].compactMap { $0 }.max()
    }

    /// Subsequence score of `q` (already lowercased) in `text`.
    static func score(_ q: String, in text: String) -> Int? {
        let t = Array(text.lowercased())
        let qs = Array(q)
        guard !qs.isEmpty, qs.count <= t.count else { return nil }
        var score = 0, ti = 0, run = 0
        var prev: Character = " "
        for c in qs {
            var found = false
            while ti < t.count {
                let ch = t[ti]
                let before = ti > 0 ? t[ti - 1] : " "
                ti += 1
                if ch == c {
                    run = prev == before && ti > 1 && run > 0 ? run + 1 : 1
                    let wordStart = !(before.isLetter || before.isNumber)
                    score += 1 + (run > 1 ? 5 * run : 0) + (wordStart ? 8 : 0) + (ti == 1 ? 10 : 0)
                    prev = ch
                    found = true
                    break
                }
                run = 0
            }
            if !found { return nil }
        }
        return score - t.count / 8  // shorter texts win ties
    }

    /// Entries matching `query`, best first; ties keep the given order (recency).
    public static func filter(_ query: String, _ entries: [SwitcherEntry]) -> [SwitcherEntry] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return entries }
        return entries.enumerated()
            .compactMap { i, e in score(query, e).map { (e, $0, i) } }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }
}
