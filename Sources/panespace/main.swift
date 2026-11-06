import AppKit
import MacKit
import ApplicationServices
import PanespaceCore

let panespaceVersion = "0.1.0"

let help = """
panespace \(panespaceVersion) — i3-style tiling window manager for macOS

USAGE
  panespace                      start the window manager (foreground)
  panespace msg <command>        run an i3 command, e.g. panespace msg focus left
  panespace msg -t <type>        query: get_tree, get_workspaces, get_bindings, get_binding_modes, get_config, get_version, get_stats
  panespace <command>            shorthand for `panespace msg <command>`
  panespace stats                speed and cost: key-to-frame latency, frame rate, scans, CPU, memory
  panespace list-windows         show every window and how panespace classifies it (for writing rules)
  panespace preview-indicator <png>  render every menu bar indicator look to an image
  panespace check-config [path]  parse a config and print warnings
  panespace init-config          write the default config if none exists, print its path

Config: \(configURL().path)
"""

func configURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    return base.appendingPathComponent("panespace/config")
}

func send(_ type: String, _ payload: String) -> Never {
    guard let resp = IPC.send(type: type, payload: payload) else {
        fputs("panespace: not running (no socket at \(IPC.socketPath))\n", stderr)
        exit(1)
    }
    print(resp)
    exit(resp.contains("\"success\" : false") ? 2 : 0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var wm: WindowManager?
    private var waitItem: NSStatusItem?
    private var waitTimer: Timer?
    /// Held for the app's lifetime: App Nap would coalesce our timers and stretch animations and key handling.
    /// Idle system sleep stays allowed.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Tiling windows")
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) { return start() }
        log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Panespace ⚠︎"
        let menu = NSMenu()
        menu.addItem(withTitle: "Grant Accessibility access…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        waitItem = item
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            if let item = self?.waitItem { NSStatusBar.system.removeStatusItem(item) }
            self?.start()
        }
    }

    @objc func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func start() {
        let wm = WindowManager(configURL: configURL())
        self.wm = wm
        wm.start()
    }

    func applicationWillTerminate(_ notification: Notification) { wm?.restoreAllWindows() }
}

var signalSources: [DispatchSourceSignal] = []

func runDaemon() -> Never {
    if IPC.send(type: "get_version", payload: "") != nil {
        fputs("panespace: already running\n", stderr)
        exit(0)  // not a failure: launchd's KeepAlive must not keep relaunching a duplicate
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            if let wm = delegate.wm { wm.shutdown() }
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
    app.run()
    exit(0)
}

func listWindows() -> Never {
    guard AXIsProcessTrusted() else {
        fputs("panespace: this terminal needs Accessibility permission to read windows\n", stderr)
        exit(1)
    }
    let server = windowServerSnapshot()
    let start = Date()
    var rows: [[String]] = [["ID", "KIND", "APP", "BUNDLE ID", "SUBROLE", "FRAME", "TITLE"]]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let el = AXUIElement.app(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1)
        for w in el.windows {
            let id = w.windowID
            let kind = id.map { _ in classify(w, bundleID: app.bundleIdentifier ?? "", layer: server[id!]?.layer) } ?? .ignore
            let f = w.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
            rows.append([id.map(String.init) ?? "-", w.isMinimized ? "minimized" : "\(kind)",
                         app.localizedName ?? "?", app.bundleIdentifier ?? "", w.subrole ?? "", f,
                         String(w.title.prefix(50))])
        }
    }
    let widths = rows[0].indices.map { i in rows.map { $0[i].count }.max()! }
    for r in rows {
        print(r.enumerated().map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
    print(String(format: "\n%d windows read in %.0f ms", rows.count - 1, Date().timeIntervalSince(start) * 1000))
    exit(0)
}

/// `panespace stats`: the daemon's numbers, readable.
func printStats() -> Never {
    guard let resp = IPC.send(type: "get_stats", payload: ""), let data = resp.data(using: .utf8),
          let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("panespace: not running (no socket at \(IPC.socketPath))\n", stderr)
        exit(1)
    }
    func n(_ k: String) -> String { s[k].map { "\($0)" } ?? "–" }
    func dist(_ k: String) -> String {
        guard let d = s[k] as? [String: Any], let med = d["median"] else { return "no samples yet" }
        return "median \(med) ms · p95 \(d["p95"] ?? "–") ms · worst \(d["max"] ?? "–") ms  (\(d["samples"] ?? 0) samples)"
    }
    let up = (s["uptime_s"] as? Int) ?? 0
    print("""
    Panespace \(panespaceVersion), up \(up / 3600)h \(up / 60 % 60)m
      key → first frame  \(dist("key_to_frame_ms"))
      animations         \(n("animations")) · \(n("fps_avg")) fps average · slowest frame \(n("slowest_frame_ms")) ms
      window scans       \(n("syncs")) · \(dist("sync_ms"))
      CPU                \(n("cpu_avg_percent"))% average · \(n("cpu_recent_percent"))% last few minutes
      memory             \(n("memory_mb")) MB · \(n("threads")) threads
      managing           \(n("windows")) windows · \(n("workspaces")) workspaces · \(n("displays")) displays · \(n("commands")) commands run
    """)
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil, "start": runDaemon()
case "msg":
    var a = Array(args.dropFirst())
    var type = "run_command"
    if a.first == "-t", a.count >= 2 {
        type = a[1]
        a.removeFirst(2)
    }
    send(type, a.joined(separator: " "))
case "list-windows": listWindows()
case "stats": printStats()
case "preview-indicator":
    WorkspaceIcon.writePreview(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "indicator-preview.png"))
case "check-config":
    let url = args.count > 1 ? URL(fileURLWithPath: args[1]) : configURL()
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("panespace: cannot read \(url.path)\n", stderr)
        exit(1)
    }
    let c = Config.parse(text)
    let n = c.modes.values.reduce(0) { $0 + $1.count }
    print("\(url.path): \(n) bindings in \(c.modes.count) mode(s), \(c.rules.count) rules")
    c.warnings.forEach { print("warning: \($0)") }
    exit(c.warnings.isEmpty ? 0 : 2)
case "init-config":
    let url = configURL()
    if !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DefaultConfig.text.write(to: url, atomically: true, encoding: .utf8)
    }
    print(url.path)
case "help", "-h", "--help": print(help)
case "version", "-v", "--version": print(panespaceVersion)
default: send("run_command", args.joined(separator: " "))
}
