import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut: a key code plus Carbon modifier flags, and how to show it.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// Builds one from a key press, if it has at least one of ⌘ ⌥ ⌃ — a bare key would
    /// steal ordinary typing from every app. F-keys may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.isFunctionKey(Int(event.keyCode)) else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        display = symbols + Self.name(for: event)
    }

    /// Builds one from a key code and Carbon modifiers (ShortcutsLens's Change Shortcut), named
    /// the way a key press would be in the current keyboard layout. Nil without ⌘ ⌥ or ⌃,
    /// unless it's an F-key.
    init?(keyCode: Int, carbonModifiers: Int) {
        let mods = UInt32(carbonModifiers) & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard (0...127).contains(keyCode), mods & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.isFunctionKey(keyCode) else { return nil }
        var symbols = ""
        if mods & UInt32(controlKey) != 0 { symbols += "⌃" }
        if mods & UInt32(optionKey) != 0 { symbols += "⌥" }
        if mods & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if mods & UInt32(cmdKey) != 0 { symbols += "⌘" }
        self.keyCode = UInt32(keyCode)
        modifiers = mods
        display = symbols + Self.name(keyCode: keyCode, characters: Self.layoutCharacter(keyCode))
    }

    private static func name(for event: NSEvent) -> String {
        name(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers)
    }

    /// F1–F20 may stand alone: no app types with them.
    static func isFunctionKey(_ code: Int) -> Bool { fKeys[code] != nil }

    static func name(keyCode code: Int, characters: String?) -> String {
        if let f = fKeys[code] { return "F\(f)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return (characters ?? "?").uppercased()
        }
    }

    /// What the key types with no modifiers in the current layout ("s" for kVK_ANSI_S on QWERTY).
    static func layoutCharacter(_ keyCode: Int, shift: Bool = false) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90), and `kVK_F1...kVK_F20` trapped on the first key pressed.
    static let fKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works from a menu bar app
/// and needs no extra permission, unlike an event tap.
@MainActor
final class HotKeyCenter {
    enum Action: UInt32, CaseIterable {
        case saveAll = 1
        case restoreAll = 2
    }

    static let shared = HotKeyCenter()
    var perform: ((Action) -> Void)?
    private var refs: [Action: EventHotKeyRef] = [:]
    private var installed = false

    /// Registers whatever is set in AppSettings, replacing earlier registrations.
    func apply() {
        installHandlerOnce()
        unregisterAll()
        let settings = AppSettings.shared
        for action in Action.allCases {
            guard let key = action == .saveAll ? settings.saveAllHotKey : settings.restoreAllHotKey else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x574B_4850), id: action.rawValue) // "WKHP"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                Diagnostics.note("hotkey \(key.display) for \(action) not registered (\(status)) — probably taken by another app")
            }
        }
        ShortcutsLensReport.publish()
    }

    /// For ShortcutsLens: the shortcuts that registered, named as Settings names them.
    var reportedShortcuts: [ShortcutsLensReport.Shortcut] {
        let settings = AppSettings.shared
        return Action.allCases.compactMap { action in
            guard refs[action] != nil,
                  let key = action == .saveAll ? settings.saveAllHotKey : settings.restoreAllHotKey else { return nil }
            return .init(id: "\(action)", title: title(of: action),
                         keyCode: Int(key.keyCode), carbonModifiers: Int(key.modifiers))
        }
    }

    /// ShortcutsLens's Change Shortcut: saves the keys in AppSettings as the Settings shortcut
    /// boxes do (so Settings shows them and sync carries them) and registers again. Nil when done,
    /// or why not.
    func change(id: String, keyCode: Int, carbonModifiers: Int) -> String? {
        guard let action = Action.allCases.first(where: { "\($0)" == id }) else { return "WindowKeeper has no shortcut called \(id)." }
        guard let key = HotKey(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return "WindowKeeper shortcuts need ⌘, ⌥ or ⌃ (F-keys may stand alone)."
        }
        if let other = others(using: key, except: action).first {
            return "WindowKeeper already uses \(key.display) for \(title(of: other))."
        }
        let previous = hotKey(for: action)
        save(key, for: action)
        apply()
        guard refs[action] == nil else { return nil }
        // Taken by another app: keep the old keys rather than leave the shortcut dead.
        save(previous, for: action)
        apply()
        return "\(key.display) is taken by another app, so WindowKeeper kept \(previous?.display ?? "no shortcut")."
    }

    func hotKey(for action: Action) -> HotKey? {
        action == .saveAll ? AppSettings.shared.saveAllHotKey : AppSettings.shared.restoreAllHotKey
    }

    /// Writes the same settings the Settings shortcut boxes do.
    func save(_ key: HotKey?, for action: Action) {
        switch action {
        case .saveAll: AppSettings.shared.saveAllHotKey = key
        case .restoreAll: AppSettings.shared.restoreAllHotKey = key
        }
    }

    func title(of action: Action) -> String { action == .saveAll ? "Save all" : "Restore all" }

    /// The other shortcuts that use these keys.
    func others(using key: HotKey, except action: Action?) -> [Action] {
        Action.allCases.filter { $0 != action && hotKey(for: $0)?.keyCode == key.keyCode && hotKey(for: $0)?.modifiers == key.modifiers }
    }

    /// While a shortcut is being edited, the current ones must not fire.
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        Diagnostics.note("hotkey: \(action)")
        perform?(action)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let value = id.id
    // Carbon delivers hot keys on the main thread's event loop.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(value) }
    return noErr
}
