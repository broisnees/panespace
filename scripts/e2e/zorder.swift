import CoreGraphics
import Foundation
// Prints on-screen layer-0 windows front to back: id owner name
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as! Int, (w[kCGWindowOwnerName as String] as? String) ?? "", (w[kCGWindowName as String] as? String) ?? "")
}
