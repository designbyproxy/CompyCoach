// Prints the window ID of the largest on-screen window owned by a process, for
// `screencapture -l`. Small windows (the menu bar icon) are ignored. Used by scripts/make-screenshots.sh.
//
//   window-id <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: window-id <pid>\n".data(using: .utf8)!)
    exit(2)
}

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let best = info
    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
    .compactMap { w -> (id: Int, area: Double)? in
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return (id, (b["Width"] ?? 0) * (b["Height"] ?? 0))
    }
    .filter { $0.area > 200 * 200 }
    .max { $0.area < $1.area }

guard let best else { exit(1) }
print(best.id)
