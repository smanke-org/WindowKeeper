import CoreGraphics
import Foundation

/// One on-screen window as the window server lists it: cheap to read, so it can be sampled
/// all the time, unlike the Accessibility API.
public struct WindowFrameSample: Hashable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var frame: CGRect

    public init(id: UInt32, pid: Int32, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

/// Which apps had windows moved while the monitors were changing.
///
/// A monitor can drop out for under a second as the displays wake: macOS piles its windows
/// onto another screen and, when it returns, often leaves them sized to fill it (Safari
/// came back at 3840×2130 on the Dell). The display samples taken every 2 s can miss such
/// a dropout entirely, so the monitor set alone does not show it — the windows do.
public enum WindowShift {
    public static func movedApps(before: [WindowFrameSample], after: [WindowFrameSample], tolerance: CGFloat = 2) -> Set<Int32> {
        let earlier = Dictionary(before.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        var moved = Set<Int32>()
        for window in after {
            guard let old = earlier[window.id] else { continue }
            if abs(old.minX - window.frame.minX) > tolerance || abs(old.minY - window.frame.minY) > tolerance
                || abs(old.width - window.frame.width) > tolerance || abs(old.height - window.frame.height) > tolerance {
                moved.insert(window.pid)
            }
        }
        return moved
    }
}
