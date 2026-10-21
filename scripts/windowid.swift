import CoreGraphics
import Foundation

// Prints the CGWindowID of the frontmost on-screen window owned by the given process id.
guard let pidText = CommandLine.arguments.dropFirst().first, let pid = Int(pidText) else { exit(2) }
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { exit(2) }
for info in list {
    guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == pid,
          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          let id = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let w = bounds["Width"] as? Double, w > 200 else { continue }
    print(id)
    exit(0)
}

exit(1)
