import CoreGraphics
import Foundation

/// What is known about a live window when deciding which saved entry it is.
public struct LiveWindowInfo: Sendable {
    public var title: String
    public var size: CGSize

    public init(title: String, size: CGSize) {
        self.title = title
        self.size = size
    }
}

/// Pairs live windows with saved entries for the same app.
///
/// Window IDs do not survive a restart, so identity has to be inferred. Title is the strong
/// signal — a document window's title is its file name. Whatever is left is paired by
/// closest size, which handles windows whose titles change (a browser's current tab) and
/// apps that title every window the same.
public enum WindowMatcher {
    public struct Pair: Hashable, Sendable {
        public var live: Int
        public var saved: Int
    }

    public static func match(live: [LiveWindowInfo], saved: [SavedWindow]) -> [Pair] {
        var pairs: [Pair] = []
        var freeLive = Set(live.indices)
        var freeSaved = Set(saved.indices)

        // Same title first, closest size among duplicates.
        let titles = Set(live.map(\.title)).intersection(saved.map(\.title)).subtracting([""])
        for title in titles.sorted() {
            let l = live.indices.filter { freeLive.contains($0) && live[$0].title == title }
            let s = saved.indices.filter { freeSaved.contains($0) && saved[$0].title == title }
            for pair in closestBySize(live: l, saved: s, liveWindows: live, savedWindows: saved) {
                pairs.append(pair)
                freeLive.remove(pair.live)
                freeSaved.remove(pair.saved)
            }
        }

        // Then the rest by size.
        pairs += closestBySize(live: freeLive.sorted(), saved: freeSaved.sorted(), liveWindows: live, savedWindows: saved)
        return pairs.sorted { $0.live < $1.live }
    }

    /// Greedy: the globally closest pair first, so one bad pairing cannot steal another
    /// window's obvious match. Ties keep saved order.
    private static func closestBySize(live: [Int], saved: [Int], liveWindows: [LiveWindowInfo], savedWindows: [SavedWindow]) -> [Pair] {
        var candidates: [(distance: Double, live: Int, saved: Int)] = []
        for l in live {
            for s in saved {
                let a = liveWindows[l].size
                let b = savedWindows[s].offset
                candidates.append((abs(a.width - b.width) + abs(a.height - b.height), l, s))
            }
        }
        candidates.sort { ($0.distance, $0.saved, $0.live) < ($1.distance, $1.saved, $1.live) }
        var usedLive = Set<Int>()
        var usedSaved = Set<Int>()
        var result: [Pair] = []
        for c in candidates where !usedLive.contains(c.live) && !usedSaved.contains(c.saved) {
            usedLive.insert(c.live)
            usedSaved.insert(c.saved)
            result.append(Pair(live: c.live, saved: c.saved))
        }
        return result
    }
}
