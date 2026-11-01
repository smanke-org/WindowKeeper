import AppKit
import WindowKeeperKit

/// Other apps' on-screen windows as the window server lists them. Needs no permission and
/// costs about a millisecond, so it can be read every couple of seconds.
enum WindowServerFrames {
    static func current() -> [WindowFrameSample] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            // Layer 0 holds ordinary windows; menus, the Dock and overlays sit above it.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return WindowFrameSample(id: id, pid: pid, frame: frame)
        }
    }
}
