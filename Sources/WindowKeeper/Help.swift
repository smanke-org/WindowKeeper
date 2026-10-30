import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// `{hotkey:save}` and `{hotkey:restore}` show the user's own shortcuts.
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        let s = AppSettings.shared
        return text
            .replacingOccurrences(of: "{hotkey:save}", with: s.saveAllHotKey?.display ?? "(no shortcut set)")
            .replacingOccurrences(of: "{hotkey:restore}", with: s.restoreAllHotKey?.display ?? "(no shortcut set)")
    }

    static var debugTokens: String { resolve("{hotkey:save} {hotkey:restore}") }
    static let testTabs = ["Settings"]
    static func topic(forSettingsTab tab: String) -> String { "getting-started" }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("WindowKeeper remembers where your windows go at each desk and puts them back. Plug into the monitors at your desk and every window returns to where you left it there; undock and use the laptop alone, and that layout comes back too."),
            .text("Each set of monitors is a profile, recognized by the monitors' serial numbers, so it's found again at the same desk even after a restart. WindowKeeper saves window positions automatically every few minutes."),
            .heading("Allow access"),
            .text("WindowKeeper needs Accessibility permission (macOS 27 calls it Device Control) to read and move other apps' windows. To remember desktop icons it also asks Finder for permission. The menu bar menu offers \"Allow Accessibility Access…\" or \"Allow Finder Access…\" when either is missing."),
            .tip("The menu bar menu's first line shows which monitor profile is active, and whether it's locked."),
            .tip("While ToolHUD is running, WindowKeeper's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
            .tip("Quitting asks first, since windows aren't saved or put back while WindowKeeper is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "saving", title: "Saving and Restoring", symbol: "macwindow.on.rectangle", blocks: [
            .keys([
                ("{hotkey:save}", "Save All Windows & Icons Now"),
                ("{hotkey:restore}", "Restore All Windows & Icons"),
                ("Save [App] Windows", "Save only the app you were using (menu bar menu)"),
                ("Restore [App] Windows", "Put only that app's windows back"),
                ("Restore from Profile", "Use another desk's layout here, for all windows or one app"),
                ("Undo Last Restore (⌘Z)", "Put windows back where they were before the last restore"),
            ]),
            .heading("Automatic restores"),
            .keys([
                ("A known monitor setup connects", "Docking at a desk WindowKeeper has seen, or waking with its monitors attached"),
                ("WindowKeeper opens", "Usually at login after a restart"),
                ("An app reopens", "Each window goes back as the app opens it"),
            ]),
            .text("After a restore, WindowKeeper watches the windows for a little while and undoes moves an app makes on its own. If you drag a window during that time, it leaves it where you put it. Apps that aren't running are skipped, never opened."),
            .tip("Set the shortcuts in Settings › Keyboard Shortcuts."),
        ]),

        HelpTopic(id: "profiles", title: "Monitor Profiles", symbol: "display.2", blocks: [
            .text("Choose \"Monitor Profiles…\" in the menu bar menu to see every desk WindowKeeper knows. A new profile is created, with a notification, the first time a set of monitors is connected. Rename it after the desk it belongs to."),
            .keys([
                ("Lock", "Auto-save leaves this layout alone; Save Now still updates it"),
                ("Delete Profile", "Removes its saved positions from this Mac and iCloud"),
                ("Import from Another Mac…", "Copy a profile's window positions from another Mac on your iCloud account"),
            ]),
            .text("The built-in display counts too, so working with the lid open or closed at the same desk gives two profiles."),
        ]),

        HelpTopic(id: "icons", title: "Desktop Icons", symbol: "square.grid.3x3", blocks: [
            .text("With \"Remember desktop icon positions too\" on, icons are saved and restored with your windows, per desk, including disks and servers, which go back to their spot when they mount again. WindowKeeper asks Finder to move them, so it needs Finder access (Automation)."),
            .text("If Finder sorts your desktop, it ignores icon positions: click the desktop and choose View › Sort By › None, or Snap to Grid."),
        ]),

        HelpTopic(id: "settings", title: "Settings and Sync", symbol: "gearshape", blocks: [
            .keys([
                ("General", "Appearance, opening at login, asking before quitting, and the Dock and menu bar icons"),
                ("Save automatically", "How often positions are saved"),
                ("Restoring", "Which events put windows back"),
                ("Keyboard Shortcuts", "Save all and restore all"),
                ("iCloud and updates", "Sync settings with your other Macs; how updates install"),
                ("Storage", "Where profiles are kept; Show in Finder opens the folder"),
            ]),
            .text("Profiles are stored on this Mac and copied to a folder for this Mac in iCloud Drive, which is how another Mac can import them."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("windowkeeper://save", "Save all windows"),
                ("windowkeeper://restore", "Restore all windows"),
                ("windowkeeper://save-app", "Save the app in front"),
                ("windowkeeper://restore-app", "Restore the app in front"),
                ("windowkeeper://restore-icons", "Restore desktop icons"),
                ("windowkeeper://undo", "Undo the last restore"),
                ("windowkeeper://profiles", "Open Monitor Profiles"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's WindowKeeper buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Windows don't move"),
            .text("WindowKeeper needs Accessibility permission. Choose \"Allow Accessibility Access…\" in the menu bar menu. If it's on but nothing moves, remove WindowKeeper from the list in System Settings › Privacy & Security and add it again."),
            .heading("A window lands in the wrong place"),
            .text("Some apps move their own windows as they open. Restore again, or save the layout once it's right. Windows on other Spaces aren't moved."),
            .heading("Desktop icons don't move"),
            .text("Allow Finder access, and make sure Finder isn't sorting the desktop (View › Sort By › None)."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("WindowKeeperHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
