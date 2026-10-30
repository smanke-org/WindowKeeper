#if DEBUG
import AppKit

/// `WINDOWKEEPER_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off|settings>` (trace to `WINDOWKEEPER_DEBUG_TRACE`):
/// quits as ⌘Q does a second after launch, then answers the question a second later: presses
/// Return (then clicks Cancel), clicks Cancel or Quit (ticking "Don't ask again" first for
/// `suppress`), or with `off` turns the setting off first. What the question looked like is
/// traced before any answer; when the quit is cancelled, so is whether the app is still
/// running and its activation policy, and then it quits without asking.
@MainActor
enum DebugQuitTest {
    private static var lines: [String] = []

    static func run(_ how: String, settingsWindow: SettingsWindowController) {
        if how == "settings" { return snapshotSettings(settingsWindow) }
        trace("started policy \(NSApp.activationPolicy().rawValue) confirmQuit \(AppSettings.shared.confirmQuit)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if how == "off" { AppSettings.shared.confirmQuit = false }
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { Self.answer(how) }
                }
                RunLoop.main.add(answer, forMode: .common)
                trace("quitting (\(how))")
                NSApp.terminate(nil)
                // Only reached when the quit was cancelled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        trace("still running; confirmQuit \(AppSettings.shared.confirmQuit) policy \(NSApp.activationPolicy().rawValue)")
                        trace("done")
                        QuitConfirmation.quitNow()
                    }
                }
            }
        }
    }

    private static func answer(_ how: String) {
        guard let window = NSApp.modalWindow else { return trace("no modal window") }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        trace("asked \(texts) buttons \(titles) key \(window.isKeyWindow) visible \(window.isVisible) active \(NSApp.isActive) front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            let check = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    trace("after Return: question still up \(NSApp.modalWindow != nil)")
                    buttons.first { $0.title == "Cancel" }?.performClick(nil)
                }
            }
            RunLoop.main.add(check, forMode: .common)
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }

    /// `settings`: renders the Settings window to `WINDOWKEEPER_DEBUG_SNAPSHOT` (a PNG), then quits.
    private static func snapshotSettings(_ settingsWindow: SettingsWindowController) {
        settingsWindow.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let window = NSApp.windows.first { $0.title == "WindowKeeper Settings" }
                if let path = ProcessInfo.processInfo.environment["WINDOWKEEPER_DEBUG_SNAPSHOT"],
                   let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                trace("settings window \(window != nil)")
                QuitConfirmation.quitNow()
            }
        }
    }

    private static func trace(_ s: String) {
        lines.append(s)
        guard let path = ProcessInfo.processInfo.environment["WINDOWKEEPER_DEBUG_TRACE"] else { return }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
