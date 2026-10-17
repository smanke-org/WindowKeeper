import SwiftUI

/// The iCloud settings sync and update choices, laid out for a plain (non-Form) Settings view.
struct SyncUpdateControls: View {
    @ObservedObject private var sync = SettingsSync.shared
    @ObservedObject private var updater = AutoUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
            if sync.isEnabled {
                HStack {
                    Group {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == (Host.current().localizedName ?? "") ? "" : " from \($0)" } ?? "")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Waiting for iCloud Drive…").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }.controlSize(.small)
                }
                .font(.caption)
            }
            Text("Auto-save, restore options, keyboard shortcuts and where WindowKeeper appears follow you to every Mac signed in to the same iCloud account with sync turned on. Window profiles stay with each Mac's monitors.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("When an update is available:", selection: $updater.policy) {
                ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .padding(.top, 6)
            if updater.policy != .off {
                UpdateIntervalPicker(interval: $updater.interval, label: "Check every:")
            }
            if let staged = updater.staged {
                HStack {
                    Text("Version \(staged.version) is ready.").font(.caption)
                    Spacer()
                    Button("Install Now") { updater.installNow() }.controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Check Now") { UpdateController.checkForUpdates() }.controlSize(.small)
            }
            if let error = updater.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if updater.policy != .off && !updater.notificationsAllowed {
                HStack(alignment: .top) {
                    Label("Notifications are off for WindowKeeper, so update news only shows in the menu.", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }.controlSize(.small)
                }
            }
            Text(updateFooter)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { updater.refreshNotificationStatus() }
    }

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            return "WindowKeeper checks \(updater.interval.phrase). A new version installs itself when windows aren't being restored, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            return "WindowKeeper checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            return "WindowKeeper won't look for updates on its own. Use Check Now whenever you like."
        }
    }
}
