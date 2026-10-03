import AppKit
import WindowKeeperKit

/// A desktop icon as Finder reports it.
struct DesktopIcon {
    let name: String
    let kind: SavedIcon.Kind
    /// Centre of the icon, in global top-left coordinates — the same space as windows.
    let position: CGPoint
    let fileID: String?
}

/// Reads and moves desktop icons by asking Finder over Apple Events.
///
/// Ported from Desktop Bins, with its lessons:
/// - Icons expose `desktop position`; plain `position` reads -1,-1. Read the parallel
///   lists (`name of every item of desktop`, …) rather than iterating item references.
/// - `every item of desktop` includes the disks and servers Finder shows there.
/// - The hardened runtime needs `com.apple.security.automation.apple-events`, or events are
///   blocked before macOS ever asks the user. Never pre-flight the permission: just send a
///   real event once the run loop is running, and that raises the prompt.
/// - A refusal (-1743) is surfaced in the menu and Settings, never in an alert raised from
///   a timer — an accessory app's background modal can be answered by a stray keystroke.
///
/// Scripts run in `osascript` on a background queue rather than in-process: the first event
/// waits on the permission prompt, and a busy Finder can stall a reply, neither of which may
/// freeze the menu. The events are still attributed to WindowKeeper, its responsible process.
@MainActor
enum FinderDesktop {
    enum Access: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) static var access: Access = .unknown
    /// Called when `access` changes, so the menu icon and Settings can follow.
    static var onAccessChange: (() -> Void)?

    // ASCII unit and record separators: file names can contain tabs and newlines.
    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    /// Every icon on the desktop, or nil if Finder could not be asked.
    static func read(timeout: TimeInterval = 15) async -> [DesktopIcon]? {
        let script = """
        with timeout of 10 seconds
            tell application "Finder"
                set theNames to name of every item of desktop
                set theClasses to class of every item of desktop
                set thePositions to desktop position of every item of desktop
                -- Inside the tell block: `disk` is Finder's term and undefined outside it.
                set output to ""
                repeat with i from 1 to count of theNames
                    set p to item i of thePositions
                    set k to "item"
                    if (item i of theClasses) is disk then set k to "volume"
                    set output to output & (item i of theNames) & (character id 31) & k & (character id 31) & (item 1 of p) & (character id 31) & (item 2 of p) & (character id 30)
                end repeat
            end tell
        end timeout
        return output
        """
        guard let output = await run(script, timeout: timeout) else { return nil }
        let ids = fileIDs()
        return output.components(separatedBy: record).compactMap { line in
            let f = line.components(separatedBy: unit)
            guard f.count == 4, let x = Double(f[2]), let y = Double(f[3]) else { return nil }
            let kind: SavedIcon.Kind = f[1] == "volume" ? .volume : .item
            return DesktopIcon(name: f[0], kind: kind, position: CGPoint(x: x, y: y),
                               fileID: kind == .item ? ids[f[0]] : nil)
        }
    }

    /// Moves icons, all in one Apple Event round trip. An icon that is gone is skipped on its own.
    /// Returns how many moves Finder accepted, or nil if Finder could not be asked.
    @discardableResult
    static func place(_ moves: [(name: String, point: CGPoint)]) async -> Int? {
        guard !moves.isEmpty else { return 0 }
        var body = "set placed to 0\nwith timeout of 10 seconds\ntell application \"Finder\"\n"
        for move in moves {
            body += """
                try
                    set desktop position of item "\(escape(move.name))" of desktop to {\(Int(move.point.x.rounded())), \(Int(move.point.y.rounded()))}
                    set placed to placed + 1
                end try

            """
        }
        body += "end tell\nend timeout\nreturn placed as text"
        return await run(body, timeout: 15).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Finder ignores positions while the desktop is sorted (View › Sort By anything but
    /// None or Snap to Grid). Read from Finder's preferences, which needs no Apple Event.
    static var arrangementIgnoresPositions: Bool {
        guard let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any],
              let icons = settings["IconViewSettings"] as? [String: Any],
              let arrangeBy = icons["arrangeBy"] as? String
        else { return false }
        return !["grid", "none"].contains(arrangeBy)
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    // MARK: - Private

    /// File identifiers of the Desktop folder's contents, keyed by name. Stable across a
    /// rename within the volume, which is how a renamed icon is still recognised.
    private static func fileIDs() -> [String: String] {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath(),
              let contents = try? FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: [.fileIdentifierKey])
        else { return [:] }
        var ids: [String: String] = [:]
        for url in contents {
            if let id = try? url.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier {
                ids[url.lastPathComponent] = "\(id)"
            }
        }
        return ids
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String, timeout: TimeInterval) async -> String? {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runOSAScript(source, timeout: timeout))
            }
        }
        let (status, output, error) = result
        guard status == 0 else {
            // osascript ends its error with the code in parentheses, e.g. "… (-1743)".
            let code = error.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression)
                .map { String(error[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "() \n")) } ?? "\(status)"
            Diagnostics.note("Finder Apple Event failed (\(code))")
            if code == "-1743" { setAccess(.denied) }
            return nil
        }
        setAccess(.granted)
        // osascript adds a trailing newline to the result.
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    /// Runs a script, killing it after `timeout` seconds. Returns status, stdout, stderr.
    nonisolated private static func runOSAScript(_ source: String, timeout: TimeInterval) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return (-1, "", "\(error)") }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    private static func setAccess(_ new: Access) {
        guard access != new else { return }
        access = new
        Diagnostics.note("Finder access: \(new)")
        onAccessChange?()
    }
}
