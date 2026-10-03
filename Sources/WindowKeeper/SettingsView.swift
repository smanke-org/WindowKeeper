import AppKit
import SwiftUI
import WindowKeeperKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let store: ProfileStore
    let keeper: Keeper

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !keeper.isTrusted { accessibilityWarning }

            section("Saving") {
                Toggle("Save window positions automatically", isOn: $settings.autoSave)
                HStack(spacing: 8) {
                    Text("Every")
                    TextField("", value: intervalValue, format: .number)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $settings.autoSaveUnit) {
                        ForEach(IntervalUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue.capitalized).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!settings.autoSave)
                .padding(.leading, 20)
                caption("Saves to the profile for the monitors connected now. Paused for a minute after monitors change, so windows macOS moved out of the way are never saved. The shortest interval is 10 seconds.")
                    .padding(.leading, 20)
            }

            Divider()

            section("Restoring") {
                Toggle("When a known monitor setup is connected", isOn: $settings.restoreOnProfileDetected)
                caption("Docking at a desk WindowKeeper has seen before, or waking with external monitors attached, puts every window back.")
                Toggle("When WindowKeeper opens", isOn: $settings.restoreOnLaunch)
                    .padding(.top, 4)
                caption("Usually at login after a restart.")
                Toggle("When an app reopens", isOn: $settings.restoreOnAppRelaunch)
                    .padding(.top, 4)
                caption("Each window goes back as the app opens it. Drag a window during that time and WindowKeeper leaves it where you put it.")
            }

            Divider()

            section("Desktop Icons") {
                Toggle("Remember desktop icon positions too", isOn: $settings.rememberDesktopIcons)
                caption("Saved and restored with your windows, per desk — including disks and servers, which go back to their spot when they mount again. WindowKeeper asks Finder to move them, which needs Automation › Finder.")
                if settings.rememberDesktopIcons, FinderDesktop.access == .denied {
                    HStack {
                        Label("Finder access is off, so icons can’t be read or moved.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Automation Settings") { FinderDesktop.openAutomationSettings() }
                            .controlSize(.small)
                    }
                }
                if settings.rememberDesktopIcons, FinderDesktop.arrangementIgnoresPositions {
                    caption("Finder is sorting your desktop, so it ignores icon positions. In Finder, click the desktop and choose View › Sort By › None or Snap to Grid.")
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            section("Keyboard Shortcuts") {
                shortcutRow("Save all", $settings.saveAllHotKey)
                shortcutRow("Restore all", $settings.restoreAllHotKey)
                caption("Work from any app. Click a box and press the keys; Delete clears it.")
            }

            Divider()

            section("General") {
                Toggle("Open WindowKeeper at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                if launchAtLogin.needsApproval {
                    HStack {
                        caption("Waiting for approval in Login Items.")
                        Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                Toggle("Check for updates when WindowKeeper opens", isOn: $settings.checkForUpdatesAtLaunch)
                    .help("Looks for a newer release on GitHub a few seconds after launch. You are only asked if there is one.")
            }

            Divider()

            section("Storage") {
                HStack(alignment: .firstTextBaseline) {
                    caption(cloudDescription)
                    Spacer()
                    Button("Show in Finder") { reveal() }
                        .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Spacer()
                Text("WindowKeeper \(AppInfo.displayVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin.refresh() }
    }

    private var intervalValue: Binding<Int> {
        Binding(get: { settings.autoSaveValue }, set: { settings.autoSaveValue = max(1, $0) })
    }

    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("WindowKeeper needs Accessibility access")
                    .font(.system(size: 13, weight: .semibold))
                caption("Without it, it cannot see or move other apps’ windows, and nothing is saved or restored.")
                Button("Open Accessibility Settings") {
                    AXWindows.requestTrust()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cloudDescription: String {
        switch store.cloudState {
        case .unknown, .synced:
            "Profiles are kept on this Mac and copied to iCloud Drive › WindowKeeper, in a folder for this Mac only. Other Macs on your account keep their own."
        case .unavailable:
            "iCloud Drive is off, so profiles are kept on this Mac only."
        case .failed(let message):
            "Could not copy profiles to iCloud Drive: \(message). They are still saved on this Mac."
        }
    }

    private func reveal() {
        let cloud = store.cloudFolderURL.appending(path: "profiles.json")
        let target = FileManager.default.fileExists(atPath: cloud.path) ? cloud : ProfileStore.localURL
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func shortcutRow(_ label: String, _ binding: Binding<HotKey?>) -> some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutRecorder(hotKey: binding)
                .fixedSize()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
