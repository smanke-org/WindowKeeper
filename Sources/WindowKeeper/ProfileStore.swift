import Foundation
import IOKit
import Observation
import WindowKeeperKit

/// Another Mac's saved profiles, read from its iCloud folder.
struct RemoteLibrary: Identifiable, Sendable {
    var id: String { library.machineID }
    let library: ProfileLibrary
}

/// Owns the saved profiles: a local file that is always the working copy, mirrored to
/// this Mac's own folder in iCloud Drive.
///
/// Each Mac writes only `iCloud Drive/WindowKeeper/Macs/<hardware UUID>/profiles.json`, so
/// two Macs never write the same file and there is nothing to merge or conflict. Another
/// Mac's folder is only ever read, by "Import from Another Mac".
///
/// iCloud I/O runs off the main thread: the first access can raise a privacy prompt, and a
/// call waiting on an unanswered prompt must not freeze the menu.
@Observable
@MainActor
final class ProfileStore {
    enum CloudState: Equatable {
        case unknown
        case synced(Date)
        /// iCloud Drive is off or signed out: profiles are kept on this Mac only.
        case unavailable
        case failed(String)
    }

    private(set) var library: ProfileLibrary
    private(set) var cloudState: CloudState = .unknown

    @ObservationIgnored let machineID: String
    @ObservationIgnored private var lastWritten: Data?
    @ObservationIgnored private var cloudWrite: DispatchWorkItem?
    private static let ioQueue = DispatchQueue(label: "WindowKeeper.cloud", qos: .utility)

    nonisolated static let localURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "WindowKeeper/profiles.json")
    }()

    nonisolated static let cloudDriveURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

    nonisolated static let cloudRootURL = cloudDriveURL.appending(path: "WindowKeeper/Macs", directoryHint: .isDirectory)

    nonisolated var cloudFolderURL: URL { Self.cloudRootURL.appending(path: machineID, directoryHint: .isDirectory) }

    init() {
        machineID = Self.hardwareUUID()
        let name = Host.current().localizedName ?? "This Mac"
        if let data = try? Data(contentsOf: Self.localURL),
           var loaded = try? Self.decoder.decode(ProfileLibrary.self, from: data) {
            loaded.machineName = name
            library = loaded
            lastWritten = data
        } else {
            library = ProfileLibrary(machineID: machineID, machineName: name)
        }
    }

    /// After a reinstall or on a replacement Mac with the same hardware UUID, the local file
    /// is gone but this Mac's iCloud copy is not. Adopt it if nothing has been saved here.
    func recoverFromCloudIfEmpty(then completion: @escaping @MainActor () -> Void) {
        guard library.profiles.allSatisfy(\.windows.isEmpty) else { return }
        let url = cloudFolderURL.appending(path: "profiles.json")
        Self.ioQueue.async {
            let data = Self.coordinatedRead(url)
            Task { @MainActor in
                // Only a copy with saved windows is worth adopting; an empty one is just
                // this Mac's own first run echoed back, and adopting it re-ran the launch restore.
                guard let data, let cloud = try? Self.decoder.decode(ProfileLibrary.self, from: data),
                      cloud.profiles.contains(where: { !$0.windows.isEmpty }),
                      self.library.profiles.allSatisfy(\.windows.isEmpty)
                else { return }
                Diagnostics.note("recovered \(cloud.profiles.count) profile(s) from iCloud")
                self.library.profiles = cloud.profiles
                self.persist()
                completion()
            }
        }
    }

    // MARK: - Editing

    func profile(id: UUID?) -> MonitorProfile? {
        guard let id else { return nil }
        return library.profiles.first { $0.id == id }
    }

    func add(_ profile: MonitorProfile) {
        library.profiles.append(profile)
        persist()
    }

    func update(_ profile: MonitorProfile) {
        guard let i = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard library.profiles[i] != profile else { return }
        library.profiles[i] = profile
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var profile = profile(id: id) else { return }
        profile.name = trimmed
        update(profile)
    }

    func delete(_ id: UUID) {
        library.profiles.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Saving

    private nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes only when something actually changed, so auto-save running every few seconds
    /// over an unchanged layout costs no disk writes and no iCloud traffic.
    private func persist() {
        guard let data = try? Self.encoder.encode(library), data != lastWritten else { return }
        do {
            try FileManager.default.createDirectory(at: Self.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.localURL, options: .atomic)
            lastWritten = data
        } catch {
            Diagnostics.note("could not write \(Self.localURL.path): \(error.localizedDescription)")
            return
        }
        scheduleCloudWrite(data)
    }

    /// Batched: a burst of edits becomes one upload.
    private func scheduleCloudWrite(_ data: Data) {
        cloudWrite?.cancel()
        let folder = cloudFolderURL
        let work = DispatchWorkItem {
            Self.ioQueue.async {
                let result = Self.writeToCloud(data, folder: folder)
                Task { @MainActor in self.cloudState = result }
            }
        }
        cloudWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    nonisolated private static func writeToCloud(_ data: Data, folder: URL) -> CloudState {
        guard FileManager.default.fileExists(atPath: cloudDriveURL.path) else { return .unavailable }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "profiles.json")
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
            return .synced(Date())
        } catch {
            Diagnostics.note("iCloud write failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Coordinated, so a file iCloud has evicted to save space is downloaded first.
    nonisolated private static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    // MARK: - Other Macs

    /// Every other Mac's library in iCloud Drive. Slow if files must download — call off the menu path.
    func otherMacs() async -> [RemoteLibrary] {
        let root = Self.cloudRootURL
        let mine = machineID
        return await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                let libraries = folders
                    .filter { $0.lastPathComponent != mine }
                    .compactMap { Self.coordinatedRead($0.appending(path: "profiles.json")) }
                    .compactMap { try? Self.decoder.decode(ProfileLibrary.self, from: $0) }
                    .filter { !$0.profiles.isEmpty }
                    .map(RemoteLibrary.init)
                continuation.resume(returning: libraries.sorted { $0.library.machineName < $1.library.machineName })
            }
        }
    }

    /// Copies another Mac's profile here. A profile for the same monitors replaces the
    /// local one's windows (keeping its name); otherwise it is added, and becomes active
    /// whenever this Mac is connected to those monitors.
    @discardableResult
    func importProfile(_ remote: MonitorProfile, from machineName: String) -> MonitorProfile {
        if var existing = library.profile(withSignature: remote.signature) {
            existing.windows = remote.windows
            existing.lastSaved = Date()
            existing.importedFrom = machineName
            update(existing)
            return existing
        }
        var copy = remote
        copy.id = UUID()
        copy.name = library.uniqueName(remote.name)
        copy.importedFrom = machineName
        add(copy)
        return copy
    }

    // MARK: - Identity

    /// The hardware UUID: stable for the life of the Mac, unique per Mac, and the same
    /// after a reinstall — which is what lets a reinstall find its iCloud copy.
    private static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String ?? "unknown-mac"
    }
}
