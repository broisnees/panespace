import AppKit
import CoreText
import UniformTypeIdentifiers
import PanespaceCore

/// Menu bar indicator. Drawn as a template image so macOS tints it exactly like its own icons
/// (light/dark, Tahoe's translucent menu bar). Clicking opens a menu of workspaces and settings.
final class StatusBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var manager: WindowManager?
    private var renderedKey = ""

    func install(manager: WindowManager) {
        self.manager = manager
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
    }

    func update(model: Model, secureInput: Bool, spacesWarning: String?) {
        let slots = model.sortedWorkspaces.filter { !$0.isEmpty || model.isVisible($0) }.map { ws in
            WorkspaceIcon.Slot(label: WorkspaceIcon.label(ws.name),
                               style: ws === model.focusedWorkspace ? .focused : model.isVisible(ws) ? .visible : .occupied)
        }
        let mode = model.mode == "default" ? nil : model.mode
        let look = WorkspaceIcon.Look(rawValue: model.config.workspaceIndicator) ?? .number
        let warn = spacesWarning != nil
        let key = "\(slots)|\(mode ?? "")|\(secureInput)|\(look)|\(warn)"
        guard key != renderedKey, let button = item?.button else { return }  // re-render only on change
        renderedKey = key
        button.image = WorkspaceIcon.render(slots: slots, mode: mode, secureInput: secureInput, warning: warn, look: look)
        let focused = model.focusedWorkspace.name
        button.setAccessibilityLabel("Panespace, workspace \(focused)" + (mode.map { ", \($0) mode" } ?? ""))
        button.toolTip = spacesWarning
            ?? (secureInput ? "Secure Input is on (a password field is focused), so macOS is withholding keystrokes from Panespace."
                            : "Panespace — workspace \(focused)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let manager else { return }
        let model = manager.model
        if let warning = manager.spacesWarning {
            let i = menuItem("Some Windows Can't Be Tiled…", #selector(showSpacesHelp), symbol: "exclamationmark.triangle")
            i.toolTip = warning
            menu.addItem(i)
        }
        if !manager.configWarnings.isEmpty {
            let n = manager.configWarnings.count
            menu.addItem(menuItem("\(n) Config Warning\(n == 1 ? "" : "s")…", #selector(showWarnings),
                                  symbol: "exclamationmark.triangle"))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        menu.addItem(header("Workspaces"))
        for ws in model.sortedWorkspaces where !ws.isEmpty || model.isVisible(ws) {
            menu.addItem(workspaceItem(ws, model))
        }

        // The focused window's actions. Only number keys are bound by default, so this is how to reach them.
        if let w = model.focusedWindow, let ws = w.workspace {
            menu.addItem(.separator())
            menu.addItem(header("Window"))
            menu.addItem(commandItem(w.isFloating ? "Tile Window" : "Float Window", "floating toggle",
                                     symbol: w.isFloating ? "rectangle.split.2x1" : "macwindow.on.rectangle"))
            let fs = commandItem("Fullscreen", "fullscreen toggle", symbol: "arrow.up.left.and.arrow.down.right")
            fs.state = ws.fullscreen === w ? .on : .off
            menu.addItem(fs)
            if !w.isFloating, let parent = w.parent {
                menu.addItem(layoutItem(current: parent.layout))
                if ws.root.windows.count > 1 {
                    menu.addItem(commandItem("Balance Sizes", "balance", symbol: "equal.square"))
                }
            }
        }
        menu.addItem(.separator())

        // Quick controls: the things worth reaching without remembering a key.
        menu.addItem(header("Quick Controls"))
        menu.addItem(commandItem("Find Window…", "switcher", symbol: "magnifyingglass"))
        menu.addItem(commandItem("Previous Workspace", "workspace prev", symbol: "chevron.left"))
        menu.addItem(commandItem("Next Workspace", "workspace next", symbol: "chevron.right"))
        menu.addItem(commandItem("Last Workspace", "workspace back_and_forth", symbol: "arrow.uturn.backward"))
        if model.monitors.count > 1 {
            menu.addItem(commandItem("Focus Other Display", "focus output next", symbol: "display.2"))
            if model.focusedWindow != nil {
                menu.addItem(commandItem("Send Window to Other Display", "move container to output next",
                                         symbol: "rectangle.portrait.and.arrow.right"))
            }
            menu.addItem(commandItem("Send Workspace to Other Display", "move workspace to output next",
                                     symbol: "rectangle.portrait.on.rectangle.portrait"))
        }
        if model.focusedWindow != nil {
            menu.addItem(commandItem("Close Window", "kill", symbol: "xmark.square"))
        }
        menu.addItem(.separator())

        let immersive = menuItem("Immersive Mode", #selector(toggleImmersive), shortcut: "immersive toggle",
                                 symbol: "rectangle.inset.filled")
        immersive.state = manager.chrome.isImmersive ? .on : .off
        immersive.toolTip = "Auto-hide the menu bar so windows use the whole screen (the Dock follows its macOS setting)"
        menu.addItem(immersive)
        menu.addItem(settingsItem(manager))
        menu.addItem(.separator())
        menu.addItem(menuItem("About Panespace", #selector(about), symbol: "info.circle"))
        menu.addItem(menuItem("Quit Panespace", #selector(quit), shortcut: "exit", symbol: "power"))
    }

    /// `[1] Deck, Ghostty  ⌥1`: the workspace's badge, its apps, and the key that switches to it.
    private func workspaceItem(_ ws: Workspace, _ model: Model) -> NSMenuItem {
        var apps: [String] = []
        for w in ws.allWindows where !apps.contains(w.info.app) { apps.append(w.info.app) }
        let focused = ws === model.focusedWorkspace
        let item = menuItem(ws.name, #selector(switchWorkspace(_:)),
                            shortcut: ["workspace number \(ws.name)", "workspace \(ws.name)", "workspace \"\(ws.name)\""])
        item.representedObject = ws.name
        item.state = focused ? .on : .off
        item.image = WorkspaceIcon.menuBadge(ws.name, filled: focused, look: WorkspaceIcon.Look(rawValue: model.config.workspaceIndicator) ?? .number)

        let font = NSFont.menuFont(ofSize: 0)
        let primary: [NSAttributedString.Key: Any] = [.font: font]
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let title = NSMutableAttributedString()
        if ws.number == nil { title.append(NSAttributedString(string: ws.name + "  ", attributes: primary)) }
        if apps.isEmpty {
            title.append(NSAttributedString(string: "Empty", attributes: secondary))
        } else {
            let shown = apps.prefix(3).joined(separator: ", ")
            title.append(NSAttributedString(string: shown, attributes: ws.number == nil ? secondary : primary))
            if apps.count > 3 { title.append(NSAttributedString(string: " +\(apps.count - 3)", attributes: secondary)) }
        }
        if model.monitors.count > 1, let m = model.monitor(ws.monitorID) {
            title.append(NSAttributedString(string: "  ·  \(m.name)", attributes: secondary))
        }
        item.attributedTitle = title
        item.toolTip = apps.isEmpty ? nil : apps.joined(separator: ", ")
        return item
    }

    private static let layouts: [(layout: Layout, label: String, symbol: String)] = [
        (.splitH, "Side by Side", "rectangle.split.2x1"), (.splitV, "Top and Bottom", "rectangle.split.1x2"),
        (.tabbed, "Tabbed", "squares.below.rectangle"), (.stacking, "Stacked", "rectangle.stack"),
    ]

    private func layoutItem(current: Layout) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for l in StatusBar.layouts {
            let i = commandItem(l.label, "layout \(l.layout.rawValue)", symbol: l.symbol)
            i.state = l.layout == current ? .on : .off
            sub.addItem(i)
        }
        let item = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        item.image = symbol(StatusBar.layouts.first { $0.layout == current }?.symbol ?? "rectangle.split.2x1")
        item.submenu = sub
        return item
    }

    private func settingsItem(_ manager: WindowManager) -> NSMenuItem {
        let model = manager.model
        let sub = NSMenu()
        sub.autoenablesItems = false
        let ffm = menuItem("Focus Follows Mouse", #selector(toggleFocusFollowsMouse))
        ffm.state = model.config.focusFollowsMouse ? .on : .off
        sub.addItem(ffm)
        let anim = menuItem("Animations", #selector(toggleAnimations))
        anim.state = model.config.animations ? .on : .off
        sub.addItem(anim)
        let login = menuItem("Open at Login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        sub.addItem(login)
        sub.addItem(.separator())
        sub.addItem(choices("Modifier Key", key: "set $mod", current: configValue("set $mod"), StatusBar.modifiers))
        sub.addItem(choices("Menu Bar Indicator", key: "workspace_indicator", current: model.config.workspaceIndicator,
                            StatusBar.indicators))
        sub.addItem(.separator())
        sub.addItem(menuItem("Edit Config…", #selector(editConfig)))
        sub.addItem(menuItem("Reload Config", #selector(reload), shortcut: "reload"))
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.image = symbol("gearshape")
        item.submenu = sub
        return item
    }

    private static let modifiers: [(value: String, label: String)] = [
        ("alt", "Option ⌥"), ("ctrl+alt", "Control + Option ⌃⌥"), ("cmd", "Command ⌘"),
        ("caps", "Caps Lock ⇪"), ("hyper", "Hyper ⌃⌥⇧⌘"),
    ]
    private static let indicators: [(value: String, label: String)] = [
        ("number", "Number"), ("pill", "Pill"), ("panes", "Panes + Number"), ("circle", "Circle"), ("minimal", "Minimal"),
        ("segmented", "All Workspaces: Segmented"), ("dots", "All Workspaces: Dots"), ("tiles", "All Workspaces: Tiles"),
    ]

    /// A submenu of values for one config setting; picking one writes it to the config and reloads.
    private func choices(_ title: String, key: String, current: String?, _ options: [(value: String, label: String)]) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for o in options {
            let i = NSMenuItem(title: o.label, action: #selector(pickSetting(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [key, o.value]
            i.state = o.value == current?.lowercased() ? .on : .off
            sub.addItem(i)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Runs a Panespace command, showing the user's binding for it (if any) as the shortcut.
    private func commandItem(_ title: String, _ command: String, symbol name: String) -> NSMenuItem {
        let i = menuItem(title, #selector(runCommand(_:)), shortcut: command, symbol: name)
        i.representedObject = command
        return i
    }

    private func configValue(_ key: String) -> String? {
        guard let url = manager?.configURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Config.value(of: key, in: text)
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func menuItem(_ title: String, _ action: Selector, shortcut command: String? = nil, symbol name: String? = nil) -> NSMenuItem {
        menuItem(title, action, shortcut: command.map { [$0] } ?? [], symbol: name)
    }

    /// Shows the user's actual binding for any of `commands` (from the config) as the item's shortcut hint.
    private func menuItem(_ title: String, _ action: Selector, shortcut commands: [String], symbol name: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let name { i.image = symbol(name) }
        if let combo = manager?.model.config.modes["default"]?.first(where: { commands.contains($0.value) })?.key,
           let name = combo.keyName, name.count == 1, !combo.modifiers.contains(.caps) {
            i.keyEquivalent = name
            var m: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.control) { m.insert(.control) }
            if combo.modifiers.contains(.option) { m.insert(.option) }
            if combo.modifiers.contains(.shift) { m.insert(.shift) }
            if combo.modifiers.contains(.command) { m.insert(.command) }
            i.keyEquivalentModifierMask = m
        }
        return i
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        manager?.runCommand("workspace \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"")
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        manager?.runCommand(command)
    }

    @objc private func showSpacesHelp() { manager?.showDesktopsAlert() }

    @objc private func toggleImmersive() { manager?.runCommand("immersive toggle") }
    @objc private func reload() { manager?.reload() }

    /// Code editors, in order of preference. TextEdit is the last resort: its smart quotes turn `"` into `”`,
    /// which breaks lines like `mode "resize"`.
    private static let editors = [
        "dev.zed.Zed", "com.todesktop.230313mzl4w4u92" /* Cursor */, "com.microsoft.VSCode", "com.exafunction.windsurf",
        "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit", "com.coteditor.CotEditor",
    ]

    @objc private func editConfig() {
        guard let url = manager?.configURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? DefaultConfig.text.write(to: url, atomically: false, encoding: .utf8)
        }
        let ws = NSWorkspace.shared
        let editor = StatusBar.editors.lazy.compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
            ?? ws.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        ws.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.alert("Couldn't open the config", error.localizedDescription) }
        }
    }

    @objc private func showWarnings() {
        alert("Panespace config warnings", manager?.configWarnings.joined(separator: "\n") ?? "")
    }

    @objc private func pickSetting(_ sender: NSMenuItem) {
        guard let kv = sender.representedObject as? [String], kv.count == 2 else { return }
        writeSetting(kv[0], kv[1])
    }

    @objc private func toggleFocusFollowsMouse() {
        writeSetting("focus_follows_mouse", manager?.model.config.focusFollowsMouse == true ? "no" : "yes")
    }

    @objc private func toggleAnimations() {
        writeSetting("animations", manager?.model.config.animations == true ? "no" : "yes")
    }

    @objc private func toggleLogin() {
        do { try LoginItem.set(!LoginItem.isEnabled) } catch { alert("Couldn't change Open at Login", error.localizedDescription) }
    }

    @objc private func about() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let repo = "https://github.com/broisnischal/panespace"
        let credits = NSAttributedString(string: "github.com/broisnischal/panespace", attributes: [
            .link: URL(string: repo)!, .paragraphStyle: center, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { manager?.shutdown() }

    /// Writes one setting into the config and reloads: a menu choice acts like editing the file + reload.
    /// Not an atomic write, so a config that is a symlink into a dotfiles repo stays a symlink.
    private func writeSetting(_ key: String, _ value: String) {
        guard let manager else { return }
        let url = manager.configURL
        do {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? DefaultConfig.text
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Config.setting(key, to: value, in: text).write(to: url, atomically: false, encoding: .utf8)
            manager.reload()
        } catch {
            alert("Couldn't save the config", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Renders the workspace indicator as a template image (macOS tints it like its own icons).
/// Current workspace only:
///   number (default)  a solid rounded square, the number cut out
///   pill              a solid capsule, the number cut out
///   panes             Panespace's three-pane mark, then the number
///   circle            a solid circle, the number cut out
///   minimal           just the number, underlined
/// Every workspace:
///   segmented         one capsule control; the focused workspace is a solid pill, number cut out
///   dots              focused workspace as a numbered pill, the others as small dots (Omarchy-like)
///   tiles             focused workspace as a solid tile, others as plain numbers
/// A workspace shown on another display gets an outline instead of a fill.
enum WorkspaceIcon {
    enum Style { case focused, visible, occupied }
    enum Look: String, CaseIterable { case number, pill, panes, circle, minimal, segmented, dots, tiles }
    /// Looks that show only the current workspace.
    static let single: Set<Look> = [.number, .pill, .panes, .circle, .minimal]

    struct Slot: CustomStringConvertible {
        let label: String
        let style: Style
        var description: String { "\(label):\(style)" }
    }

    static let height: CGFloat = 18

    /// Long names are shortened so the menu bar stays tidy.
    static func label(_ name: String) -> String { name.count > 10 ? String(name.prefix(9)) + "…" : name }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let desc = (base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor).addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// The workspace's badge in the menu, drawn like the menu bar indicator: solid for the current one,
    /// outlined for the rest. Named workspaces show their first letter.
    static func menuBadge(_ name: String, filled: Bool, look: Look) -> NSImage {
        let label = Int(name) != nil ? name : String(name.prefix(1)).uppercased()
        let shape: Look = look == .pill || look == .circle ? look : .number
        let image = NSImage(size: badgeSize(label, shape, height: 15), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            drawBadge(label, shape, filled: filled, in: r, cg)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Workspace \(name)"
        return image
    }

    private static func badgeFont(_ look: Look, _ h: CGFloat) -> NSFont {
        switch look {
        case .minimal: return font(h * 0.94, .heavy)
        case .panes: return font(h * 0.84, .semibold)
        case .circle: return font(h * 0.64, .bold)
        default: return font(h * 0.72, .bold)
        }
    }

    private static func badgeSize(_ label: String, _ look: Look, height h: CGFloat) -> NSSize {
        let w = textWidth(label, badgeFont(look, h))
        switch look {
        case .pill: return NSSize(width: max(h * 1.6, w + h * 0.95), height: h)
        case .panes: return NSSize(width: h * 0.95 + 4 + w, height: h)
        case .minimal: return NSSize(width: w + 3, height: h)
        default: return NSSize(width: max(h, w + h * 0.55), height: h)
        }
    }

    /// One badge. `filled`: a solid shape with the number cut out; otherwise an outline around the number.
    private static func drawBadge(_ label: String, _ look: Look, filled: Bool, in r: NSRect, _ cg: CGContext) {
        let f = badgeFont(look, r.height)
        NSColor.black.set()
        switch look {
        case .circle:
            let d = r.height
            let bounds = NSRect(x: r.midX - max(d, r.width) / 2, y: r.minY, width: max(d, r.width), height: d)
            let disc = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: d / 2 - 0.8, yRadius: d / 2 - 0.8)
            if filled { disc.fill(); knockOut(label, f, in: r, cg) } else { disc.lineWidth = 1.6; disc.stroke(); draw(label, f, in: r, alpha: 1) }
        case .panes:
            // The app icon's layout: a main pane beside a stack of two, the main one lit.
            let g = NSRect(x: r.minX, y: r.minY + r.height * 0.06, width: r.height * 0.95, height: r.height * 0.88)
            let gap = max(1.3, g.width * 0.11), radius = g.height * 0.17
            let main = NSRect(x: g.minX, y: g.minY, width: (g.width - gap) * 0.54, height: g.height)
            let rx = main.maxX + gap, half = (g.height - gap) / 2
            NSBezierPath(roundedRect: main, xRadius: radius, yRadius: radius).fill()
            NSColor.black.withAlphaComponent(0.42).setFill()
            for y in [g.minY, g.minY + half + gap] {
                NSBezierPath(roundedRect: NSRect(x: rx, y: y, width: g.maxX - rx, height: half), xRadius: radius, yRadius: radius).fill()
            }
            draw(label, f, in: NSRect(x: g.maxX + 4, y: r.minY, width: r.maxX - g.maxX - 4, height: r.height), alpha: 1)
        case .minimal:
            let bar = max(2, r.height * 0.13)
            draw(label, f, in: NSRect(x: r.minX, y: r.minY + bar + 1, width: r.width, height: r.height - bar - 1), alpha: 1)
            NSBezierPath(roundedRect: NSRect(x: r.minX + 1, y: r.minY, width: r.width - 2, height: bar), xRadius: bar / 2, yRadius: bar / 2).fill()
        default:  // number, pill
            let radius = look == .pill ? r.height / 2 : r.height * 0.3
            if filled {
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
                knockOut(label, f, in: r, cg)
            } else {
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.65, dy: 0.65), xRadius: radius - 0.65, yRadius: radius - 0.65)
                outline.lineWidth = 1.3
                outline.stroke()
                draw(label, f, in: r, alpha: 1)
            }
        }
    }

    private static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// The current workspace only, in one of the single looks, after any Secure Input / warning badge and
    /// binding-mode pill.
    private static func renderCurrent(_ label: String, _ look: Look, mode: String?, secureInput: Bool, warning: Bool) -> NSImage {
        let h = height
        let modeFont = font(9.5, .bold)
        let size = badgeSize(label, look, height: 16)
        var x: CGFloat = 0
        var lockRect: NSRect?
        if secureInput || warning {
            lockRect = NSRect(x: 0, y: (h - 14) / 2, width: 14, height: 14)
            x += 19
        }
        var modeRect: NSRect?
        let modeText = mode?.uppercased()
        if let modeText {
            let w = textWidth(modeText, modeFont) + 14
            modeRect = NSRect(x: x, y: (h - 16) / 2, width: w, height: 16)
            x += w + 5
        }
        let symbol = warning ? "exclamationmark.triangle.fill" : "lock.fill"
        let badge = NSRect(x: x, y: (h - size.height) / 2, width: size.width, height: size.height)
        let image = NSImage(size: NSSize(width: badge.maxX, height: h), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.set()
            if let r = lockRect, let lock = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold)) {
                let s = lock.size
                lock.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            if let r = modeRect, let modeText {
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
                knockOut(modeText, modeFont, in: r, cg)
            }
            drawBadge(label, look, filled: true, in: badge, cg)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func render(slots: [Slot], mode: String?, secureInput: Bool, warning: Bool = false, look: Look = .number) -> NSImage {
        if single.contains(look) {
            return renderCurrent(slots.first { $0.style == .focused }?.label ?? "", look, mode: mode, secureInput: secureInput,
                                 warning: warning)
        }
        let h = height
        let numberFont = font(12, .semibold)
        let modeFont = font(9.5, .bold)

        // Leading accessories: Secure Input lock, binding mode pill.
        var x: CGFloat = 0
        var lockRect: NSRect?
        if secureInput {
            lockRect = NSRect(x: x, y: 2, width: 12, height: 14)
            x += 12 + 5
        }
        var modeRect: NSRect?
        let modeText = mode?.uppercased()
        if let modeText {
            let w = textWidth(modeText, modeFont) + 14
            modeRect = NSRect(x: x, y: 1, width: w, height: h - 2)
            x += w + 5
        }

        // Workspace segments.
        var rects: [NSRect] = []
        switch look {
        case .number, .pill, .panes, .circle, .minimal: break  // single looks: renderCurrent
        case .segmented:
            for s in slots {
                let w = max(22, textWidth(s.label, numberFont) + 14)
                rects.append(NSRect(x: x, y: 0, width: w, height: h))
                x += w
            }
        case .dots:
            for s in slots {
                let w = s.style == .focused ? max(24, textWidth(s.label, numberFont) + 14) : 10
                rects.append(NSRect(x: x, y: 0, width: w, height: h))
                x += w + 3
            }
            if !slots.isEmpty { x -= 3 }
        case .tiles:
            for s in slots {
                let w = max(18, textWidth(s.label, numberFont) + 10)
                rects.append(NSRect(x: x, y: 1, width: w, height: h - 2))
                x += w + 3
            }
            if !slots.isEmpty { x -= 3 }
        }
        let total = max(1, slots.isEmpty ? x - 5 : x)

        let image = NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            func fill(_ path: NSBezierPath, _ alpha: CGFloat) {
                NSColor.black.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            func capsule(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2) }

            if let r = lockRect, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Input")?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold)) {
                let s = lock.size
                lock.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            if let r = modeRect, let modeText {
                fill(capsule(r), 1)
                knockOut(modeText, modeFont, in: r, cg)
            }

            switch look {
            case .number, .pill, .panes, .circle, .minimal: break
            case .segmented:
                if let first = rects.first, let last = rects.last {
                    fill(capsule(NSRect(x: first.minX, y: 0, width: last.maxX - first.minX, height: h)), 0.13)
                }
                for (s, r) in zip(slots, rects) {
                    let thumb = capsule(r.insetBy(dx: 2, dy: 2))
                    switch s.style {
                    case .focused:
                        fill(thumb, 1)
                        knockOut(s.label, numberFont, in: r, cg)
                    case .visible:
                        let ring = capsule(r.insetBy(dx: 2.6, dy: 2.6))
                        ring.lineWidth = 1.2
                        NSColor.black.setStroke()
                        ring.stroke()
                        draw(s.label, numberFont, in: r, alpha: 1)
                    case .occupied:
                        draw(s.label, numberFont, in: r, alpha: 0.8)
                    }
                }
            case .dots:
                for (s, r) in zip(slots, rects) {
                    switch s.style {
                    case .focused:
                        fill(capsule(r.insetBy(dx: 0, dy: 1.5)), 1)
                        knockOut(s.label, numberFont, in: r, cg)
                    case .visible:
                        let ring = NSBezierPath(ovalIn: NSRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7))
                        ring.lineWidth = 1.3
                        NSColor.black.setStroke()
                        ring.stroke()
                    case .occupied:
                        fill(NSBezierPath(ovalIn: NSRect(x: r.midX - 3, y: r.midY - 3, width: 6, height: 6)), 0.55)
                    }
                }
            case .tiles:
                for (s, r) in zip(slots, rects) {
                    let tile = NSBezierPath(roundedRect: r, xRadius: 4.5, yRadius: 4.5)
                    switch s.style {
                    case .focused:
                        fill(tile, 1)
                        knockOut(s.label, numberFont, in: r, cg)
                    case .visible:
                        let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.9, yRadius: 3.9)
                        ring.lineWidth = 1.2
                        NSColor.black.setStroke()
                        ring.stroke()
                        draw(s.label, numberFont, in: r, alpha: 1)
                    case .occupied:
                        draw(s.label, numberFont, in: r, alpha: 0.55)
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Centers digits on their cap height, which reads as optically centered in a small shape.
    private static func origin(_ s: String, _ f: NSFont, in r: NSRect) -> NSPoint {
        let w = (s as NSString).size(withAttributes: [.font: f]).width
        return NSPoint(x: r.midX - w / 2, y: (r.midY - f.capHeight / 2 + f.descender).rounded())
    }

    private static func draw(_ s: String, _ f: NSFont, in r: NSRect, alpha: CGFloat) {
        (s as NSString).draw(at: origin(s, f, in: r),
                             withAttributes: [.font: f, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }

    private static func knockOut(_ s: String, _ f: NSFont, in r: NSRect, _ cg: CGContext) {
        cg.saveGState()
        cg.setBlendMode(.destinationOut)
        (s as NSString).draw(at: origin(s, f, in: r), withAttributes: [.font: f, .foregroundColor: NSColor.black])
        cg.restoreGState()
    }
}

extension WorkspaceIcon {
    /// `panespace preview-indicator`: every look on a dark and a light menu bar at 4×, with a two-digit
    /// workspace and a binding mode, plus the menu badges. For judging looks without a screenshot.
    static func writePreview(to url: URL) {
        let scale: CGFloat = 4, labelW: CGFloat = 230, panelW: CGFloat = 860, rowH = height * scale + 36
        let slots = [Slot(label: "1", style: .focused), Slot(label: "2", style: .occupied), Slot(label: "4", style: .occupied)]
        let looks = Look.allCases
        let size = NSSize(width: labelW + 2 * panelW, height: rowH * CGFloat(looks.count + 1))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let dark = NSColor(white: 0.13, alpha: 1), light = NSColor(white: 0.92, alpha: 1)
        dark.setFill(); NSRect(x: labelW, y: 0, width: panelW, height: size.height).fill()
        light.setFill(); NSRect(x: labelW + panelW, y: 0, width: panelW, height: size.height).fill()
        NSColor(white: 0.2, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: labelW, height: size.height).fill()
        func tinted(_ img: NSImage, _ c: NSColor) -> NSImage {
            NSImage(size: img.size, flipped: false) { r in img.draw(in: r); c.set(); r.fill(using: .sourceAtop); return true }
        }
        func strip(_ images: [NSImage], y: CGFloat) {
            for (panel, ink) in [(labelW, NSColor.white), (labelW + panelW, NSColor.black)] {
                var x = panel + 30
                for img in images {
                    let s = NSSize(width: img.size.width * scale, height: img.size.height * scale)
                    tinted(img, ink).draw(in: NSRect(x: x, y: y + (rowH - s.height) / 2, width: s.width, height: s.height))
                    x += s.width + 70
                }
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)]
        for (i, look) in looks.enumerated() {
            let y = size.height - rowH * CGFloat(i + 1)
            (look.rawValue as NSString).draw(at: NSPoint(x: 20, y: y + rowH / 2 - 14), withAttributes: attrs)
            strip([render(slots: slots, mode: nil, secureInput: false, look: look),
                   render(slots: [Slot(label: "12", style: .focused)], mode: nil, secureInput: false, look: look),
                   render(slots: slots, mode: "resize", secureInput: false, look: look)], y: y)
        }
        ("menu" as NSString).draw(at: NSPoint(x: 20, y: rowH / 2 - 14), withAttributes: attrs)
        strip([Look.number, .pill, .circle].flatMap { l in [menuBadge("1", filled: true, look: l), menuBadge("2", filled: false, look: l)] }, y: 0)
        NSGraphicsContext.current = nil
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
