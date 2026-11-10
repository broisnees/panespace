#!/usr/bin/env python3
"""Panespace end-to-end: drives the real daemon over IPC with real windows (testwin) on a workspace of its own,
and checks what is on screen against what the model says. Prints PASS/FAIL per check and timings."""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = []
TOL = 3


def msg(*a, t=None):
    cmd = ["panespace", "msg"] + (["-t", t] if t else []) + list(a)
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    return json.loads(out) if out.strip() else None


def run(c):
    r = msg(c)
    if not r or not r[0].get("success"):
        raise RuntimeError(f"command '{c}' failed: {r}")


def windows():
    return {w["id"]: w for w in msg(t="get_windows")}


def tree():
    return msg(t="get_tree")


def ws_nodes(name):
    """(tiled, floating) window nodes of workspace `name`, and the workspace node."""
    for o in tree()["outputs"]:
        for w in o["workspaces"]:
            if w["name"] == name:
                tiled, fl = [], []
                def walk(n, floating=False):
                    if n.get("type") == "window":
                        (fl if n.get("floating") else tiled).append(n)
                    for c in n.get("nodes", []):
                        walk(c)
                    for c in n.get("floating_nodes", []):
                        walk(c, True)
                walk(w)
                return tiled, fl, w
    return [], [], None


def focused_id():
    def walk(n):
        if n.get("type") == "window" and n.get("focused"):
            return n["id"]
        for c in n.get("nodes", []) + n.get("floating_nodes", []):
            r = walk(c)
            if r:
                return r
    for o in tree()["outputs"]:
        for w in o["workspaces"]:
            r = walk(w)
            if r:
                return r


def rect(n):
    r = n["rect"]
    return [r["x"], r["y"], r["width"], r["height"]]


def close(a, b, tol=TOL):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return max(0, min(ax + aw, bx + bw) - max(ax, bx)) * max(0, min(ay + ah, by + bh) - max(ay, by))


def check(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (f"  — {detail}" if detail and not ok else (f"  ({detail})" if detail else "")), flush=True)


def settle(ws="e2e", timeout=3.0):
    """Waits until every tiled window of `ws` is where the model says. Returns (seconds, mismatches)."""
    t0 = time.time()
    while True:
        tiled, _, _ = ws_nodes(ws)
        real = windows()
        bad = [(n["id"], n.get("title", ""), rect(n), real.get(n["id"], {}).get("frame")) for n in tiled
               if not real.get(n["id"]) or not close(rect(n), real[n["id"]]["frame"])]
        if not bad or time.time() - t0 > timeout:
            return time.time() - t0, bad
        time.sleep(0.03)


