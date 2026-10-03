import AppKit
import SwiftUI
import WindowKeeperKit

/// Lists the saved monitor profiles: rename, restore, delete, and import from another Mac.
struct ProfilesView: View {
    let store: ProfileStore
    let keeper: Keeper
    /// A profile to call attention to — a new desk the user was just told about.
    var highlight: UUID?

    @State private var pendingDelete: MonitorProfile?
    @State private var showingImport = false

    private var profiles: [MonitorProfile] {
        store.library.profiles.sorted { a, b in
            if (a.id == keeper.currentProfileID) != (b.id == keeper.currentProfileID) { return a.id == keeper.currentProfileID }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile, store: store, keeper: keeper,
                                   isCurrent: profile.id == keeper.currentProfileID,
                                   isHighlighted: profile.id == highlight,
                                   onDelete: { pendingDelete = profile })
                    }
                    if profiles.isEmpty {
                        Text("No monitor profiles yet. One is created for whatever monitors are connected.")
                            .foregroundStyle(.secondary)
                            .padding(30)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("A profile is created the first time a set of monitors is connected. Rename it to the desk it belongs to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Import from Another Mac…") { showingImport = true }
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .sheet(isPresented: $showingImport) {
            ImportView(store: store, keeper: keeper) { showingImport = false }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete Profile", role: .destructive) {
                if let profile = pendingDelete { store.delete(profile.id) }
                pendingDelete = nil
            }
        } message: {
            Text("Its saved window positions are removed from this Mac and from iCloud. If these monitors are connected again, a new empty profile is created.")
        }
    }
}

private struct ProfileRow: View {
    let profile: MonitorProfile
    let store: ProfileStore
    let keeper: Keeper
    let isCurrent: Bool
    let isHighlighted: Bool
    let onDelete: () -> Void

    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, now in if !now { commit() } }
                if isCurrent {
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button {
                    keeper.setLocked(!profile.isLocked, profileID: profile.id)
                } label: {
                    Image(systemName: profile.isLocked ? "lock.fill" : "lock.open")
                }
                .help(profile.isLocked
                      ? "Locked: auto-save leaves this layout alone. Save Now still updates it. Click to unlock."
                      : "Lock this layout so auto-save never changes it.")
                Button("Restore") { keeper.restore(.all, from: profile) }
                    .disabled(profile.windows.isEmpty && profile.icons.isEmpty)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete this profile")
            }
            Text(profile.displays.sorted { $0.bounds.x < $1.bounds.x }.map(displayLabel).joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            name = profile.name
            if isHighlighted { editing = true }
        }
        .onChange(of: profile.name) { _, new in if !editing { name = new } }
    }

    private func commit() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = profile.name; return }
        store.rename(profile.id, to: name)
    }

    /// Name plus the end of the serial, so two monitors of the same model can be told apart.
    private func displayLabel(_ d: DisplayRecord) -> String {
        if d.isBuiltin { return "Built-in display" }
        if d.key.hasPrefix("sn:"), let serial = d.key.split(separator: "-").last {
            return "\(d.name) (…\(serial.suffix(4)))"
        }
        return d.name
    }

    private var details: String {
        var parts = ["\(profile.windows.count) window(s)", "\(profile.icons.count) desktop icon(s)"]
        if profile.isLocked { parts.append("locked") }
        if let saved = profile.lastSaved {
            parts.append("last changed \(saved.formatted(.relative(presentation: .named)))")
        }
        if let from = profile.importedFrom { parts.append("imported from \(from)") }
        return parts.joined(separator: " · ")
    }
}

/// Profiles saved by the user's other Macs, read from their iCloud folders.
private struct ImportView: View {
    let store: ProfileStore
    let keeper: Keeper
    let done: () -> Void

    @State private var macs: [RemoteLibrary]?
    @State private var pending: (MonitorProfile, String)?
    @State private var imported: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Another Mac").font(.headline)
            Text("Copies a profile’s window positions to this Mac. Apps not installed here are skipped when restoring.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let macs {
                    if macs.isEmpty {
                        Text("No other Mac on this iCloud account has saved profiles yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(macs) { mac in
                                Section(mac.library.machineName) {
                                    ForEach(mac.library.profiles) { profile in
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(profile.name)
                                                Text("\(profile.windows.count) window(s)").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button("Import") { pending = (profile, mac.library.machineName) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Reading iCloud Drive…") }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)

            HStack {
                if let imported { Text(imported).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 400)
        .task { macs = await store.otherMacs() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(replaces ? "Replace Windows" : "Import") {
                if let (profile, from) = pending {
                    let result = store.importProfile(profile, from: from)
                    imported = "Imported into “\(result.name)”."
                }
                pending = nil
            }
        } message: {
            Text(replaces
                 ? "This Mac already has a profile for the same monitors. Its saved windows will be replaced with the ones from the other Mac."
                 : "It is added as a new profile, used whenever this Mac is connected to the same monitors.")
        }
    }

    private var replaces: Bool {
        guard let (profile, _) = pending else { return false }
        return store.library.profile(withSignature: profile.signature) != nil
    }

    private var confirmTitle: String { "Import “\(pending?.0.name ?? "")”?" }
}
