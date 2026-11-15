#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Debug hook `shortcut-editor:<png path>` (WINDOWKEEPER_DEBUG=1, Settings open): opens the
/// Restore all shortcut's editor, checks typing "+" (⇧ + "="), a bare letter, an F-key alone,
/// then presses the Save all keys there and sets them, so they move. Saves a picture of the
/// editor, then opens it again and clears it. Results go to the log.
@MainActor
enum DebugShortcutEditor {
    static func run(window: NSWindow?, shot: String) async -> String {
        func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
            ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
        }
        let settings = AppSettings.shared
        guard let window, let content = window.contentView else { return "Settings is not open" }
        let buttons = recorders(in: content)
        guard buttons.count == 2 else { return "found \(buttons.count) shortcut boxes" }
        let button = buttons[1]
        var out = ["before: save \(settings.saveAllHotKey?.display ?? "none"), restore \(settings.restoreAllHotKey?.display ?? "none")"]
        if settings.saveAllHotKey == nil {
            settings.saveAllHotKey = HotKey(keyCode: kVK_ANSI_S, carbonModifiers: controlKey | optionKey | cmdKey)
            out.append("gave save \(settings.saveAllHotKey?.display ?? "-")")
        }
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard let model = button.debugModel else { return out.joined(separator: "; ") + "; editor did not open" }
        out.append("open title \(button.debugTitle), registered \(HotKeyCenter.shared.reportedShortcuts.map(\.title))")
        model.typed("+")
        out.append("plus→\(model.keyText) shift \(model.shift) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.command = true
        model.typed("+")
        out.append("⌘ plus→\(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.control = false; model.option = false; model.shift = false; model.command = false
        model.typed("k")
        out.append("bare k combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.choose(Int(kVK_Space))
        model.typed(model.keyText)
        out.append("menu Space→\(model.keyText)")
        model.choose(Int(kVK_F6))
        model.typed(model.keyText)
        out.append("menu F6→\(model.keyText); F6 alone: \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        let names = [kVK_Delete, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
            .compactMap { HotKey(keyCode: $0, carbonModifiers: cmdKey)?.display }
        out.append("names \(names.joined(separator: " "))")
        guard let save = settings.saveAllHotKey else { return out.joined(separator: "; ") }
        var flags: NSEvent.ModifierFlags = []
        if save.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if save.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if save.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if save.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(save.keyCode)) {
            _ = model.handle(event)
        }
        out.append("pressed \(model.combo?.display ?? "-") moves from \(model.movesFrom)")
        try? await Task.sleep(for: .milliseconds(300))
        if !shot.isEmpty, let view = button.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
        }
        model.finish?(.set(model.combo))
        out.append("right after set: title \(button.debugTitle), registered \(HotKeyCenter.shared.reportedShortcuts.map(\.title))")
        await waitForClose(button)
        out.append("after set: save \(settings.saveAllHotKey?.display ?? "none"), restore \(settings.restoreAllHotKey?.display ?? "none"), title \(button.debugTitle), registered \(HotKeyCenter.shared.reportedShortcuts.map(\.title))")
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard let again = button.debugModel else { return out.joined(separator: "; ") + "; editor did not reopen" }
        again.finish?(.set(nil))
        out.append("right after clear: title \(button.debugTitle)")
        await waitForClose(button)
        out.append("after clear: save \(settings.saveAllHotKey?.display ?? "none"), restore \(settings.restoreAllHotKey?.display ?? "none"), title \(button.debugTitle), registered \(HotKeyCenter.shared.reportedShortcuts.map(\.title))")
        return out.joined(separator: "; ")
    }

    /// The popover's close finishes after its animation.
    private static func waitForClose(_ button: ShortcutRecorder.RecorderButton) async {
        for _ in 0..<30 where button.debugModel != nil { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
#endif