class App:
    def __init__(self, tag):
        self.p = subprocess.Popen([os.path.join(HERE, "testwin"), tag], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert self.p.stdout.readline().strip() == "ready"
        self.tag = tag

    def do(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        return self.p.stdout.readline().strip()

    def open(self, n=1):
        return [int(k) for k in self.do(f"open {n}").split()[1:]]

    def quit(self):
        try:
            self.do("quit")
        except Exception:
            pass
        self.p.wait(timeout=5)


def wid(app, k, dialog=False, timeout=3.0):
    title = f"E2E-{app.tag}-{k}" + ("-dialog" if dialog else "")
    t0 = time.time()
    while time.time() - t0 < timeout:
        for w in windows().values():
            if w.get("title") == title:
                return w["id"]
        time.sleep(0.05)
    raise RuntimeError(f"window {title} never appeared")


def managed(i, timeout=3.0):
    """Waits until window `i` is in the model; returns seconds."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        for o in tree()["outputs"]:
            for w in o["workspaces"]:
                if str(i) in json.dumps(w) and f'"id": {i}' in json.dumps(w):
                    return time.time() - t0
        time.sleep(0.03)
    return None


def cpu(pid):
    out = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return float(out or 0)


def pid_of(name):
    out = subprocess.run(["pgrep", "-f" if "/" in name else "-x", name], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def main():
    start_ws = next(w["name"] for w in msg(t="get_workspaces") if w.get("focused"))
    pane, ws_pid = pid_of("Panespace.app/Contents/MacOS/panespace"), pid_of("WindowServer")
    stats0 = msg(t="get_stats")
    run("workspace e2e")
    a = App("A")
    try:
        # 1. New windows tile (auto_split), real frames match the model, no overlaps.
        ks = a.open(1)
        w1 = wid(a, ks[0]); t_new = managed(w1)
        check("new window is managed", t_new is not None, f"{t_new:.2f}s" if t_new is not None else "never")
        ks += a.open(1); w2 = wid(a, ks[1]); managed(w2)
        ks += a.open(1); w3 = wid(a, ks[2]); managed(w3)
        ks += a.open(1); w4 = wid(a, ks[3]); managed(w4)
        dt, bad = settle()
        check("4 windows: real frames match tiles", not bad, f"settled in {dt:.2f}s" if not bad else f"{bad}")
        tiled, _, wsn = ws_nodes("e2e")
        frames = [windows()[n["id"]]["frame"] for n in tiled]
        ov = [(i, j, overlap(frames[i], frames[j])) for i in range(len(frames)) for j in range(i + 1, len(frames)) if overlap(frames[i], frames[j]) > 50]
        check("4 windows: no overlaps", not ov, f"{ov}")
        mon = msg(t="get_tree")["outputs"][0]["rect"]
        area = sum(f[2] * f[3] for f in frames)
        check("4 windows: tiles fill the screen", area > 0.85 * mon["width"] * (mon["height"] - 33), f"{area} of {mon['width'] * mon['height']}")
        shapes = [(f[2], f[3]) for f in frames]
        check("dwindle: not all in one row", len({f[1] for f in frames}) > 1, f"{frames}")

        # 2. Focus and move by direction.
        a.do(f"front {ks[0]}"); time.sleep(0.3)
        t0 = time.time(); run("focus right"); t_focus = time.time() - t0
        f = focused_id()
        check("focus right moves focus", f is not None and f != w1, f"focused={f} cmd {t_focus*1000:.0f}ms")
        before = {n["id"]: rect(n) for n in ws_nodes("e2e")[0]}
        run("move left"); dt, bad = settle()
        after = {n["id"]: rect(n) for n in ws_nodes("e2e")[0]}
        check("move left changes layout and windows follow", before != after and not bad, f"{bad}")

        # 3. Resize by direction (with real windows).
        run(f'[title="^E2E-A-{ks[0]}$"] focus')

        r0 = rect(next(n for n in ws_nodes("e2e")[0] if n["id"] == w1))
        run("resize right 80 px"); dt, bad = settle()
        r1 = rect(next(n for n in ws_nodes("e2e")[0] if n["id"] == w1))
        check("resize right grows the window's right edge", r1[2] > r0[2] and not bad, f"{r0} -> {r1} {bad}")
        run("resize left 80 px"); settle()
        r2 = rect(next(n for n in ws_nodes("e2e")[0] if n["id"] == w1))
        check("resize left moves it back", abs(r2[2] - r0[2]) <= TOL, f"{r0} vs {r2}")

        # 4. Workspace switch away and back: hidden then restored, timing.
        t0 = time.time(); run("workspace e2e-other"); t_away = time.time() - t0
        time.sleep(0.4)
        real = windows()
        vis = [i for i in (w1, w2, w3, w4) if real[i]["frame"][0] < mon["width"] - 50 and real[i]["frame"][1] < mon["height"] - 50]
        check("switching away parks the windows", not vis, f"still visible: {vis}")
        t0 = time.time(); run("workspace e2e"); dt, bad = settle(); t_back = time.time() - t0
        check("switching back restores every tile", not bad, f"{t_back:.2f}s" if not bad else f"{bad}")

        # 5. Pseudotile.
        run(f'[title="^E2E-A-{ks[1]}$"] focus'); run("pseudo enable"); time.sleep(0.4)
        n2 = next(n for n in ws_nodes("e2e")[0] if n["id"] == w2); real2 = windows()[w2]["frame"]
        inside = real2[0] >= n2["rect"]["x"] - TOL and real2[0] + real2[2] <= n2["rect"]["x"] + n2["rect"]["width"] + TOL             and real2[2] * real2[3] < n2["rect"]["width"] * n2["rect"]["height"] * 0.9
        centered = abs((real2[0] + real2[2] / 2) - (n2["rect"]["x"] + n2["rect"]["width"] / 2)) <= 4
        check("pseudo: smaller and centered in its tile", inside and centered, f"tile {rect(n2)} window {real2}")
        frames_seen = set()
        for _ in range(15):
            frames_seen.add(tuple(windows()[w2]["frame"])); time.sleep(0.07)
        check("pseudo: no flicker (frame stays put)", len(frames_seen) == 1, f"{len(frames_seen)} different frames: {list(frames_seen)[:4]}")
        run("pseudo disable"); settle()

        # 6. Floating dialog: floats, stays above tiles after focusing a tile, reachable by direction.
        dk = int(a.do("dialog").split()[1]); d = wid(a, dk, dialog=True); managed(d)
        _, fl, _ = ws_nodes("e2e")
        check("dialog is floating", any(n["id"] == d for n in fl), f"floating={[n['id'] for n in fl]}")
        run(f'[title="^E2E-A-{ks[2]}$"] focus'); time.sleep(0.5)
        z = subprocess.run([os.path.join(HERE, "zorder")], capture_output=True, text=True).stdout.split("\n")
        order = [int(l.split()[0]) for l in z if l.strip()]
        # raise-loop regression: focus tiles back and forth with a float present; Panespace and WindowServer stay calm
        for i in range(10):
            run("focus left" if i % 2 else "focus right"); time.sleep(0.05)
        time.sleep(1.0)
        c_pane, c_ws = cpu(pane), cpu(ws_pid)
        time.sleep(1.0)
        c_pane, c_ws = max(c_pane, cpu(pane)), max(c_ws, cpu(ws_pid))
        check("no raise loop: Panespace idle after focus churn with a dialog", c_pane < 30, f"panespace {c_pane}% windowserver {c_ws}%")
        a.do(f"close {dk}")
        # 6b. A dialog from ANOTHER app (System Settings, a permission prompt) opening over a focused tile.
        b = App("B")
        try:
            run(f'[title="^E2E-A-{ks[2]}$"] focus'); time.sleep(0.4)
            bk = int(b.do("dialog").split()[1]); bd = wid(b, bk, dialog=True); managed(bd); time.sleep(0.8)
            order = [int(l.split()[0]) for l in subprocess.run([os.path.join(HERE, "zorder")], capture_output=True, text=True).stdout.split("\n") if l.strip()]
            check("other app's new dialog is on top", order.index(bd) < order.index(w3), f"z: dialog@{order.index(bd)} tile@{order.index(w3)}")
            run(f'[title="^E2E-A-{ks[0]}$"] focus'); time.sleep(0.4)
            run("focus mode_toggle"); time.sleep(0.5)
            order = [int(l.split()[0]) for l in subprocess.run([os.path.join(HERE, "zorder")], capture_output=True, text=True).stdout.split("\n") if l.strip()]
            check("focus mode_toggle (leader v) brings the dialog back on top", focused_id() == bd and order.index(bd) == 0, f"focused={focused_id()} z: dialog@{order.index(bd)}")
        finally:
            b.quit()

        # 7. Pin follows workspaces.
        run(f'[title="^E2E-A-{ks[3]}$"] focus'); run("pin enable")
        run("workspace e2e-other"); time.sleep(0.5)
        f4 = windows()[w4]["frame"]
        check("pinned window stays on screen on another workspace", f4[0] < mon["width"] - 50, f"{f4}")
        run("workspace e2e"); run(f'[title="^E2E-A-{ks[3]}$"] pin disable'); run(f'[title="^E2E-A-{ks[3]}$"] floating disable'); settle()
        check("unpinned window tiles again", w4 in [n["id"] for n in ws_nodes("e2e")[0]], f"tiles={[n['id'] for n in ws_nodes('e2e')[0]]}")

        # 8. Minimize leaves the layout, restore brings it back to its spot.
        a.do(f"minimize {ks[1]}"); time.sleep(0.8)
        ids = [n["id"] for n in ws_nodes("e2e")[0]]
        dt, bad = settle()
        check("minimized window leaves the layout, others re-tile", w2 not in ids and not bad, f"w2={w2} tiles={ids} {bad}")
        a.do(f"restore {ks[1]}"); time.sleep(1.0)
        ids = [n["id"] for n in ws_nodes("e2e")[0]]
        dt, bad = settle()
        check("restored window comes back tiled", w2 in ids and not bad, f"tiles={ids} {bad}")

        # 8b. Bring a minimized window back by command (what the switcher does): same spot, focused, quick.
        spot = rect(next(n for n in ws_nodes("e2e")[0] if n["id"] == w3))
        a.do(f"minimize {ks[2]}"); time.sleep(0.8)
        check("minimized (2nd) leaves the layout", w3 not in [n["id"] for n in ws_nodes("e2e")[0]])
        t0 = time.time(); run(f'[title="^E2E-A-{ks[2]}$"] focus')
        back = None
        while time.time() - t0 < 3:
            if w3 in [n["id"] for n in ws_nodes("e2e")[0]] and focused_id() == w3:
                back = time.time() - t0; break
            time.sleep(0.03)
        dt, bad = settle()
        now = next((rect(n) for n in ws_nodes("e2e")[0] if n["id"] == w3), None)
        check("focus on a minimized window restores it, focused", back is not None and not bad, f"{back:.2f}s" if back else f"{bad}")
        check("restored window is back in its old spot", now is not None and close(now, spot), f"{spot} -> {now}")

        # 9. App minimum size: tiles make room instead of overlapping.
        a.do(f"minsize {ks[0]} 900 300"); run(f'[title="^E2E-A-{ks[0]}$"] focus'); run("balance"); time.sleep(1.0)
        dt, bad = settle(timeout=2)
        frames = [windows()[n["id"]]["frame"] for n in ws_nodes("e2e")[0]]
        ov = [(i, j) for i in range(len(frames)) for j in range(i + 1, len(frames)) if overlap(frames[i], frames[j]) > 50]
        check("min-size window: no overlaps", not ov, f"{frames}")
        a.do(f"minsize {ks[0]} 100 100")

        # 10. Stress: 8 windows open fast, then all close; layout consistent and quick.
        t0 = time.time(); more = a.open(8)
        ids = [wid(a, k) for k in more]
        for i in ids:
            managed(i)
        dt, bad = settle(timeout=5); t_open = time.time() - t0
        frames = [windows()[n["id"]]["frame"] for n in ws_nodes("e2e")[0]]
        ov = [(i, j) for i in range(len(frames)) for j in range(i + 1, len(frames)) if overlap(frames[i], frames[j]) > 50]
        check("stress: 12 windows tiled without overlap", not bad and not ov, f"{t_open:.2f}s" if not bad and not ov else f"{bad} {ov}")
        t0 = time.time()
        for k in more:
            a.do(f"close {k}")
        time.sleep(0.6); dt, bad = settle(); t_close = time.time() - t0
        n_left = len(ws_nodes("e2e")[0])
        check("stress: closing 8 gives their space back", n_left == 4 and not bad, f"{n_left} tiles left, {t_close:.2f}s {bad}")

        # Timings
        check("timing: workspace switch away < 150ms", t_away < 0.15, f"{t_away*1000:.0f}ms")
        check("timing: workspace switch back settled < 400ms", t_back < 0.4, f"{t_back*1000:.0f}ms")
    finally:
        a.quit()
        time.sleep(0.5)
        try:
            run(f'workspace "{start_ws}"')
        except Exception as e:
            print("could not go back:", e)
    stats1 = msg(t="get_stats")
    print("\nstats before:", json.dumps(stats0))
    print("stats after: ", json.dumps(stats1))
    fails = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(fails)}/{len(RESULTS)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
