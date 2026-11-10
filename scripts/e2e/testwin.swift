import AppKit
// E2E test app: windows on command. stdin lines: open N | dialog | minimize K | restore K | close K | minsize K W H | quit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
NSWindow.allowsAutomaticWindowTabbing = false
var wins: [Int: NSWindow] = [:]
var next = 1
let tag = CommandLine.arguments.dropFirst().first ?? "A"
func say(_ s: String) { print(s); fflush(stdout) }
func make(dialog: Bool) -> Int {
    let k = next; next += 1
    let style: NSWindow.StyleMask = dialog ? [.titled, .closable] : [.titled, .closable, .miniaturizable, .resizable]
    let w = NSWindow(contentRect: NSRect(x: 200 + k * 30, y: 200 + k * 20, width: dialog ? 360 : 520, height: dialog ? 220 : 380),
                     styleMask: style, backing: .buffered, defer: false)
    w.title = "E2E-\(tag)-\(k)\(dialog ? "-dialog" : "")"
    w.isReleasedWhenClosed = false
    if !dialog { w.collectionBehavior.insert(.fullScreenPrimary) }
    w.makeKeyAndOrderFront(nil)
    wins[k] = w
    return k
}
DispatchQueue.global().async {
    while let line = readLine() {
        let p = line.split(separator: " ").map(String.init)
        DispatchQueue.main.async {
            switch p.first {
            case "open": let n = Int(p[1]) ?? 1; say("ok " + (0..<n).map { _ in String(make(dialog: false)) }.joined(separator: " "))
            case "dialog": say("ok \(make(dialog: true))")
            case "minimize": wins[Int(p[1])!]?.miniaturize(nil); say("ok")
            case "restore": wins[Int(p[1])!]?.deminiaturize(nil); say("ok")
            case "close": wins[Int(p[1])!]?.close(); wins[Int(p[1])!] = nil; say("ok")
            case "minsize": wins[Int(p[1])!]?.minSize = NSSize(width: Double(p[2])!, height: Double(p[3])!); say("ok")
            case "front": app.activate(ignoringOtherApps: true); wins[Int(p[1])!]?.makeKeyAndOrderFront(nil); say("ok")
            case "quit": say("ok"); exit(0)
            default: say("err")
            }
        }
    }
    exit(0)
}
app.activate(ignoringOtherApps: true)
say("ready")
app.run()
