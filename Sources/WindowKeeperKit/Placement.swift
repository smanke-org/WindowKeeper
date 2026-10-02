import CoreGraphics
import Foundation

/// Works out where a saved window goes on the monitors connected now.
public enum Placement {
    /// - Parameters:
    ///   - window: the saved entry.
    ///   - savedDisplays: the displays of the profile the entry came from.
    ///   - live: the displays connected now.
    public static func target(for window: SavedWindow, savedDisplays: [DisplayRecord], live: [LiveDisplay]) -> CGRect? {
        guard let main = live.first(where: \.isMain) ?? live.first else { return nil }
        let offset = window.offset

        // Its own monitor is here: same offset, as saved. Only pulled back if the title bar
        // would end up out of reach — a window deliberately hanging off an edge stays put.
        if let home = live.first(where: { $0.key == window.displayKey }) {
            let frame = CGRect(x: home.bounds.minX + offset.x, y: home.bounds.minY + offset.y,
                               width: offset.width, height: offset.height)
            return keepReachable(frame, in: home.visible)
        }

        // Its monitor is missing — restoring another desk's profile, or a monitor unplugged.
        // Map by position in the arrangement (leftmost to leftmost, and so on), scale
        // proportionally, and keep it fully on screen.
        let target = stand(in: window.displayKey, savedDisplays: savedDisplays, live: live) ?? main
        let source = savedDisplays.first { $0.key == window.displayKey }?.bounds.rect
        let frame: CGRect
        if let source, source.width > 0, source.height > 0 {
            let sx = target.visible.width / source.width
            let sy = target.visible.height / source.height
            frame = CGRect(x: target.visible.minX + offset.x * sx,
                           y: target.visible.minY + offset.y * sy,
                           width: offset.width * min(1, sx),
                           height: offset.height * min(1, sy))
        } else {
            frame = CGRect(x: target.visible.minX + offset.x, y: target.visible.minY + offset.y,
                           width: offset.width, height: offset.height)
        }
        return clamp(frame, into: target.visible)
    }

    /// The live display standing in for a missing one: same rank left to right, among the
    /// saved profile's displays and the connected ones.
    static func stand(in key: String, savedDisplays: [DisplayRecord], live: [LiveDisplay]) -> LiveDisplay? {
        let savedOrder = savedDisplays.sorted { ($0.bounds.x, $0.bounds.y) < ($1.bounds.x, $1.bounds.y) }
        guard let rank = savedOrder.firstIndex(where: { $0.key == key }) else { return nil }
        let liveOrder = live.sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
        guard !liveOrder.isEmpty else { return nil }
        return liveOrder[min(rank, liveOrder.count - 1)]
    }

    /// Fits entirely inside `area`, shrinking if it has to.
    public static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
        f.origin.y = min(max(f.minY, area.minY), area.maxY - f.height)
        return f
    }

    /// Leaves the frame alone unless its title bar would be unreachable: then moves it just
    /// far enough that the top edge is on screen and at least `grip` points of it show.
    public static func keepReachable(_ frame: CGRect, in area: CGRect, grip: CGFloat = 80) -> CGRect {
        var f = frame
        if f.minY < area.minY { f.origin.y = area.minY }
        if f.minY > area.maxY - grip / 2 { f.origin.y = area.maxY - grip / 2 }
        if f.maxX < area.minX + grip { f.origin.x = area.minX + grip - f.width }
        if f.minX > area.maxX - grip { f.origin.x = area.maxX - grip }
        return f
    }

    /// Which display a window belongs to: the one holding its centre, else the one it
    /// overlaps most, else the main display.
    public static func display(for frame: CGRect, among live: [LiveDisplay]) -> LiveDisplay? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let holder = live.first(where: { $0.bounds.contains(centre) }) { return holder }
        let best = live.max { area($0.bounds.intersection(frame)) < area($1.bounds.intersection(frame)) }
        if let best, area(best.bounds.intersection(frame)) > 0 { return best }
        return live.first(where: \.isMain) ?? live.first
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
