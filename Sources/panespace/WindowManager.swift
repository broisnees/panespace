import AppKit
import MacKit
import ApplicationServices
import Carbon
import PanespaceCore

private let logTime = ISO8601DateFormatter()

/// Thread-safe (stderr writes are atomic per line).
func log(_ s: String) {
    FileHandle.standardError.write(Data("\(logTime.string(from: Date())) panespace: \(s)\n".utf8))
}

enum Screens {
    /// NSScreen (bottom-left origin) → Accessibility coordinates (top-left origin of the primary screen).
    static func read() -> [Monitor] {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            let r = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            return [Monitor(id: 0, name: "fallback", frame: r, visibleFrame: r, isMain: true)]
        }
        let h = primary.frame.height
        func ax(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Monitor(id: id, name: s.localizedName, frame: ax(s.frame), visibleFrame: ax(s.visibleFrame),
                           isMain: s == primary)
        }
    }
}

/// Lock-protected integer, for focus generations read off the main thread.
final class Counter {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.withLock { v } }
    func increment() -> Int { lock.withLock { v += 1; return v } }
}

/// One AXObserver per app process. Created off the main thread (talking to a launching app can block);
/// its callbacks are delivered on the main run loop.
final class AppTracker {
    let app: NSRunningApplication
    let pid: pid_t
    let element: AXUIElement
    private let observer: AXObserver
    private let lock = NSLock()
    private var watched = Set<CGWindowID>()

    init?(_ app: NSRunningApplication, refcon: UnsafeMutableRawPointer) {
        self.app = app
        pid = app.processIdentifier
        element = .app(pid)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return nil }
        observer = obs
        var ok = false
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            ok = AXObserverAddNotification(obs, element, n as CFString, refcon) == .success || ok
        }
        guard ok else { return nil }  // app not ready for AX yet; retried on the next sync
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func watch(_ w: AXUIElement, id: CGWindowID, refcon: UnsafeMutableRawPointer) {
        guard lock.withLock({ watched.insert(id).inserted }) else { return }
        for n in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                  kAXWindowMiniaturizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, w, n as CFString, refcon)
        }
    }

    func unwatch(_ id: CGWindowID) { lock.withLock { _ = watched.remove(id) } }

    deinit { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
}

private func axCallback(_: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().handleAX(element, notification as String)
}

/// Threading model:
/// - main thread: the model and all bookkeeping. Never waits on another app.
/// - `axQueue` (serial): every frame write and focus change, in command order.
/// - `syncQueue` (serial): window enumeration, one thread per app inside.
/// - `eventQueue` (serial): small reads triggered by notifications (focused window, frames, titles).
final class WindowManager {
    let model: Model
    let configURL: URL
    private(set) var configWarnings: [String] = []
    private let tap = EventTap()
    private let statusBar = StatusBar()
    private let border = FocusBorder()
    let stats = Stats()
    /// When the command being applied was asked for (key press or CLI), to time it to the first frame.
    private var commandAt: Double?
    let chrome = MacChrome()
    private let switcher = SwitcherPanel()

    private let axQueue = DispatchQueue(label: "panespace.ax", qos: .userInteractive)
    private let syncQueue = DispatchQueue(label: "panespace.sync", qos: .userInitiated)
    private let eventQueue = DispatchQueue(label: "panespace.events", qos: .userInteractive)
    private let focusGeneration = Counter()

    private var trackers: [pid_t: AppTracker] = [:]
    private var elements: [WindowID: AXUIElement] = [:]
    private var pids: [WindowID: pid_t] = [:]
    private var hiddenByUs = Set<WindowID>()
    private var lastApplied: [WindowID: CGRect] = [:]
    /// Last size we wrote; when unchanged a move needs one AX call instead of three.
    private var appliedSize: [WindowID: CGSize] = [:]
    private var reappliedAt: [WindowID: Date] = [:]
    /// Times in a row an app moved its window back after we put it in its tile.
    private var fights: [WindowID: Int] = [:]
    /// The `for_window` rules (by index) already applied to each window.
    private var rulesRun: [WindowID: Set<Int>] = [:]
    /// Windows that left the layout for a while (minimized, app hidden, briefly unlisted): where they lived,
    /// so they come back to the same workspace instead of the focused one.
    private var parked: [WindowID: (workspace: String, floating: Bool, frame: CGRect?, spot: (neighbor: WindowID, before: Bool)?, until: Date)] = [:]
    /// New windows already seen listed-but-not-shown once (re-checked once, not on every sweep).
    private var offscreenSeen = Set<WindowID>()
    /// When a window last left the screen (closed, minimized, app hidden or quit). macOS then hands focus to
    /// some other window, often one on another workspace: that is not the user asking to go there.
    private var windowLostAt = Date.distantPast
    /// Consecutive syncs a still-existing window was missing from its app's list.
    private var missing: [WindowID: Int] = [:]
    private var dragged: [WindowID: Bool] = [:]  // true = was resized
    /// Last frame each window reported, the baseline for diffing a mouse resize (apps snap sizes, so not `rect`).
    private var seenFrame: [WindowID: CGRect] = [:]
    /// The tiled window whose edge the user is dragging; its neighbours are re-tiled live around it.
    private var liveResize: WindowID?
    private var liveApplyBusy = false
    private var liveApplyAgain = false
    /// Mouse is up but `mouseUp` hasn't run yet; drag notifications still in flight count as the drag.
    private var mouseUpPending = false
    // Layout animation.
    private let animGeneration = Counter()
    private let liveFrames = FrameStore()
    /// Windows the running animation is moving; a newer layout picks them up mid-flight.
    private var animating = Set<WindowID>()
    /// After an animation, late move notifications for its windows are ours, not the app's.
    private var settling: [WindowID: Date] = [:]
    /// Windows whose real frame we don't know (new, or moved by their app or macOS): animate from a fresh read.
    private var unsure = Set<WindowID>()
    /// The workspace each monitor showed at the last layout, to tell which way a switch slides.
    private var shownOn: [MonitorID: String] = [:]
    /// The next layout jumps instead of gliding (the displays changed).
    private var instantNext = false
    /// Layouts wait until then (macOS is still running its own zoom animation).
    private var holdApplyUntil = Date.distantPast
    /// The title-bar double-click that already became a zoom.
    private var zoomedClick = 0
    // Trackpad gestures.
    private var trackpad: Trackpad?
    private let swipeTrack = SwipeTrack()
    /// A sideways swipe in progress: the workspaces either side, and (when windows follow the fingers live)
    /// where those neighbours' windows wait off-screen.
    private var swipe: (monitor: Monitor, prev: Workspace?, next: Workspace?, homes: [WindowID: CGRect])?
    /// After a swipe that didn't switch to them: where the neighbours' windows go back to before parking.
    private var swipeHomes: [WindowID: CGRect] = [:]
    /// The next apply follows a swipe's end.
    private var swipeJustEnded = false
    /// Windows their app made cover a whole display (a game's or player's borderless full screen), and that
    /// frame. Panespace leaves them be until the app shrinks them again.
    private var appFullscreen: [WindowID: CGRect] = [:]
    /// The last click on a window's green (full-screen) button: that one full screen becomes Panespace's zoom.
    private var greenButton: (id: WindowID, at: Date)?
    /// Windows in macOS full screen right now (on their own Space): kept out of the layout until they leave.
    private var nativeFullscreen = Set<WindowID>()
    /// New windows left alone because they were born full screen (logged once each).
    private var fullscreenSkipped = Set<WindowID>()
    /// Until then, macOS is sliding between Spaces: window moves are its animation, not the app's.
    private var spaceSettleUntil = Date.distantPast
    /// The layout being applied comes from the user's own command (not an app or macOS event).
    private var userAsked = false
    private var modDrag: ModDrag?
    /// Bumped on every mod-drag begin and end, so a hit test that lands after its drag ended is dropped.
    private var modDragGeneration = 0
    private var lastFocused: WindowID?
    private var pendingFocus: (id: WindowID, until: Date)?
    private var lastFocusedMonitor: MonitorID?
    private let focusHolder = FocusHolder()
    private var applyQueued = false
    private var syncScope: SyncScope?
    private var syncInFlight = false
    private var startup = true
    private var capsActive = false
    private var lastMouseMove = Date.distantPast
    private var secureInput = false
    private var timers: [Timer] = []
    private let debug = ProcessInfo.processInfo.environment["PANESPACE_DEBUG"] != nil
    /// AX and event-tap callbacks hold this pointer, so the manager is retained for the life of the process.
    private lazy var refcon: UnsafeMutableRawPointer = Unmanaged.passRetained(self).toOpaque()

    /// Session saved across restarts (window → workspace). /tmp is wiped on reboot, when window IDs change.
    private struct Session: Codable {
        struct Entry: Codable {
            var id: UInt32
            var workspace: String?
            var floating: Bool
            var bundle: String
        }
        var focused: String
        var windows: [Entry]
    }
    private static let sessionPath = "/tmp/panespace-\(getuid())-session.json"
    private var restoring: Session?
    private var lastSavedSession: Data?

    init(configURL: URL) {
        self.configURL = configURL
        let (cfg, warnings) = WindowManager.loadConfig(configURL)
        configWarnings = warnings
        model = Model(config: cfg, monitors: Screens.read())
        if let d = FileManager.default.contents(atPath: Self.sessionPath) {
            restoring = try? JSONDecoder().decode(Session.self, from: d)
        }
    }

    private func timed<T>(_ label: @autoclosure () -> String, _ body: () -> T) -> T {
        guard debug else { return body() }
        let t = DispatchTime.now().uptimeNanoseconds
        let r = body()
        log(String(format: "%@ %.2f ms", label(), Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6))
        return r
    }

    // MARK: Lifecycle

