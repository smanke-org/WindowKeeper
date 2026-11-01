#if DEBUG
import AppKit

/// Debug builds only. `WINDOWKEEPER_DEBUG_UPDATE_NOTES=<folder>`: fetches the notes of WindowKeeper's
/// own releases, draws the update prompt, the What's New sheet Settings shows after an
/// automatic update, and Settings itself to PNGs, writes report.txt, and quits. It starts
/// nothing else: no saving, restoring, sync or updates. Run it from a copy with its own bundle
/// identifier, so it has its own settings; it refuses to run as com.smanke.WindowKeeper.
@MainActor
enum DebugUpdateNotes {
    static func run(folder: String, settingsWindow: SettingsWindowController) {
        guard Bundle.main.bundleIdentifier != "com.smanke.WindowKeeper" else {
            NSLog("WindowKeeper: run this test from a copy with its own bundle identifier")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        func contentSize() -> CGSize {
            settingsWindow.window.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }

        Task {
            note("running \(AppInfo.version)")
            // The update prompt, as someone on 1.1.3 would see it offered 1.1.6.
            let notes = await ReleaseNotes.fetch(newAfter: "1.1.3", through: "1.1.6")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.1.6", current: "1.1.3", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "1.1.5"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            settingsWindow.show()
            // Before the installed WindowKeeper moves it: the form's own height, or
            // the size dragged to last time.
            note("settings opened at \(contentSize()) (chosen \(String(describing: settingsWindow.chosenSize)))")
            try? await Task.sleep(for: .seconds(4))
            render(settingsWindow.window?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(settingsWindow.window?.attachedSheet != nil)")
            if let window = settingsWindow.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(for: .seconds(1))
            let window = settingsWindow.window
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) natural content \(contentSize())")
            // Scrolled to the bottom, where the Updates section and What's New… are.
            if let scroll = window?.contentView.flatMap(firstScrollView), let doc = scroll.documentView {
                note("scroll: document \(doc.frame.size) visible \(scroll.contentView.bounds.size) insets \(scroll.contentInsets) safe \(window?.contentView?.safeAreaInsets ?? NSEdgeInsetsZero)")
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.maxY : 0))
                try? await Task.sleep(for: .seconds(1))
            }
            render(window, to: out.appending(path: "settings.png"))

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            settingsWindow.showWhatsNew()
            try? await Task.sleep(for: .seconds(3))
            render(settingsWindow.window?.attachedSheet, to: out.appending(path: "whats-new-asked.png"))
            note("asked sheet shown: \(settingsWindow.window?.attachedSheet != nil)")
            if let window = settingsWindow.window, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Dragged bigger: the form fills the window, and the size is kept.
            if let window {
                window.setContentSize(NSSize(width: 640, height: 420))
                settingsWindow.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                // Drawn straight away: the installed WindowKeeper may put the window back.
                window.displayIfNeeded()
                render(window, to: out.appending(path: "settings-dragged.png"))
                note("dragged content \(contentSize()) chosen \(String(describing: settingsWindow.chosenSize))")
                // The smallest it can be dragged to: the form's width, 280 points high.
                note("smallest content \(window.contentMinSize)")
            }
            note("done")
            exit(0)
        }
    }

    private static func firstScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(sub) { return found } }
        return nil
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
