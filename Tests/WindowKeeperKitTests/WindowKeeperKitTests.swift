import CoreGraphics
import Foundation
import Testing
@testable import WindowKeeperKit

struct DisplayKeyTests {
    private func inputs(builtin: Bool = false, numeric: UInt32 = 0, alnum: String? = nil) -> DisplayKey.Inputs {
        .init(isBuiltin: builtin, vendor: 8718, model: 13428, numericSerial: numeric, alphanumericSerial: alnum, displayUUID: "U")
    }

    @Test func prefersAlphanumericSerial() {
        // The HP E273q on the test desk: junk numeric serial, real alphanumeric one.
        #expect(DisplayKey.make(inputs(numeric: 16_843_009, alnum: "6CM91601YM")) == "sn:8718-13428-6CM91601YM")
    }

    @Test func skipsPlaceholderNumericSerial() {
        #expect(DisplayKey.make(inputs(numeric: 16_843_009)) == "uuid:U")
        #expect(DisplayKey.make(inputs(numeric: 810_366_796)) == "edid:8718-13428-810366796")
    }

    @Test func rejectsFillerAlphanumericSerial() {
        #expect(DisplayKey.make(inputs(numeric: 5555, alnum: "0000000000")) == "edid:8718-13428-5555")
        #expect(DisplayKey.make(inputs(numeric: 5555, alnum: "  ")) == "edid:8718-13428-5555")
    }

    @Test func builtinIsBuiltin() {
        #expect(DisplayKey.make(inputs(builtin: true, alnum: "XYZ123")) == "builtin")
    }

    @Test func identicalMonitorsAreKeptApart() {
        let keys = DisplayKey.disambiguate(["uuid:A", "builtin", "uuid:A"], xs: [3000, -1700, 0])
        #expect(keys == ["uuid:A#2", "builtin", "uuid:A"])
    }

    @Test func signatureIgnoresOrder() {
        #expect(ProfileSignature.make(["b", "a"]) == ProfileSignature.make(["a", "b"]))
    }
}

struct MatcherTests {
    private func saved(_ title: String, _ w: Double, _ h: Double) -> SavedWindow {
        SavedWindow(bundleID: "app", appName: "App", title: title, displayKey: "d",
                    offset: Frame(x: 0, y: 0, width: w, height: h), savedAt: .distantPast)
    }

    @Test func titleBeatsSize() {
        let live = [LiveWindowInfo(title: "B.txt", size: CGSize(width: 500, height: 500)),
                    LiveWindowInfo(title: "A.txt", size: CGSize(width: 900, height: 900))]
        let s = [saved("A.txt", 500, 500), saved("B.txt", 900, 900)]
        let pairs = WindowMatcher.match(live: live, saved: s)
        #expect(pairs == [.init(live: 0, saved: 1), .init(live: 1, saved: 0)])
    }

    @Test func untitledFallBackToSize() {
        let live = [LiveWindowInfo(title: "New tab", size: CGSize(width: 1200, height: 800)),
                    LiveWindowInfo(title: "Docs", size: CGSize(width: 600, height: 900))]
        let s = [saved("Old tab", 610, 890), saved("Other", 1190, 805)]
        let pairs = WindowMatcher.match(live: live, saved: s)
        #expect(pairs == [.init(live: 0, saved: 1), .init(live: 1, saved: 0)])
    }

    @Test func moreLiveThanSavedLeavesExtrasAlone() {
        let live = (0..<3).map { _ in LiveWindowInfo(title: "", size: CGSize(width: 400, height: 400)) }
        #expect(WindowMatcher.match(live: live, saved: [saved("", 400, 400)]).count == 1)
    }
}

struct PlacementTests {
    let dell = LiveDisplay(key: "dell", name: "DELL", isBuiltin: false, isMain: true,
                           bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                           visible: CGRect(x: 0, y: 30, width: 3840, height: 2130))
    let hp = LiveDisplay(key: "hp", name: "HP", isBuiltin: false, isMain: false,
                         bounds: CGRect(x: 3840, y: 441, width: 2560, height: 1440),
                         visible: CGRect(x: 3840, y: 441, width: 2560, height: 1440))

    private func window(on key: String, _ x: Double, _ y: Double, _ w: Double = 800, _ h: Double = 600) -> SavedWindow {
        SavedWindow(bundleID: "a", appName: "A", title: "", displayKey: key,
                    offset: Frame(x: x, y: y, width: w, height: h), savedAt: .distantPast)
    }