    func start() {
        _ = refcon
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tap.onCommand = { [unowned self] cmd, at in runCommand(cmd, keyAt: at) }
        tap.onMouseUp = { [unowned self] in mouseUp() }
        tap.onMouseDown = { [unowned self] in clicked(at: $0) }
        tap.onMouseMoved = { [unowned self] in mouseMoved($0) }
        tap.onModDrag = { [unowned self] phase, p in
            switch phase {
            case .begin(let resize): modDragBegan(at: p, resize: resize)
            case .move: modDragMoved(to: p)
            case .end: modDragEnded(at: p)
            }
        }
        if !tap.start() { log("could not create the event tap; hotkeys are disabled") }
        applyBindings()
        if !IPC.serve({ [unowned self] in handleIPC($0, $1) }, offMain: { type, _ in type == "get_windows" ? allWindowsJSON() : nil }) {
            log("could not open \(IPC.socketPath)")
        }

        let nc = NSWorkspace.shared.notificationCenter
        func pid(_ n: Notification) -> pid_t? {
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            guard let p = pid(n) else { return }
            requestSync(.apps([p]))
            // Apps often answer AX only a moment after launch: look again soon, then a few more times.
            for d in [0.15, 0.4, 0.8, 1.5, 3] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.requestSync(.apps([p])) } }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            guard let p = pid(n) else { return }
            windowLostAt = Date()
            trackers[p] = nil
            requestSync(.apps([p]))
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            refreshOSFocus()
            if let p = pid(n) { requestSync(.apps([p])) }  // also catches windows that never announced themselves
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [unowned self] n in
                if let p = pid(n) { requestSync(.apps([p])) }
            }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [unowned self] _ in
            spaceSettleUntil = Date().addingTimeInterval(1.5)
            requestSync(.all)
            checkSpaces()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.screensChanged()
                self.updateTrackpad(restart: true)  // trackpads can stop reporting after sleep
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [unowned self] _ in screensChanged() }

        // Idle cost: no app is asked anything unless something changed. Once in a while, a full sweep as a
        // safety net for ghosts; in between, a cheap look at the window server's list (no app involved) spots
        // windows that appeared or vanished without telling us, and only their apps get scanned.
        let sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [unowned self] _ in
            requestSync(.all)
            pruneStale()
            stats.sampleCPU()
        }
        sweep.tolerance = 5
        let tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in
            watchWindowServer()
            let s = IsSecureEventInputEnabled()
            if s != secureInput { secureInput = s; updateStatus() }
            saveSession()  // only writes when something moved; survives crashes and kills
            checkSpaces()
        }
        tick.tolerance = 0.5  // lets macOS batch our wake-ups with others
        timers += [sweep, tick]

        statusBar.install(manager: self)
        watchConfig()
        checkSpaces()
        if let want = model.config.immersive { chrome.set(want) }
        requestSync(.all)
        for c in model.config.execs + model.config.execAlways { exec(c) }
        if !configWarnings.isEmpty { log("config warnings:\n  " + configWarnings.joined(separator: "\n  ")) }
        log("started with \(model.monitors.count) monitor(s); config \(configURL.path)")
    }

    func shutdown() {
        saveSession()
        chrome.restore()
        CapsLock.disable()
        restoreAllWindows()
        unlink(IPC.socketPath)
        exit(0)
    }

    /// Puts every window we parked off-screen back where the user can reach it.
    func restoreAllWindows() {
        swipeTrack.finish()  // a swipe in progress only ends when main says so: end it, or the wait below never returns
        _ = animGeneration.increment()
        axQueue.sync {}  // let queued moves finish first
        for id in hiddenByUs {
            guard let el = elements[id], let w = model.windows[id] else { continue }
            let m = w.workspace.flatMap { model.monitor($0.monitorID) } ?? model.mainMonitor
            let v = m.visibleFrame
            if w.isFloating, let f = w.floatingFrame, v.intersects(f) {
                el.setFrame(f)
            } else {
                let s = el.size ?? CGSize(width: v.width * 0.6, height: v.height * 0.6)
                let size = CGSize(width: min(s.width, v.width), height: min(s.height, v.height))
                el.setFrame(CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2,
                                   width: size.width, height: size.height))
            }
        }
        hiddenByUs.removeAll()
    }

    /// Drops bookkeeping for windows that are no longer managed. `forget` clears all of it when a window goes;
    /// this catches anything a path missed, so a long-running daemon can't slowly collect stale entries
    /// (or act on a stale one if macOS reuses the window ID).
    private func pruneStale() {
        let live = Set(model.windows.keys)
        let before = elements.count + lastApplied.count + seenFrame.count + settling.count + rulesRun.count
        func keep<V>(_ d: inout [WindowID: V]) { d = d.filter { live.contains($0.key) } }
        keep(&elements); keep(&pids); keep(&lastApplied); keep(&appliedSize); keep(&reappliedAt); keep(&fights)
        keep(&rulesRun); keep(&missing); keep(&dragged); keep(&seenFrame); keep(&appFullscreen); keep(&settling)
        settling = settling.filter { $0.value > Date() }
        hiddenByUs.formIntersection(live)
        unsure.formIntersection(live)
        animating.formIntersection(live)
        liveFrames.keep(live)
        let server = Set(windowServerSnapshot().keys)
        if !server.isEmpty {
            fullscreenSkipped.formIntersection(server)
            nativeFullscreen.formIntersection(server)
            parked = parked.filter { server.contains($0.key) && $0.value.until > Date() }
        }
        if debug {
            let after = elements.count + lastApplied.count + seenFrame.count + settling.count + rulesRun.count
            if after != before { log("pruned \(before - after) stale per-window entries") }
        }
    }

    /// On-screen normal windows → their app, as of the last look.
    private var serverWindows: [CGWindowID: pid_t] = [:]

    /// Diffs the window server's on-screen list (one local call, no app is asked) and scans just the apps
    /// whose windows came or went. Catches windows that never announce themselves, and tab switches.
    private func watchWindowServer() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        let me = getpid()
        var now: [CGWindowID: pid_t] = [:]
        now.reserveCapacity(serverWindows.count)
        for d in list where d[kCGWindowLayer as String] as? Int == 0 {
            guard let n = d[kCGWindowNumber as String] as? Int, let p = d[kCGWindowOwnerPID as String] as? Int,
                  pid_t(p) != me else { continue }
            now[CGWindowID(n)] = pid_t(p)
        }
        guard now != serverWindows else { return }
        var changed = Set<pid_t>()
        for (id, p) in now where serverWindows[id] == nil { changed.insert(p) }
        for (id, p) in serverWindows where now[id] == nil { changed.insert(p) }
        serverWindows = now
        if !changed.isEmpty { requestSync(.apps(changed)) }
    }

    private func saveSession() {
        let entries = model.sessionSnapshot().map {
            Session.Entry(id: $0.id, workspace: $0.workspace, floating: $0.floating,
                          bundle: model.windows[$0.id]?.info.bundleID ?? "")
        }
        guard let data = try? JSONEncoder().encode(Session(focused: model.focusedWorkspace.name, windows: entries)),
              data != lastSavedSession else { return }
        lastSavedSession = data
        FileManager.default.createFile(atPath: Self.sessionPath, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: Config

    static func loadConfig(_ url: URL) -> (Config, [String]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? DefaultConfig.text.write(to: url, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? DefaultConfig.text
        let c = Config.parse(text)
        return (c, c.warnings)
    }

    private var configWatcher: DispatchSourceFileSystemObject?
    private var configReloadWork: DispatchWorkItem?
    private var lastConfigText: String?

    /// Hot reload: the config is read again whenever it's saved. Editors often save by replacing the file,
    /// so the watch is re-armed after a rename or delete (and retried until the new file exists).
    private func watchConfig() {
        configWatcher?.cancel()
        configWatcher = nil
        if lastConfigText == nil { lastConfigText = try? String(contentsOf: configURL, encoding: .utf8) }
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watchConfig() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            let replaced = !src.data.isDisjoint(with: [.rename, .delete])
            configReloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if replaced { watchConfig() }
                // Only when the text really changed (saving twice, or a touch, does nothing).
                let text = try? String(contentsOf: configURL, encoding: .utf8)
                guard let text, text != lastConfigText else { return }
                lastConfigText = text
                log("config changed on disk; reloading")
                reload()
            }
            configReloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)  // editors write in bursts
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }

    func reload() {
        lastConfigText = try? String(contentsOf: configURL, encoding: .utf8)
        let before = model.config.immersive
        let (c, w) = WindowManager.loadConfig(configURL)
        configWarnings = w
        model.setConfig(c)
        lastApplied.removeAll()
        applyBindings()
        if let want = c.immersive, want != before { chrome.set(want) }
        for cmd in c.execAlways { exec(cmd) }
        log(w.isEmpty ? "config reloaded" : "config reloaded with warnings:\n  " + w.joined(separator: "\n  "))
        apply()
    }

    private func applyBindings() {
        let caps = model.config.usesCapsLock
        if caps != capsActive {  // hidutil only when the setting changes, not on every mode switch
            if caps { CapsLock.enable() } else { CapsLock.disable() }
            capsActive = caps
        }
        tap.setBindings(model.config.modes[model.mode] ?? [:], trackMouseMoves: model.config.focusFollowsMouse,
                        floatingModifier: model.config.floatingModifier, capsLock: caps,
                        interceptFullscreen: model.config.interceptNativeFullscreen,
                        oneShot: model.config.oneShotModes.contains(model.mode))
        updateTrackpad()
        updateStatus()
    }

    // MARK: Commands

    /// Never touches another app synchronously: model update, then the AX work is queued.
    @discardableResult
    func runCommand(_ text: String, keyAt: Double? = nil) -> CommandResult {
        stats.command()
        commandAt = keyAt ?? CACurrentMediaTime()
        defer { commandAt = nil }
        userAsked = true  // a key, the menu or the CLI: allowed to take the user out of a full-screen Space
        defer { userAsked = false }
        let modeBefore = model.mode
        let r = timed("model.run '\(text)'") { model.run(text) }
        perform(r.effects)
        if model.mode != modeBefore { applyBindings() }
        if !r.ok { log("command '\(text)': \(r.errors.joined(separator: "; "))") }
        timed("apply") { apply() }
        return r
    }

    private func perform(_ effects: [Effect]) {
        for e in effects {
            switch e {
            case .exec(let c): exec(c)
            case .close(let id):
                if let el = elements[id] { axQueue.async { el.element(kAXCloseButtonAttribute)?.perform(kAXPressAction) } }
            case .reload: DispatchQueue.main.async { self.reload() }
            case .exit: DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.shutdown() }
            case .immersive(let t):
                chrome.set(t == .toggle ? !chrome.isImmersive : t == .enable)
                updateStatus()
            case .switcher: DispatchQueue.main.async { self.openSwitcher() }
            }
        }
    }

    /// The window switcher, on the focused monitor. Picking a window goes to its workspace and focuses it;
    /// dismissing it gives the keyboard back to the window that had it.
    private func openSwitcher() {
        let m = model.focusedMonitor
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == m.id
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }  // no display at all (mid-wake)
        switcher.show(model.switcherEntries(), on: screen.visibleFrame) { [weak self] id in
            guard let self else { return }
            userAsked = true
            defer { userAsked = false }
            if let id, model.windows[id] != nil { model.osFocused(id) }
            lastFocused = nil  // the switcher had the keyboard: always focus again
            pendingFocus = nil
            apply()
        }
    }

    /// Window hints over every visible window. Picking one focuses it (or swaps it with the focused one); either
    private func exec(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("exec '\(cmd)' failed: \(error)") }
    }

    func handleIPC(_ type: String, _ payload: String) -> String {
        switch type {
        case "run_command", "command":
            let r = runCommand(payload)
            var d: [String: Any] = ["success": r.ok]
            if !r.ok { d["error"] = r.errors.joined(separator: "; ") }
            return IPC.json([d])
        case "get_tree": return IPC.json(model.treeJSON())
        case "get_workspaces": return IPC.json(model.workspacesJSON())
        case "get_binding_modes": return IPC.json(model.config.modes.keys.sorted())
        case "get_bindings":
            return IPC.json((model.config.modes[model.mode] ?? [:]).map { ["key": $0.key.description, "command": $0.value] })
        case "get_config": return IPC.json(["path": configURL.path, "warnings": configWarnings])
        case "get_version": return IPC.json(["version": panespaceVersion])
        case "get_stats":
            return IPC.json(stats.json(windows: model.windows.count, workspaces: model.workspaces.count,
                                       displays: model.monitors.count))
        default: return IPC.json(["success": false, "error": "unknown message type '\(type)'"])
        }
    }

    // MARK: Events

    func handleAX(_ el: AXUIElement, _ n: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)  // local, no round trip to the app
        switch n {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Our own animation frames echo back here, per window per frame. Drop them before the 3 AX reads below
            // compete with the apps (and our own writes) for nothing.
            if !animating.isEmpty || !settling.isEmpty, let id = elements.first(where: { CFEqual($0.value, el) })?.key,
               animating.contains(id) || (settling[id].map { Date() < $0 } ?? false) { return }
            let resized = n == kAXWindowResizedNotification
            eventQueue.async { [weak self] in
                guard let id = el.windowID else { return }
                let frame = el.frame
                let fullScreen = el.isFullScreen
                DispatchQueue.main.async { self?.windowMoved(id, pid: pid, frame: frame, resized: resized, fullScreen: fullScreen) }
            }
        case kAXTitleChangedNotification:
            eventQueue.async { [weak self] in
                guard let id = el.windowID else { return }
                let title = el.title
                DispatchQueue.main.async {
                    guard let self, var info = self.model.windows[id]?.info, info.title != title else { return }
                    info.title = title
                    self.model.updateInfo(id, info)
                    self.runRules(id)
                }
            }
        case kAXFocusedWindowChangedNotification:
            refreshOSFocus()
            requestSync(.apps([pid]))
        case kAXUIElementDestroyedNotification:
            // Closed: give its space back right away instead of waiting for a rescan.
            if let id = elements.first(where: { CFEqual($0.value, el) })?.key {
                windowLostAt = Date()
                forget(id)
                scheduleApply()
            }
            requestSync(.apps([pid]))
        default:  // window created/minimized, app hidden/shown
            if n == kAXWindowMiniaturizedNotification || n == kAXApplicationHiddenNotification { windowLostAt = Date() }
            requestSync(.apps([pid]))
        }
    }

    private func windowMoved(_ id: WindowID, pid: pid_t, frame: CGRect?, resized: Bool, fullScreen: Bool) {
        guard let w = model.windows[id], modDrag == nil else { return }
        // Going into macOS full screen (a video, a music player, a game): never fight the transition. A scan of
        // its app sets the window aside like a minimized one; it comes back to its tile when it leaves.
        if fullScreen { return requestSync(.apps([pid])) }
        // Our own animation frames, and their stragglers.
        if animating.contains(id) || (settling[id].map { Date() < $0 } ?? false) { return }
        let click = tap.click
        let clicking = tap.isMouseDown || mouseUpPending
        // A title-bar double-click: macOS zoomed (or unzoomed) the window. Make it Panespace's zoom instead.
        if resized, !w.isFloating, click.count >= 2, !click.dragged, click.seq != zoomedClick,
           clicking || Date().timeIntervalSince(click.upAt) < 0.6,
           let r = lastApplied[id], r.contains(click.down), click.down.y - r.minY < 52 {
            return titleBarZoom(id, click: click.seq)
        }
        // Only a real drag is the user moving or resizing; a still click that moved the window was the app.
        if clicking && click.dragged {
            if let live = liveResize, live != id { return }  // our own re-tiling of its neighbours
            if resized, !w.isFloating, let f = frame {
                liveResize = id
                model.userResized(id, from: seenFrame[id] ?? lastApplied[id], to: f)
                seenFrame[id] = f
                liveApply()
            }
            dragged[id] = (dragged[id] ?? false) || resized
            border.hide()
            return
        }
        if let frame { seenFrame[id] = frame }
        // Floating: wherever it goes (its app, Rectangle, a keyboard shortcut) is its new home.
        if w.isFloating {
            if let f = frame, !hiddenByUs.contains(id), onScreen(f) { model.syncFloatingFrame(id, f) }
            return
        }
        // The app made its window cover a whole display (a game's or video player's borderless full screen):
        // its call. Leave it until the app shrinks it again, then put it back in its tile.
        if let f = frame, !w.isFloating, coversDisplay(f), !(lastApplied[id].map { $0.insetBy(dx: -2, dy: -2).contains(f) } ?? false) {
            appFullscreen[id] = f
            return
        }
        if appFullscreen.removeValue(forKey: id) != nil {
            lastApplied[id] = nil
            appliedSize[id] = nil
            unsure.insert(id)
            return scheduleApply()
        }
        // macOS sliding between Spaces, or the user away in a full-screen Space: not the app moving its window.
        if Date() < spaceSettleUntil || spaces.activeIsFullscreen { return }
        // The app moved its own window (e.g. restored a saved frame). Put it back, at most once a second
        // so apps that snap sizes (terminals) can't make us loop.
        guard let target = lastApplied[id], let f = frame,
              Date().timeIntervalSince(reappliedAt[id] ?? .distantPast) > 1 else { return }
        if abs(f.minX - target.minX) > 2 || abs(f.minY - target.minY) > 2
            || abs(f.width - target.width) > 30 || abs(f.height - target.height) > 30 {
            // Third time in a row within a few seconds: the app insists (an emulator keeping its aspect ratio).
            // Let it have its frame until the layout itself changes, instead of flickering forever.
            let last = reappliedAt[id] ?? .distantPast
            fights[id] = Date().timeIntervalSince(last) < 4 ? (fights[id] ?? 0) + 1 : 1
            if fights[id]! >= 3 {
                if debug { log("window \(id) keeps resizing itself; leaving it at \(f)") }
                lastApplied[id] = f
                appliedSize[id] = f.size
                return
            }
            reappliedAt[id] = Date()
            lastApplied[id] = nil
            appliedSize[id] = nil
            unsure.insert(id)
            scheduleApply()
        }
    }

    /// Mostly on a display: a frame worth remembering for a floating window (not one parked in a corner).
    private func onScreen(_ f: CGRect) -> Bool {
        let area = f.width * f.height
        guard area > 0 else { return false }
        return model.monitors.contains { m in
            let i = m.visibleFrame.intersection(f)
            return !i.isNull && i.width * i.height >= area * 0.3
        }
    }

    private func coversDisplay(_ f: CGRect) -> Bool {
        model.monitors.contains { f.insetBy(dx: -2, dy: -2).contains($0.frame) }
    }

    /// A click in a window's top-left corner might be on its green button: check, off the main thread (the hit
    /// test asks the app). That window's next macOS full screen becomes Panespace's zoom instead.
    private func clicked(at p: CGPoint) {
        // The user picks the window now: a focus Panespace asked for a moment ago (still queued, or awaiting its
        // report) must neither land after this click nor make its report look stale.
        pendingFocus = nil
        _ = focusGeneration.increment()
        guard model.config.interceptNativeFullscreen, let w = model.window(at: p),
              let r = w.isFloating ? w.floatingFrame : lastApplied[w.id], p.x - r.minX < 100, p.y - r.minY < 60 else { return }
        let id = w.id
        eventQueue.async { [weak self] in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
                  hit?.subrole == kAXFullScreenButtonSubrole as String else { return }
            DispatchQueue.main.async { self?.greenButton = (id, Date()) }
        }
    }

    /// macOS zoomed the window after a title-bar double-click: toggle Panespace's zoom (fullscreen) instead.
    /// The layout waits out macOS's own zoom animation so the two don't fight, then glides from where it ended.
    private func titleBarZoom(_ id: WindowID, click: Int) {
        zoomedClick = click
        settling[id] = Date().addingTimeInterval(0.3)
        holdApplyUntil = Date().addingTimeInterval(0.25)
        model.run("fullscreen toggle", on: id)
        unsure.insert(id)
        lastApplied[id] = nil
        appliedSize[id] = nil
        scheduleApply()
    }

    /// Reads which window the OS has focused, off the main thread, and follows it.
    private func refreshOSFocus(recheck: Bool = false, retry: Bool = true) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        guard pid != getpid() else { return }
        eventQueue.async { [weak self] in
            let id = AXUIElement.app(pid).focusedWindow?.windowID
            DispatchQueue.main.async {
                guard let self else { return }
                if let id { return self.osFocusReported(id, recheck: recheck) }
                // Cmd-Tab can land before the app has a focused window to report: ask once more shortly.
                if retry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.refreshOSFocus(recheck: recheck, retry: false) }
                    return
                }
                // Still none: the app is in front with no window of its own focused. If none of its windows
                // is on screen, go to where they are, like Cmd-Tab to an app on another macOS Space.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      Date().timeIntervalSince(self.windowLostAt) > 0.8 else { return }
                let mine = self.model.windows.values.filter { $0.info.pid == pid }
                guard !mine.contains(where: { $0.workspace.map(self.model.isVisible) ?? false }),
                      let target = mine.min(by: { $0.id < $1.id }) else { return }
                self.osFocusReported(target.id, recheck: true)
            }
        }
    }

    private func osFocusReported(_ id: WindowID, recheck: Bool = false) {
        if let p = pendingFocus {
            // We just asked for a different window; ignore stale reports until it lands.
            if p.id == id || Date() > p.until { pendingFocus = nil } else { return }
        }
        guard let w = model.windows[id] else { return }
        // Focus jumped to a window on a workspace that isn't shown. Right after a window closed, minimized or
        // its app hid, that's macOS picking a stand-in (often the same app's window elsewhere): stay put.
        // (Scratchpad windows count as not shown: macOS picking one after a close must not pop it out.)
        if id != model.focusedWindow?.id, !(w.workspace.map(model.isVisible) ?? false) {
            if Date().timeIntervalSince(windowLostAt) < 0.8 { return keepFocus() }
            // An app brought itself forward (notification click, Spotlight, a link) rather than the user
            // Cmd-Tabbing to it: with focus_on_window_activation none/urgent, stay on this workspace.
            if model.config.focusOnActivation != "focus", Date().timeIntervalSince(tap.lastAppSwitch) > 1.5 {
                if debug { log("focus: \(w.info.app) activated on workspace \(w.workspace?.name ?? "scratchpad"); staying (focus_on_window_activation)") }
                return keepFocus()
            }
            // Same app as the focused window: the close that caused it may not have been reported yet.
            if !recheck, let cur = model.focusedWindow, pids[cur.id] == pids[id] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refreshOSFocus(recheck: true) }
                return
            }
        }
        lastFocused = id
        if id != model.focusedWindow?.id {
            model.osFocused(id)
            scheduleApply()
        }
    }

    /// Takes keyboard focus back from a window macOS focused off-screen: to the workspace's own window, or to
    /// Panespace when the workspace is empty, so typing never lands in a window the user can't see.
    private func keepFocus() {
        if debug { log("focus: ignoring macOS's stand-in focus on another workspace") }
        if model.focusedWindow == nil {
            lastFocused = nil
            focusHolder.take(model.focusedMonitor.id)
        } else {
            lastFocused = nil  // apply() focuses the model's window again
            scheduleApply()
        }
    }

    private func mouseUp() {
        mouseUpPending = true
        // Give the window server a beat to settle the final frames, then read them off the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            let targets = dragged.keys.compactMap { id in elements[id].map { (id, $0) } }
            guard !targets.isEmpty else { return dragEnded([:]) }
            eventQueue.async { [weak self] in
                var frames: [WindowID: CGRect] = [:]
                for (id, el) in targets { frames[id] = el.frame }
                DispatchQueue.main.async { self?.dragEnded(frames) }
            }
        }
    }

    private func dragEnded(_ frames: [WindowID: CGRect]) {
        mouseUpPending = false
        liveResize = nil
        let cursor = CGEvent(source: nil)?.location
        for (id, resized) in dragged {
            guard let w = model.windows[id], let f = frames[id] else { continue }
            if w.isFloating {
                model.floatingWindowDropped(id, frame: f)
                continue
            }
            unsure.insert(id)
            if resized {
                model.userResized(id, from: seenFrame[id], to: f)
                seenFrame[id] = f
            } else if let c = cursor {
                model.userDropped(id, at: c)
            }
            lastApplied[id] = nil
            appliedSize[id] = nil
        }
        dragged.removeAll()
        refreshOSFocus()
        scheduleApply()
        startSync()  // anything deferred while the button was down
    }

    private func mouseMoved(_ p: CGPoint) {
        guard model.config.focusFollowsMouse, !tap.isMouseDown, Date().timeIntervalSince(lastMouseMove) > 0.05 else { return }
        lastMouseMove = Date()
        guard let w = model.window(at: p), w.id != model.focusedWindow?.id else { return }
        // Only between tiles: focusing raises the window, so hovering in and out of a floating window would
        // flip it above and below the tile under it. Floating windows take focus on click.
        if w.isFloating || model.focusedWindow?.isFloating == true { return }
        model.osFocused(w.id)
        apply(warp: false)
    }

    private var screensWork: DispatchWorkItem?

    /// Displays report several changes while one is plugged in or wakes: act once they've settled.
    private func screensChanged() {
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.screensSettled() }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func screensSettled() {
        model.setMonitors(Screens.read())
        Vsync.shared.displaysChanged()
        lastApplied.removeAll()
        appliedSize.removeAll()
        seenFrame.removeAll()
        // Hidden ones are hidden again on the new geometry. Ones whose workspace is shown now (it took the place of
        // one that went back to its display) stay marked, so they're brought out of the corner.
        hiddenByUs = hiddenByUs.filter { id in model.windows[id]?.workspace.map(model.isVisible) == true }
        instantNext = true
        shownOn.removeAll()
        requestSync(.all)
        scheduleApply()
    }

    // MARK: floating_modifier drags

    private struct ModDrag {
        let id: WindowID
        let el: AXUIElement
        let resize: Bool
        let floating: Bool
        let start: CGPoint
        let startFrame: CGRect
        /// Resize moves the edges nearest to where the drag started.
        let leftEdge: Bool
        let topEdge: Bool
    }

    private func modDragBegan(at p: CGPoint, resize: Bool) {
        border.hide()  // also keeps the AX hit test below from landing on our own overlay
        modDragGeneration += 1
        let generation = modDragGeneration
        // The AX hit test asks the app under the cursor, so it runs off the main thread. It must never reach our
        // own process (menu bar item), so only inside work areas.
        let inWorkArea = model.monitors.contains { $0.visibleFrame.contains(p) }
        eventQueue.async { [weak self] in
            let hit = inWorkArea ? WindowManager.axWindow(at: p) : nil
            DispatchQueue.main.async {
                guard let self, generation == self.modDragGeneration else { return }  // the drag already ended
                self.startModDrag(at: p, resize: resize, hit: hit)
            }
        }
    }

    private func startModDrag(at p: CGPoint, resize: Bool, hit: (id: WindowID, frame: CGRect?)?) {
        // Floating before tiled, as the user sees them, when the hit test found nothing of ours.
        let target = hit.flatMap { model.windows[$0.id] != nil ? $0 : nil } ?? model.window(at: p).map { (id: $0.id, frame: nil) }
        if debug { log("modDrag begin at \(p) resize=\(resize) → \(target.map { "\($0.id)" } ?? "no window")") }
        guard let (id, axFrame) = target, let w = model.windows[id], let el = elements[id],
              let frame = w.isFloating ? axFrame ?? w.floatingFrame : w.rect else { return }
        if id != model.focusedWindow?.id {
            model.osFocused(id)
            apply(warp: false)
        }
        modDrag = ModDrag(id: id, el: el, resize: resize, floating: w.isFloating, start: p, startFrame: frame,
                          leftEdge: p.x < frame.midX, topEdge: p.y < frame.midY)
        border.hide()
    }

    private func modDragMoved(to p: CGPoint) {
        guard let d = modDrag else { return }
        let (dx, dy) = (p.x - d.start.x, p.y - d.start.y)
        var f = d.startFrame
        guard d.resize else {
            let origin = CGPoint(x: f.minX + dx, y: f.minY + dy)
            axQueue.async { d.el.setPosition(origin) }
            return
        }
        let (minW, minH): (CGFloat, CGFloat) = (120, 80)
        if d.leftEdge {
            f.origin.x = min(f.minX + dx, f.maxX - minW)
            f.size.width = d.startFrame.maxX - f.minX
        } else {
            f.size.width = max(minW, f.width + dx)
        }
        if d.topEdge {
            f.origin.y = min(f.minY + dy, f.maxY - minH)
            f.size.height = d.startFrame.maxY - f.minY
        } else {
            f.size.height = max(minH, f.height + dy)
        }
        if d.floating {
            let frame = f
            axQueue.async { d.el.setFrame(frame) }
        } else {
            // Tiled: turn the dragged edges into split weights and re-layout live.
            model.userResized(d.id, to: f)
            liveApply()
        }
    }

    /// Re-tiles during a drag, at most one batch of writes in flight, so slow apps can't pile up a backlog.
    /// The window under the user's resize is left alone; writing to it would fight the drag.
    private func liveApply() {
        guard !liveApplyBusy else { return liveApplyAgain = true }
        liveApplyBusy = true
        apply(warp: false, leave: liveResize, animate: false)
        axQueue.async {
            DispatchQueue.main.async { [self] in
                liveApplyBusy = false
                let again = liveApplyAgain
                liveApplyAgain = false
                if again, tap.isMouseDown || mouseUpPending || modDrag != nil { liveApply() }  // else mouse-up applies
            }
        }
    }

    private func modDragEnded(at p: CGPoint) {
        modDragGeneration += 1
        // No window was grabbed (empty space, or let go before the hit test came back): still resume what the
        // press held back.
        guard let d = modDrag else { scheduleApply(); return startSync() }
        modDragMoved(to: p)
        modDrag = nil
        dragged.removeAll()  // our own frame writes during the drag aren't user drags
        if d.floating {
            axQueue.async { [weak self] in
                guard let f = d.el.frame else { return }
                DispatchQueue.main.async {
                    self?.model.floatingWindowDropped(d.id, frame: f)
                    self?.scheduleApply()
                }
            }
        } else if !d.resize {
            model.userDropped(d.id, at: p)  // swap with the window underneath, or snap back
            lastApplied[d.id] = nil
        }
        scheduleApply()
        startSync()
    }

    /// Topmost window under `p` and its frame, by AX hit test. Blocks on the app, so never on the main thread.
    private static func axWindow(at p: CGPoint) -> (id: WindowID, frame: CGRect?)? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              let hit, let win = hit.role == kAXWindowRole ? hit : hit.element(kAXWindowAttribute),
              let id = win.windowID else { return nil }
        return (id, win.frame)
    }

    // MARK: Window discovery

    private enum SyncScope {
        case apps(Set<pid_t>), all

        func union(_ o: SyncScope?) -> SyncScope {
            switch (self, o) {
            case (.all, _), (_, .all?): return .all
            case (.apps(let a), .apps(let b)?): return .apps(a.union(b))
            case (_, nil): return self
            }
        }

        func contains(_ pid: pid_t) -> Bool {
            if case .apps(let s) = self { return s.contains(pid) }
            return true
        }
    }

    private struct SyncResult {
        var seen: [WindowID: Seen] = [:]
        var minimized = Set<WindowID>()
        var hiddenPids = Set<pid_t>()
        var failedPids = Set<pid_t>()  // app didn't answer: keep its windows as they are
        var goneApps = Set<pid_t>()
        var server: [WindowID: Bool]?  // window → on screen; nil when the window server didn't answer
        var newTrackers: [pid_t: AppTracker] = [:]
        /// Background native tab → the selected tab of its group, shown in its place.
        var tabs: [WindowID: WindowID] = [:]
        /// New windows listed but not on screen yet → their app.
        var offscreen: [WindowID: pid_t] = [:]
    }

    private struct Seen {
        let el: AXUIElement
        let pid: pid_t
        let info: WindowInfo?  // nil for windows the model already knew when the scan started
        let kind: WindowKind
        var frame: CGRect? = nil  // new windows only, read here so the main thread never asks the app
    }

    func scheduleApply() {
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, holdApplyUntil.timeIntervalSinceNow)) { [self] in
            applyQueued = false
            if tap.isMouseDown || modDrag != nil || swipe != nil { return }  // never fight a drag or swipe; their end applies
            apply()
        }
    }

    private func requestSync(_ scope: SyncScope) {
        syncScope = scope.union(syncScope)
        startSync()
    }

    /// Enumerates windows of the apps in scope off the main thread (one thread per app), then diffs on main.
    private func startSync() {
        guard !syncInFlight, let scope = syncScope, !tap.isMouseDown, modDrag == nil else { return }
        syncScope = nil
        syncInFlight = true
        let me = getpid()
        let regular = { (a: NSRunningApplication) in
            a.activationPolicy == .regular && a.processIdentifier != me && !a.isTerminated
        }
        let candidates: [NSRunningApplication]
        var goneApps = Set<pid_t>()
        switch scope {
        case .all:
            candidates = NSWorkspace.shared.runningApplications.filter(regular)
            let live = Set(candidates.map(\.processIdentifier))
            for pid in Set(trackers.keys).union(pids.values) where !live.contains(pid) {
                trackers[pid] = nil
                goneApps.insert(pid)
            }
        case .apps(let set):
            candidates = set.compactMap { NSRunningApplication(processIdentifier: $0) }.filter(regular)
            for pid in set where !candidates.contains(where: { $0.processIdentifier == pid }) {
                trackers[pid] = nil
                goneApps.insert(pid)
            }
        }
        let existing = trackers
        let known = model.windows.mapValues(\.isFloating)
        // In a full-screen Space (or sliding to one) every desktop window is off screen: that says nothing.
        let offscreenMeansHidden = !spaces.activeIsFullscreen && Date() >= spaceSettleUntil
        let refcon = refcon
        let started = DispatchTime.now().uptimeNanoseconds
        syncQueue.async { [weak self] in
            // An empty snapshot means the window server isn't answering (e.g. after wake); don't drop everything.
            let server = windowServerSnapshot()
            let lock = NSLock()
            var result = SyncResult()
            result.goneApps = goneApps
            result.server = server.isEmpty ? nil : server.mapValues(\.onscreen)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                let app = candidates[i]
                let pid = app.processIdentifier
                if app.isHidden {
                    lock.withLock { _ = result.hiddenPids.insert(pid) }
                    return
                }
                guard let t = existing[pid] ?? AppTracker(app, refcon: refcon),
                      let windows = t.element.windowsIfAvailable else {
                    lock.withLock { _ = result.failedPids.insert(pid) }
                    return
                }
                let name = app.localizedName ?? ""
                let bundle = app.bundleIdentifier ?? ""
                var local: [WindowID: Seen] = [:]
                var localMinimized: [WindowID] = []
                var listed: [(el: AXUIElement, id: WindowID)] = []
                for w in windows {
                    guard let id = w.windowID, server.isEmpty || server[id] != nil else { continue }
                    if w.isMinimized || w.isFullScreen {  // full screen: on its own Space, outside the layout
                        localMinimized.append(id)
                        continue
                    }
                    listed.append((w, id))
                }
                // Native tabs (Finder, Terminal, Ghostty...): every tab is its own window, all sharing one
                // frame, and only the selected one is on screen. The others aren't windows to tile.
                var localTabs: [WindowID: WindowID] = [:]
                var localOffscreen: [WindowID] = []
                let offscreen = server.isEmpty ? [] : listed.filter { server[$0.id]?.onscreen == false }
                if !offscreen.isEmpty {
                    let shown = listed.filter { server[$0.id]?.onscreen == true }.compactMap { s in s.el.frame.map { (s.id, $0) } }
                    for (w, id) in offscreen {
                        if let f = w.frame, let sibling = shown.first(where: { sameFrame($0.1, f) }) {
                            localTabs[id] = sibling.0
                        } else if known[id] == nil {
                            localOffscreen.append(id)  // not shown yet (still opening), or a stray hidden window
                        } else if offscreenMeansHidden {
                            // Its app took it off screen but keeps it listed (closed to the tray, say): it's
                            // counted as missing, and after a few looks gives its tile back.
                            localOffscreen.append(id)
                        }
                    }
                }
                for (w, id) in listed {
                    if localTabs[id] != nil || localOffscreen.contains(id) { continue }
                    if let floating = known[id] {
                        local[id] = Seen(el: w, pid: pid, info: nil, kind: floating ? .float : .tile)
                        continue
                    }
                    let kind = classify(w, bundleID: bundle, layer: server[id]?.layer)
                    guard kind != .ignore else { continue }
                    t.watch(w, id: id, refcon: refcon)
                    local[id] = Seen(el: w, pid: pid, info: WindowInfo(app: name, bundleID: bundle, title: w.title, pid: pid),
                                     kind: kind, frame: w.frame)
                }
                lock.withLock {
                    result.seen.merge(local) { a, _ in a }
                    result.minimized.formUnion(localMinimized)
                    result.tabs.merge(localTabs) { a, _ in a }
                    for id in localOffscreen { result.offscreen[id] = pid }
                    if existing[pid] == nil { result.newTrackers[pid] = t }
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            DispatchQueue.main.async {
                guard let self else { return }
                self.stats.sync(ms)
                if self.debug {
                    log(String(format: "sync %@ %d windows in %.2f ms (off main), unanswered: %@", "\(scope)",
                               result.seen.count, ms, "\(result.failedPids)"))
                }
                self.finishSync(scope, result)
            }
        }
    }

    private func finishSync(_ scope: SyncScope, _ r: SyncResult) {
        syncInFlight = false
        let seen = r.seen
        for (pid, t) in r.newTrackers where trackers[pid] == nil { trackers[pid] = t }
        for id in seen.keys { missing[id] = nil }
        // The user picked another native tab: the newly selected one takes the old one's tile.
        for (old, new) in r.tabs where model.windows[old] != nil {
            if model.windows[new] == nil, let info = seen[new]?.info {
                model.replaceWindow(old, with: new, info: info)
                rulesRun[new] = rulesRun[old]  // the same window to the user: its rules already ran
                unsure.insert(new)
                if lastFocused == old { lastFocused = new }
            }
            forget(old)  // a tab dragged onto another window: that window already has its own tile
        }
        // Windows listed before they're shown: look once more shortly instead of waiting for the next sweep.
        let fresh = r.offscreen.filter { offscreenSeen.insert($0.key).inserted }
        if !fresh.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.requestSync(.apps(Set(fresh.values))) }
        }
        if let s = r.server { offscreenSeen = offscreenSeen.filter { s[$0] != nil } }
        for id in Array(model.windows.keys) where seen[id] == nil && r.tabs[id] == nil {
            guard let pid = pids[id], scope.contains(pid) || r.goneApps.contains(pid) else { continue }
            if r.failedPids.contains(pid) { continue }  // app didn't answer this time; nothing changed
            // Gone from its app's list and either unknown to the window server or still on screen
            // (playing its close animation): closed. Off screen means another Space: wait (below).
            let gone = r.goneApps.contains(pid) || r.server.map { $0[id] ?? true } ?? false
            if gone {
                // The window server still has it (closing, or the app answered with an empty list after a
                // lock or wake): remember its workspace for when it's listed again; dropped once the server
                // forgets the ID. Unknown to the server: really closed, nothing to remember (IDs get reused).
                if r.server?[id] != nil { park(id) }
                forget(id)
            } else if r.minimized.contains(id) || r.hiddenPids.contains(pid) {
                park(id)
                forget(id)
            } else {
                // Still exists but unlisted: a glitch or another macOS Space. Give it a few syncs.
                missing[id, default: 0] += 1
                if missing[id]! >= 3 {
                    park(id)
                    forget(id)
                }
            }
        }
        if let s = r.server { for id in parked.keys where s[id] == nil { parked[id] = nil } }

        // Restored windows keep their saved order; new ones follow by ID.
        var saved: [WindowID: (Int, Session.Entry)] = [:]
        if let s = restoring {
            for (i, e) in s.windows.enumerated() { saved[e.id] = (i, e) }
        }
        var added: [WindowID] = []
        let focusBefore = model.focusedWindow?.id
        let order = seen.keys.sorted { (saved[$0]?.0 ?? Int.max, $0) < (saved[$1]?.0 ?? Int.max, $1) }
        for id in order {
            let s = seen[id]!
            elements[id] = s.el
            pids[id] = s.pid
            guard model.windows[id] == nil, let info = s.info, !nativeFullscreen.contains(id) else { continue }
            // Born covering a whole display, menu bar and all, with no title: an app's own full-screen window
            // (WebKit puts a fullscreen video in one, then takes it into macOS full screen). Tiling it would break
            // that, so leave it alone; if it ever shrinks to a normal window, a later scan picks it up.
            if let f = s.frame, coversDisplay(f) {
                if fullscreenSkipped.insert(id).inserted { log("full screen: leaving \(info.app)'s full-screen window alone") }
                continue
            }
            if let p = parked.removeValue(forKey: id), Date() < p.until {
                model.addWindow(id, info: info, floating: p.floating, frame: nil, workspaceName: p.workspace,
                                near: p.spot?.neighbor, before: p.spot?.before ?? false)
                if let f = p.frame { model.restoreFloatingFrame(id, f) }
                markRulesRun(id)  // back from minimized or hidden: its rules ran when it first appeared
                continue
            }
            if let e = saved[id]?.1, e.bundle == info.bundleID {
                model.addWindow(id, info: info, floating: e.floating, frame: nil,
                                workspaceName: e.workspace ?? model.focusedWorkspace.name)
                if e.workspace == nil { model.run("move scratchpad", on: id) }
                markRulesRun(id)  // rules already ran in the previous session
                continue
            }
            model.addWindow(id, info: info, floating: s.kind == .float, frame: s.frame, useMonitorOfFrame: startup)
            added.append(id)
            unsure.insert(id)  // it glides in from wherever the app opened it
        }
        if startup, case .all = scope {
            startup = false
            lastFocused = nil
            if let s = restoring { model.restoreFocus(workspace: s.focused) }
            restoring = nil
        }
        for id in added { runRules(id) }
        // A new floating window doesn't take the keyboard by itself: an autocomplete list or a tool panel
        // would steal it from the editor. If macOS really focused it, refreshOSFocus (below) follows.
        if !added.isEmpty, let before = focusBefore, model.windows[before] != nil,
           let now = model.focusedWindow, added.contains(now.id), now.isFloating {
            model.osFocused(before)
        }
        for id in fullscreenOnReturn where model.windows[id] != nil {
            fullscreenOnReturn.remove(id)
            model.osFocused(id)
            model.run("fullscreen enable", on: id)
        }
        if !added.isEmpty { refreshOSFocus() }
        scheduleApply()
        startSync()
    }

    /// A window that comes back (restored session, unminimized, unhidden) already had its rules: a later title
    /// change must not run them again (a `move to workspace` rule would yank it back from where the user put it).
    private func markRulesRun(_ id: WindowID) {
        guard let w = model.windows[id] else { return }
        rulesRun[id, default: []].formUnion(model.config.rules.indices.filter { model.config.rules[$0].criteria.matches(w) })
    }

    /// Runs the `for_window` rules that match the window and haven't run for it yet.
    private func runRules(_ id: WindowID) {
        for (i, rule) in model.config.rules.enumerated() where !(rulesRun[id]?.contains(i) ?? false) {
            guard let w = model.windows[id], rule.criteria.matches(w) else { continue }
            rulesRun[id, default: []].insert(i)
            perform(model.run(rule.command, on: id).effects)
        }
        scheduleApply()
    }

    private func park(_ id: WindowID, for seconds: TimeInterval = .infinity) {
        guard let w = model.windows[id], let ws = w.workspace else { return }
        parked[id] = (ws.name, w.isFloating, w.isFloating ? w.floatingFrame : nil, model.tileSpot(id),
                      Date().addingTimeInterval(seconds))
        windowLostAt = Date()
    }

    private func forget(_ id: WindowID) {
        model.removeWindow(id)
        if let pid = pids[id] { trackers[pid]?.unwatch(id) }
        elements[id] = nil
        pids[id] = nil
        hiddenByUs.remove(id)
        lastApplied[id] = nil
        appliedSize[id] = nil
        reappliedAt[id] = nil
        fights[id] = nil
        rulesRun[id] = nil
        missing[id] = nil
        dragged[id] = nil
        seenFrame[id] = nil
        animating.remove(id)
        appFullscreen[id] = nil
        settling[id] = nil
        unsure.remove(id)
        liveFrames[id] = nil
        if liveResize == id { liveResize = nil }
        if lastFocused == id { lastFocused = nil }
    }

    // MARK: Apply

    private enum Action {
        /// `from` = the frame we last gave it, to order the writes so its edges never overshoot.
        case frame(CGRect, positionOnly: Bool, from: CGRect?)
        case center(in: CGRect)
        case hide(MonitorID, knownWidth: CGFloat?, readFrame: Bool)
    }

    private struct Job {
        let id: WindowID
        let el: AXUIElement
        let action: Action
    }

    /// Makes the real windows match the model. Bookkeeping happens here on main; the AX writes and the
    /// focus change are queued in order on `axQueue`, so the main thread never waits for an app.
    /// Animated layouts glide (`Animator`); `animate: false` (live drags) and display changes jump.
    private func apply(warp: Bool = true, leave: WindowID? = nil, animate: Bool = true) {
        let placements = model.placements()
        let fallback = model.focusedMonitor.visibleFrame
        let animated = animate && leave == nil && model.config.animations && model.config.animationDuration > 0
            && !startup && !instantNext && modDrag == nil && !tap.isMouseDown
        instantNext = false
        let slides = workspaceSlides(animated: animated)
        /// Where a window that stays on screen starts its glide.
        func origin(_ id: WindowID) -> Start {
            if animating.contains(id) { return .live(lastApplied[id]) }
            if let last = lastApplied[id], !unsure.contains(id) { return .at(last) }
            return .current
        }
        var show: [pid_t: [Job]] = [:]
        var hide: [pid_t: [Job]] = [:]
        /// Still sliding out from the animation in flight: parked by this layout if it replaces that animation.
        var leaving: [pid_t: [Job]] = [:]
        var moves: [Move] = []
        // In flight already and still headed the same way: only moved again if this layout restarts the animation.
        var carried: [Move] = []
        for (id, p) in placements {
            guard let el = elements[id], let pid = pids[id], let w = model.windows[id] else { continue }
            let wasHidden = hiddenByUs.contains(id)
            switch p {
            case .tiled(let r):
                if id == leave { continue }
                if let f = appFullscreen[id] {
                    // Its app's own full screen: leave it, but bring it back if its workspace was hidden meanwhile.
                    if wasHidden {
                        show[pid, default: []].append(Job(id: id, el: el, action: .frame(f, positionOnly: false, from: nil)))
                        hiddenByUs.remove(id)
                    }
                    continue
                }
                let unchanged = lastApplied[id] == r && !wasHidden
                if unchanged && !animating.contains(id) { continue }
                if animated {
                    var m = Move(id: id, el: el, pid: pid, start: origin(id), to: r)
                    if wasHidden && animating.contains(id) {
                        m.start = .live(nil)  // a swipe already brought it on screen, moving with the fingers
                    } else if wasHidden {  // its workspace just came on screen: slide in, or just appear
                        let s = slides[w.workspace?.monitorID ?? 0]
                        m.start = .at(s.map { r.offsetBy(dx: $0.enter.dx, dy: $0.enter.dy) } ?? r)
                        // Parked at its tile's size: the first frame moves it straight from the corner. Only a
                        // size change needs putting it at the start first (3 AX calls before anything moves).
                        m.jump = appliedSize[id] != r.size
                    }
                    if unchanged { carried.append(m) } else { moves.append(m) }
                } else {
                    show[pid, default: []].append(Job(id: id, el: el, action: .frame(r, positionOnly: appliedSize[id] == r.size,
                                                                                      from: wasHidden ? nil : lastApplied[id])))
                }
                unsure.remove(id)
                lastApplied[id] = r
                appliedSize[id] = r.size
                hiddenByUs.remove(id)
            case .floating(let f, let dirty):
                let inFlight = animating.contains(id)
                if !dirty && !wasHidden && !inFlight { continue }
                if animated, !dirty, !wasHidden, let f, inFlight {
                    carried.append(Move(id: id, el: el, pid: pid, start: .live(nil), to: f))  // e.g. moved by a swipe
                    continue
                }
                if animated, wasHidden, let f, inFlight {
                    moves.append(Move(id: id, el: el, pid: pid, start: .live(nil), to: f))
                } else if animated, wasHidden, let f, let s = slides[w.workspace?.monitorID ?? 0] {
                    moves.append(Move(id: id, el: el, pid: pid, start: .at(f.offsetBy(dx: s.enter.dx, dy: s.enter.dy)), to: f,
                                      jump: appliedSize[id] != f.size))
                } else {
                    show[pid, default: []].append(Job(id: id, el: el, action: f.map { .frame($0, positionOnly: false, from: nil) } ?? .center(in: fallback)))
                }
                hiddenByUs.remove(id)
                model.clearDirty(id)
            case .hidden(let mid):
                if wasHidden {
                    // A swipe that didn't land here pulled it on screen: back where it waited, then parked.
                    if animated, animating.contains(id), let home = swipeHomes[id] {
                        moves.append(Move(id: id, el: el, pid: pid, start: .live(nil), to: home, park: mid,
                                          parkWidth: appliedSize[id]?.width))
                    } else if animating.contains(id) {
                        leaving[pid, default: []].append(Job(id: id, el: el, action: .hide(mid, knownWidth: appliedSize[id]?.width,
                                                                                          readFrame: false)))
                    }
                    continue
                }
                if animated, let s = slides[mid] {  // its workspace was switched away: slide out, then park
                    // A floating window's real frame is its home, unless it's mid-flight (still sliding in).
                    let inFlight = animating.contains(id)
                    var m = Move(id: id, el: el, pid: pid, start: w.isFloating && !inFlight ? .current : origin(id), by: s.exit)
                    if w.isFloating, inFlight { m.start = .live(w.floatingFrame) }
                    m.park = mid
                    m.parkWidth = appliedSize[id]?.width
                    m.readFrame = w.isFloating && !inFlight
                    moves.append(m)
                } else {
                    hide[pid, default: []].append(Job(id: id, el: el, action: .hide(mid, knownWidth: appliedSize[id]?.width,
                                                                                     readFrame: w.isFloating && !animating.contains(id))))
                }
                hiddenByUs.insert(id)
                lastApplied[id] = nil
            }
        }
        swipeHomes = [:]
        // Anything else to write replaces the running animation, so it has to carry that one's windows on;
        // otherwise the running animation is left to finish delivering them.
        // A finished swipe left windows where the fingers did: nothing else delivers them, so always restart.
        let restart = !moves.isEmpty || !show.isEmpty || !hide.isEmpty || swipeJustEnded
        swipeJustEnded = false
        if restart {
            moves += carried
            for (pid, jobs) in leaving { hide[pid, default: []] += jobs }
        }

        var focusJob: (pid: pid_t, id: WindowID, el: AXUIElement, gen: Int)?
        let mates = model.focusedWindow.map { model.tabMates($0.id).compactMap { elements[$0] } } ?? []
        // In a full-screen Space (a video, a game), focusing a desktop window would make macOS leave it: leave focus
        // to macOS there; it reports the right window when the user comes back. Only looked up when it matters.
        if let f = model.focusedWindow {
            if f.id != lastFocused, let el = elements[f.id], let pid = pids[f.id],
               userAsked || !Spaces.summary().activeIsFullscreen {
                focusHolder.release()
                lastFocused = f.id
                pendingFocus = (f.id, Date().addingTimeInterval(0.6))
                focusJob = (pid, f.id, el, focusGeneration.increment())
            }
        } else if lastFocused != nil || focusHolder.monitor != model.focusedMonitor.id,
                  userAsked || !Spaces.summary().activeIsFullscreen {
            // Empty workspace: take keyboard focus away from windows that are now parked off-screen, and bring the
            // menu bar to this display (also when moving from one empty display to another).
            lastFocused = nil
            _ = focusGeneration.increment()
            focusHolder.take(model.focusedMonitor.id)
        }

        if restart || focusJob != nil {
            let monitors = model.monitors
            let generation = focusGeneration
            let queue = axQueue
            // Where the shown windows are headed, to know when they've actually arrived.
            var arriving: [WindowID: CGPoint] = [:]
            if model.config.smoothLayout && !hide.isEmpty {
                for job in show.values.joined() {
                    if case .frame(let r, _, _) = job.action { arriving[job.id] = r.origin }
                }
            }
            let gen = restart ? animGeneration.increment() : animGeneration.value
            if restart { animating = Set(moves.map(\.id)) }
            let (duration, anims, store) = (model.config.animationDuration, animGeneration, liveFrames)
            let moving = moves.map(\.id)
            let debug = self.debug
            let queued = CACurrentMediaTime()
            let (askedAt, stats) = (commandAt, self.stats)
            axQueue.async { [weak self] in
                let waited = CACurrentMediaTime() - queued
                func focus() {
                    // Superseded (another focus, or a click) before it ran: a late focus would steal the keyboard.
                    guard let fj = focusJob, generation.value == fj.gen else { return }
                    for el in mates { el.perform(kAXRaiseAction) }  // the rest of its tab, under it
                    Focus.focus(pid: fj.pid, windowID: fj.id, element: fj.el) { generation.value == fj.gen }
                    // Tahoe sometimes leaves another app's window on top; raise once more unless focus moved on.
                    queue.asyncAfter(deadline: .now() + 0.12) {
                        if generation.value == fj.gen { fj.el.perform(kAXRaiseAction) }
                    }
                }
                // While gliding, focus alongside the first frames: keys go to the new window now, and the
                // animation doesn't wait for the focus change to start.
                if !moves.isEmpty { DispatchQueue.global(qos: .userInteractive).async(execute: focus) }
                var written = WindowManager.write(show, monitors: monitors)
                let shownAt = CACurrentMediaTime()
                // Park the old workspace only once the new one is really on screen; otherwise apps that are slow
                // to move (tens of ms) leave a frame of bare desktop in between: the "flicker".
                WindowManager.waitUntilShown(arriving, timeout: 0.08)
                written.floating += WindowManager.write(hide, monitors: monitors).floating
                if moves.isEmpty { focus() }
                let glide = Animator.run(moves, duration: duration, gen: gen, generation: anims, store: store, monitors: monitors)
                written.floating += glide.floating
                written.oversized += glide.oversized
                if let askedAt {  // a key or CLI command: how long until windows started moving
                    let first = !show.isEmpty ? shownAt : (glide.firstFrameAt ?? CACurrentMediaTime())
                    stats.latency((first - askedAt) * 1000)
                }
                if !moves.isEmpty { stats.animation(frames: glide.frames, seconds: glide.seconds, slowest: glide.slowest) }
                if debug, !moves.isEmpty {
                    log(String(format: "animated %d windows: queue %.1f ms, setup %.1f ms, %d frames, slowest %.1f ms",
                               moves.count, waited * 1000, glide.setup * 1000, glide.frames, glide.slowest * 1000))
                }
                DispatchQueue.main.async {
                    self?.afterWrite(written)
                    if !moving.isEmpty { self?.animationEnded(gen, moving) }
                }
            }
        }

        let m = model.focusedMonitor
        if warp, model.config.mouseWarping, let last = lastFocusedMonitor, last != m.id,
           let cursor = CGEvent(source: nil)?.location, !m.frame.contains(cursor) {
            let r = model.focusedWindow.map { $0.isFloating ? ($0.floatingFrame ?? $0.rect) : $0.rect } ?? m.visibleFrame
            CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        lastFocusedMonitor = m.id
        updateBorder()
        updateStatus()
    }

    /// The monitors whose workspace just changed, and which way their windows slide. Always records what
    /// each monitor shows, so the next switch knows where it came from.
    private func workspaceSlides(animated: Bool) -> [MonitorID: Motion.Slide] {
        var out: [MonitorID: Motion.Slide] = [:]
        let order = model.sortedWorkspaces.map(\.name)
        for ws in model.sortedWorkspaces where model.isVisible(ws) {
            let mid = ws.monitorID
            defer { shownOn[mid] = ws.name }
            guard animated, let before = shownOn[mid], before != ws.name, let mon = model.monitor(mid),
                  let slide = Motion.slide(on: mon, among: model.monitors,
                                           forward: Motion.isForward(from: before, to: ws.name, order: order)) else { continue }
            out[mid] = slide
        }
        return out
    }

    // MARK: Trackpad gestures

    /// Starts, restarts or stops listening to the trackpad to match the config.
    private func updateTrackpad(restart: Bool = false) {
        let c = model.config
        if !c.gestures || restart || trackpad?.fingers != c.gestureFingers {
            trackpad?.stop()
            trackpad = nil
        }
        guard c.gestures, trackpad == nil else { return }
        let t = Trackpad(fingers: c.gestureFingers) { [weak self] e in self?.trackpadEvent(e) }
        if t.start() {
            trackpad = t
            log("gestures: \(c.gestureFingers)-finger swipes on")
        } else {
            log("gestures: no trackpad found")
        }
    }

    /// On the touch thread. The live offset goes straight to the follow loop; the rest hops to main.
    private func trackpadEvent(_ e: SwipeRecognizer.Event) {
        switch e {
        case .horizontalBegan:
            swipeTrack.reset()
            DispatchQueue.main.async { self.swipeBegan() }
        case .horizontal(let travel):
            swipeTrack.move(travel)
        case .horizontalEnded(let travel, let velocity):
            swipeTrack.move(travel)
            DispatchQueue.main.async { self.swipeEnded(velocity: velocity) }
        case .up: DispatchQueue.main.async { self.zoomGesture(true) }
        case .down: DispatchQueue.main.async { self.zoomGesture(false) }
        }
    }

    /// Sideways swipe: the current workspace and its neighbours move with the fingers, like Spaces. With no
    /// room beside the display (another display there) or animations off, it just switches on lift.
    private func swipeBegan() {
        guard swipe == nil, modDrag == nil, !tap.isMouseDown, let mon = model.monitor(model.focusedWorkspace.monitorID) else { return }
        let ws: Workspace = model.focusedWorkspace
        let (prev, next) = (model.adjacentWorkspace(forward: false), model.adjacentWorkspace(forward: true))
        let width = Double(mon.frame.width)
        let gain = 1.8 * width  // about half the trackpad's width is a whole screen
        let (hasPrev, hasNext) = (prev != nil, next != nil)
        swipeTrack.setMap { travel in
            let x = travel * gain
            // Fingers right bring the previous workspace in, left the next; with nothing there, it resists.
            if (x > 0 && !hasPrev) || (x < 0 && !hasNext) { return Motion.rubberBand(x, dimension: width) }
            return max(-width, min(width, x))
        }
        let live = model.config.animations && model.config.animationDuration > 0
            && Motion.slide(on: mon, among: model.monitors, forward: true)?.enter.dy == 0
        var homes: [WindowID: CGRect] = [:]
        var followers: [Animator.Follower] = []
        if live {
            for w in ws.allWindows {
                guard let el = elements[w.id], let pid = pids[w.id],
                      let base = w.isFloating ? w.floatingFrame : (lastApplied[w.id] ?? w.rect) else { continue }
                followers.append(.init(id: w.id, el: el, pid: pid, base: base, resize: false))
            }
            for (side, other) in [(-width, prev), (width, next)] {
                guard let other else { continue }
                for (id, r) in model.frames(of: other, on: mon) {
                    guard let el = elements[id], let pid = pids[id] else { continue }
                    let base = r.offsetBy(dx: side, dy: 0)
                    homes[id] = base
                    followers.append(.init(id: id, el: el, pid: pid, base: base, resize: appliedSize[id] != r.size))
                }
            }
        }
        swipe = (mon, prev, next, homes)
        border.hide()
        guard !followers.isEmpty else { return }
        animating.formUnion(followers.map(\.id))
        let gen = animGeneration.increment()
        let (track, anims, store) = (swipeTrack, animGeneration, liveFrames)
        axQueue.async { Animator.follow(followers, track: track, gen: gen, generation: anims, store: store) }
    }

    /// Fingers lifted: switch if the swipe went far or fast enough, else spring back. Either way, every window
    /// carries on from where the fingers left it, at their speed.
    private func swipeEnded(velocity: Double) {
        guard let s = swipe else { return }
        swipe = nil
        let offset = swipeTrack.state.offset
        swipeTrack.finish()
        let width = Double(s.monitor.frame.width)
        let speed = velocity * 1.8  // screens per second, + = fingers moving right
        let target = offset < 0 ? s.next : (offset > 0 ? s.prev : nil)
        let toward = offset < 0 ? -speed : speed
        if let target, Motion.commits(progress: abs(offset) / width, velocity: toward) {
            model.run("workspace \"\(target.name.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        swipeHomes = s.homes
        swipeJustEnded = true
        apply()
    }

    /// Swipe up: zoom the focused window to the full screen; down: put it back.
    private func zoomGesture(_ up: Bool) {
        guard swipe == nil, let w = model.focusedWindow, !w.isFloating else { return }
        guard up != (w.workspace?.fullscreen === w) else { return }
        model.run("fullscreen toggle", on: w.id)
        scheduleApply()
    }

    /// The animation landed. Its windows' late move notifications are still ours for a moment.
    private func animationEnded(_ gen: Int, _ ids: [WindowID]) {
        guard gen == animGeneration.value else { return }  // a newer layout took these windows over
        animating.removeAll()
        let until = Date().addingTimeInterval(0.3)
        for id in ids { settling[id] = until }
        refreshCursor()
    }

    /// A window that moves under a still cursor never hears that the cursor is now over it, so it keeps a stale
    /// cursor: a game that hid it for play doesn't show it again in its menu (it got focus while still sliding
    /// in), a text view keeps an arrow, and so on. A zero-distance move of the real cursor makes the app under
    /// it update. Tagged, so focus-follows-mouse ignores it.
    private func refreshCursor() {
        guard let p = CGEvent(source: nil)?.location,
              let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: EventTap.cursorRefreshTag)
        e.post(tap: .cghidEventTap)
    }

    private struct Written {
        /// Floating windows' frames, read just before hiding them.
        var floating: [(WindowID, CGRect)] = []
        /// Windows that came out bigger than their tile: the app won't go smaller.
        var oversized: [(id: WindowID, actual: CGSize, wanted: CGSize)] = []
    }

    private func afterWrite(_ w: Written) {
        for (id, f) in w.floating where onScreen(f) { model.syncFloatingFrame(id, f) }
        guard !w.oversized.isEmpty else { return }
        // Look again shortly: an app that is merely slow to resize must not be mistaken for one with a minimum.
        let checks = w.oversized.compactMap { o in elements[o.id].map { (o, $0) } }
        eventQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let still = checks.compactMap { o, el in el.size.map { (o.id, $0, o.wanted) } }
            DispatchQueue.main.async {
                guard let self else { return }
                var relayout = false
                for (id, actual, wanted) in still where self.lastApplied[id]?.size == wanted
                    && self.model.noteMinimumSize(id, actual: actual, wanted: wanted) {
                    if self.debug { log("window \(id) won't go below \(actual) (asked \(wanted)); tiling around it") }
                    relayout = true
                }
                if relayout { self.scheduleApply() }
            }
        }
    }

    /// Runs on `axQueue`. One thread per app.
    private static func write(_ groups: [pid_t: [Job]], monitors: [Monitor]) -> Written {
        guard !groups.isEmpty else { return Written() }
        let list = Array(groups)
        let lock = NSLock()
        var out = Written()
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            let (pid, jobs) = list[i]
            let app = AXUIElement.app(pid)
            // Some apps animate frame changes while this is on (set by e.g. VoiceOver/Magnet).
            let enhanced = app.bool("AXEnhancedUserInterface") == true
            if enhanced { app.set("AXEnhancedUserInterface", false) }
            var local = Written()
            AXUIElementSetMessagingTimeout(app, 0.25)
            for job in jobs {
                // A hung app costs a quarter second, not the 1 s default per call (×4 per window).
                AXUIElementSetMessagingTimeout(job.el, 0.25)
                defer { AXUIElementSetMessagingTimeout(job.el, 0) }
                switch job.action {
                case .frame(let r, let positionOnly, let from):
                    if positionOnly {
                        job.el.setPosition(r.origin)
                        continue
                    }
                    if let f = from, sameMonitor(f, r, monitors) {
                        // Growing: move first, then grow into place. Shrinking: shrink first, then move.
                        // Either way the window never pokes past its final edges mid-change.
                        if r.width > f.width || r.height > f.height {
                            job.el.setPosition(r.origin)
                            job.el.setSize(r.size)
                        } else {
                            job.el.setSize(r.size)
                            job.el.setPosition(r.origin)
                        }
                    } else {
                        job.el.setFrame(r)  // new or crossing monitors: size → position → size
                    }
                    // Asked to get smaller: an app with a minimum size stops short and overlaps its neighbour.
                    // One read to find out, so the layout can make room.
                    if from.map({ r.width < $0.width - 0.5 || r.height < $0.height - 0.5 }) ?? true, let s = job.el.size,
                       s.width > r.width + 2 || s.height > r.height + 2 {
                        local.oversized.append((job.id, s, r.size))
                    }
                case .center(let v):
                    if let s = job.el.size {
                        job.el.setPosition(CGPoint(x: v.midX - s.width / 2, y: v.midY - s.height / 2))
                    }
                case .hide(let mid, let knownWidth, let readFrame):
                    if readFrame, let f = job.el.frame { local.floating.append((job.id, f)) }
                    job.el.setPosition(hidePoint(mid, monitors: monitors) {
                        let live = job.el.size
                        return CGSize(width: knownWidth ?? live?.width ?? 0, height: live?.height ?? 0)
                    })
                }
            }
            if enhanced { app.set("AXEnhancedUserInterface", true) }
            if !local.floating.isEmpty || !local.oversized.isEmpty {
                lock.withLock {
                    out.floating += local.floating
                    out.oversized += local.oversized
                }
            }
        }
        return out
    }

    /// Polls the window server (cheap, no app round trip) until every window is at its target origin.
    private static func waitUntilShown(_ targets: [WindowID: CGPoint], timeout: TimeInterval) {
        guard !targets.isEmpty else { return }
        var ptrs = targets.keys.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let ids = CFArrayCreate(nil, &ptrs, ptrs.count, nil) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return }
            let arrived = list.filter { d in
                guard let n = d[kCGWindowNumber as String] as? Int, let target = targets[WindowID(n)],
                      let b = d[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"] else { return false }
                return abs(x - target.x) < 2 && abs(y - target.y) < 2
            }
            if arrived.count >= targets.count { return }
            usleep(2_000)
        } while Date() < deadline
    }

    private func updateBorder() {
        let c = model.config
        guard c.borderWidth > 0, let f = model.focusedWindow, model.focusedWorkspace.fullscreen !== f,
              !tap.isMouseDown, modDrag == nil, let el = elements[f.id] else { return border.hide() }
        let (id, width, radius, color) = (f.id, c.borderWidth, c.borderRadius, c.borderColor)
        axQueue.async { [weak self] in  // after the queued moves, so we read the final frame
            let frame = el.frame
            DispatchQueue.main.async {
                guard let self, let frame, self.model.focusedWindow?.id == id else { return }
                self.border.show(around: frame, width: width, radius: radius, color: color)
            }
        }
    }

    func updateStatus() {
        statusBar.update(model: model, secureInput: secureInput, spacesWarning: spacesWarning)
    }

    // MARK: macOS Spaces

    private var spaces = Spaces.Summary()
    private var warnedAboutDesktops = false

    /// Why tiling can't see some windows right now, or nil.
    var spacesWarning: String? {
        var parts: [String] = []
        if spaces.extraDesktops > 0 {
            parts.append("You have \(spaces.extraDesktops + 1) macOS desktops. Windows on the other desktops can't be tiled. "
                         + "Close the extra ones in Mission Control: panespace workspaces (Caps+1…9) replace them.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func checkSpaces() {
        let s = Spaces.summary()
        if spaces.activeIsFullscreen, !s.activeIsFullscreen {
            // Back on the desktop from a full-screen Space: re-scan, and fix anything that drifted meanwhile.
            lastApplied.removeAll()
            appliedSize.removeAll()
            requestSync(.all)
            scheduleApply()
        }
        defer {
            if s != spaces {
                spaces = s
                updateStatus()
            }
        }
        // A window went into macOS full screen. Apps do that for videos and games, and that's theirs to keep:
        // set the window aside like a minimized one (the rest re-tile), and it comes back when it leaves.
        // Only a click on the green button just before becomes Panespace's zoom instead, so it stays tiled.
        let now = Set(s.fullscreenWindows.map(\.window))
        if now != nativeFullscreen {
            let left = !nativeFullscreen.subtracting(now).isEmpty
            nativeFullscreen = now
            if left { requestSync(.all) }  // back on the desktop: into the layout right away
        }
        for fs in s.fullscreenWindows where !pullingBack.contains(fs.window) {
            if model.config.interceptNativeFullscreen, let g = greenButton, g.id == fs.window, Date().timeIntervalSince(g.at) < 3 {
                greenButton = nil
                pullBack(fs)
            } else if model.windows[fs.window] != nil {
                park(fs.window)
                forget(fs.window)
                scheduleApply()
            }
        }
        if s.extraDesktops > 0, !warnedAboutDesktops {
            warnedAboutDesktops = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showDesktopsAlert() }
        }
    }

    private var pullingBack = Set<CGWindowID>()
    /// Windows that left macOS full screen and get panespace fullscreen as soon as they're back in the layout.
    private var fullscreenOnReturn = Set<CGWindowID>()

    private func pullBack(_ fs: Spaces.FullscreenWindow) {
        pullingBack.insert(fs.window)
        let cached = elements[fs.window]
        eventQueue.async { [weak self] in
            // A window on another Space usually isn't listed; the cached element or the app's own list may still work.
            func find() -> AXUIElement? {
                cached ?? AXUIElement.app(fs.pid).windowsIfAvailable?.first { $0.windowID == fs.window }
            }
            var el = find()
            if el == nil {
                // Not reachable from here: let macOS switch to it, then ask the app for its focused window.
                DispatchQueue.main.sync { _ = NSRunningApplication(processIdentifier: fs.pid)?.activate() }
                Thread.sleep(forTimeInterval: 0.8)
                el = AXUIElement.app(fs.pid).focusedWindow.flatMap { $0.windowID == fs.window ? $0 : nil } ?? find()
            }
            el?.set("AXFullScreen", false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {  // macOS's exit animation
                guard let self else { return }
                self.pullingBack.remove(fs.window)
                guard el != nil else { return log("couldn't bring window \(fs.window) out of macOS full screen") }
                self.fullscreenOnReturn.insert(fs.window)
                self.lastApplied[fs.window] = nil
                self.appliedSize[fs.window] = nil
                self.requestSync(.all)
            }
        }
    }

    private var alertPanel: AlertPanel?

    /// Not modal: a modal alert would block the main thread, and with it every shortcut.
    func showDesktopsAlert() {
        guard let text = spacesWarning, alertPanel == nil else { return }
        alertPanel = AlertPanel(
            title: "panespace works best with one desktop",
            text: text + "\n\nIn Mission Control, hover the row at the top and click × on the extra desktops. "
                + "Their windows move to the desktop you keep.",
            buttons: [
                ("Open Mission Control", {
                    Process.launchedProcess(launchPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control",
                                            arguments: [])
                }),
                ("Later", {}),
            ],
            onClose: { [weak self] in self?.alertPanel = nil })
    }
}

/// Two frames of the same native tab group (equal up to rounding).
func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

/// Where to park a window so ~1px stays on its monitor (macOS refuses fully off-screen frames).
/// The sliver goes on the screen's own edge, not the visible frame's, so a visible Dock covers it. Of the bottom
/// corners and, failing those, the side edges, picks the spot where the window spills least onto other displays
/// (3+ displays, or one below), then the one leaving the least of it on screen. `size` is read only when the
/// bottom-right corner has another display beside or below it.
func hidePoint(_ id: MonitorID, monitors: [Monitor], size: () -> CGSize) -> CGPoint {
    guard let m = monitors.first(where: { $0.id == id }) ?? monitors.first else { return .zero }
    let f = m.frame, top = m.visibleFrame.minY  // never above the menu bar: macOS pushes title bars below it
    let others = monitors.filter { $0.id != m.id }.map(\.frame)
    let bottomRight = CGPoint(x: f.maxX - 1, y: f.maxY - 1)
    // Nothing to the right of or below this screen: the corner is free whatever the window's size.
    let quadrant = CGRect(x: bottomRight.x, y: bottomRight.y, width: .greatestFiniteMagnitude / 4, height: .greatestFiniteMagnitude / 4)
    let rightBand = CGRect(x: f.maxX, y: f.minY - 1, width: .greatestFiniteMagnitude / 4, height: f.height + 2)
    if !others.contains(where: { $0.intersects(quadrant) || $0.intersects(rightBand) }) { return bottomRight }
    let s = size()
    func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    let spots = [
        bottomRight,
        CGPoint(x: f.minX + 1 - s.width, y: f.maxY - 1),
        CGPoint(x: f.maxX - 1, y: top),
        CGPoint(x: f.minX + 1 - s.width, y: top),
    ]
    func score(_ p: CGPoint) -> (CGFloat, CGFloat) {
        let r = CGRect(origin: p, size: s)
        return (others.reduce(0) { $0 + area($1.intersection(r)) }, area(f.intersection(r)))
    }
    return spots.min { score($0) < score($1) } ?? bottomRight
}

/// An NSAlert shown as a floating window instead of modally, so panespace keeps responding while it's up.
final class AlertPanel: NSObject {
    private let alert = NSAlert()
    private var actions: [() -> Void] = []
    private let onClose: () -> Void

    init(title: String, text: String, buttons: [(String, () -> Void)], onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        alert.messageText = title
        alert.informativeText = text
        for (i, (label, action)) in buttons.enumerated() {
            let b = alert.addButton(withTitle: label)
            b.tag = i
            b.target = self
            b.action = #selector(pressed(_:))
            actions.append(action)
        }
        alert.layout()
        alert.window.level = .floating
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func pressed(_ sender: NSButton) {
        alert.window.orderOut(nil)
        actions[sender.tag]()
        onClose()
    }
}