    @Test func sameDisplayKeepsOffsetAfterRearranging() {
        // The HP moved from the right of the Dell to its left: same offset, new origin.
        var moved = hp
        moved.bounds.origin = CGPoint(x: -2560, y: 0)
        moved.visible.origin = CGPoint(x: -2560, y: 0)
        let target = Placement.target(for: window(on: "hp", 100, 200), savedDisplays: [], live: [dell, moved])
        #expect(target == CGRect(x: -2460, y: 200, width: 800, height: 600))
    }

    @Test func offEdgeWindowStaysUnlessUnreachable() {
        let hanging = Placement.target(for: window(on: "dell", 3500, 100), savedDisplays: [], live: [dell])
        #expect(hanging?.minX == 3500)
        let lost = Placement.target(for: window(on: "dell", 5000, -50), savedDisplays: [], live: [dell])
        #expect(lost?.minX == CGFloat(3760))
        #expect(lost?.minY == 30)
    }

    @Test func missingDisplayMapsByRankAndFitsOnScreen() {
        let saved = [DisplayRecord(key: "x", name: "X", isBuiltin: false, bounds: Frame(x: 0, y: 0, width: 1920, height: 1080)),
                     DisplayRecord(key: "y", name: "Y", isBuiltin: false, bounds: Frame(x: 1920, y: 0, width: 1920, height: 1080))]
        // Saved on the right-hand monitor of another desk -> lands on the HP, the right-hand one here.
        let target = Placement.target(for: window(on: "y", 1500, 500, 800, 600), savedDisplays: saved, live: [dell, hp])!
        #expect(hp.visible.contains(target))
    }

    @Test func unknownDisplayFallsBackToMain() {
        let target = Placement.target(for: window(on: "gone", 100, 100), savedDisplays: [], live: [hp, dell])!
        #expect(dell.visible.contains(target))
    }

    @Test func displayForFrame() {
        #expect(Placement.display(for: CGRect(x: 3800, y: 500, width: 400, height: 300), among: [dell, hp])?.key == "hp")
    }
}

struct SnapshotTests {
    private func w(_ app: String, _ key: String, _ x: Double, at date: Date = .distantPast) -> SavedWindow {
        SavedWindow(bundleID: app, appName: app, title: "", displayKey: key,
                    offset: Frame(x: x, y: 0, width: 10, height: 10), savedAt: date)
    }

    @Test func mergeKeepsAppsNotCaptured() {
        let existing = [w("mail", "d", 1), w("safari", "d", 2)]
        let merged = SnapshotMerge.merge(existing: existing, captured: [w("safari", "d", 9)], replacing: ["safari"])
        #expect(merged.map(\.offset.x) == [1, 9])
    }

    @Test func unchangedEntriesKeepTimestamp() {
        let old = Date(timeIntervalSince1970: 100)
        let merged = SnapshotMerge.merge(existing: [w("a", "d", 1, at: old)], captured: [w("a", "d", 1, at: Date())], replacing: ["a"])
        #expect(merged.first?.savedAt == old)
    }

    @Test func pileUpIsDetected() {
        let before = [w("a", "dell", 1), w("b", "hp", 1), w("c", "hp", 2)]
        let after = [w("a", "dell", 1), w("b", "dell", 1), w("c", "dell", 2)]
        #expect(SnapshotCheck.looksDisplaced(captured: after, previous: before, connectedDisplays: 2))
        #expect(!SnapshotCheck.looksDisplaced(captured: after, previous: before, connectedDisplays: 1))
    }

    @Test func intervalHasAFloor() {
        #expect(SaveInterval.seconds(value: 3, unit: .seconds) == 10)
        #expect(SaveInterval.seconds(value: 5, unit: .minutes) == 300)
        #expect(SaveInterval.seconds(value: 0, unit: .hours) == 3600)
    }
}

struct SettleTests {
    @Test func wakeSequenceSettlesOnceWithoutTransients() {
        var t = SettleTracker()
        #expect(t.sample("all") == nil)
        #expect(t.sample("all") == .settled(signature: "all", changed: true, disrupted: true))
        // Sleep/wake: monitors drop and return one at a time.
        #expect(t.sample("main") == nil)
        #expect(t.sample("main+hp") == nil)
        #expect(t.sample("all") == nil)
        #expect(t.sample("all") == .settled(signature: "all", changed: false, disrupted: true))
    }

    @Test func quietRecheckIsNotADisruption() {
        var t = SettleTracker()
        _ = t.sample("a"); _ = t.sample("a")
        #expect(t.sample("a") == nil)
        #expect(t.sample("a") == .settled(signature: "a", changed: false, disrupted: false))
    }
}
