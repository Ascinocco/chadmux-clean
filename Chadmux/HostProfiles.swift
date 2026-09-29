import Foundation
import SwiftUI
import Combine
import Citadel

/// A saved SSH host. `connection` is the endpoint identity: host-key trust,
/// the transcription token, recovery archives and resume permission are all
/// keyed by it, and it is unchanged from the single saved Mac connection it
/// replaces, so migrating needs no re-pairing and keeps every draft.
struct HostProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var connection: MacConnection
    var defaultFolder = "~"

    static let maximumHosts = 8

    /// The first host offered: this Mac itself on macOS (over its own SSH, i.e.
    /// Remote Login), or "Mac" to fill in on iOS.
    static var firstHostSuggestion: HostProfile {
        #if os(macOS)
        HostProfile(label: "This Mac", connection: MacConnection(host: "localhost", port: 22, username: NSUserName()))
        #else
        HostProfile(label: "Mac", connection: MacConnection())
        #endif
    }
    static func isThisMac(_ host: String) -> Bool {
        #if os(macOS)
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) || host.lowercased() == ProcessInfo.processInfo.hostName.lowercased()
        #else
        false
        #endif
    }

    var problem: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 32 || trimmed != label || Self.hasControl(label) { return "Enter a label of up to 32 characters." }
        if !connection.isValid { return "Enter a host, username and port between 1 and 65535." }
        if defaultFolder.isEmpty || defaultFolder.count > 1024 || Self.hasControl(defaultFolder) { return "Enter a default folder, such as ~ or ~/Projects." }
        return nil
    }
    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}

/// The saved host list, in UserDefaults like the connection it replaces.
struct HostStore {
    static let key = "host-profiles"
    static let legacyKey = "mac-connection"
    let preferences: UserDefaults

    /// The saved hosts, or on first run after upgrading, the single legacy
    /// connection as "Mac". The legacy value is left in place untouched.
    func load() -> (hosts: [HostProfile], migrated: Bool) {
        if let data = preferences.data(forKey: Self.key),
           let hosts = try? JSONDecoder().decode([HostProfile].self, from: data),
           (try? Self.validate(hosts)) != nil {
            return (hosts, false)
        }
        guard let data = preferences.data(forKey: Self.legacyKey),
              let legacy = try? JSONDecoder().decode(MacConnection.self, from: data), legacy.isValid else { return ([], false) }
        return ([HostProfile(label: "Mac", connection: legacy)], true)
    }
    func save(_ hosts: [HostProfile]) throws {
        try Self.validate(hosts)
        preferences.set(try JSONEncoder().encode(hosts), forKey: Self.key)
        // Flush now: a host edit must survive the app being killed straight after.
        preferences.synchronize()
    }
    static func validate(_ hosts: [HostProfile]) throws {
        guard hosts.count <= HostProfile.maximumHosts,
              hosts.allSatisfy({ $0.problem == nil }),
              Set(hosts.map(\.id)).count == hosts.count,
              Set(hosts.map { $0.label.lowercased() }).count == hosts.count,
              Set(hosts.map(\.connection.recoveryIdentity)).count == hosts.count else { throw InvalidHosts() }
    }
    struct InvalidHosts: Error {}
}

extension MacConnection {
    /// Two profiles for the same user on the same host would share one archive.
    var recoveryIdentity: String { trustID + "|" + username }
}

/// Every saved host and its live workspace. Each host keeps its own SSH
/// connection, sessions, tabs, drafts and resume state, so one unreachable
/// host never blocks another. The microphone is shared: one recording at a time.
@MainActor
final class HostsModel: ObservableObject {
    @Published private(set) var hosts: [HostProfile]
    /// The host whose tab is on screen; remembered across launches.
    @Published var selectedHostID: UUID? { didSet { preferences.set(selectedHostID?.uuidString, forKey: "selected-host") } }
    /// One sidebar for every host. Each host's archive still records it.
    @Published var sidebarExpanded = false { didSet { for workspace in workspaces.values where workspace.sidebarExpanded != sidebarExpanded { workspace.sidebarExpanded = sidebarExpanded } } }
    private var changes: [UUID: AnyCancellable] = [:]
    /// The host whose companion server transcribes dictation from every tab (default: the first host).
    @Published var dictationHostID: UUID? { didSet { preferences.set(dictationHostID?.uuidString, forKey: "dictation-host") } }
    /// The companion server API port on the dictation host's loopback.
    var dictationPort = 8420
    @Published private(set) var workspaces: [UUID: SessionWorkspace] = [:]
    @Published var publicKey = ""
    let voice: VoiceCoordinator
    let secrets: SecretStore
    let preferences: UserDefaults
    let media: MediaStore
    private let store: HostStore?
    private let makeWorkspace: (HostProfile, HostsModel) -> SessionWorkspace

    init(preferences: UserDefaults, secrets: SecretStore = SecretStore(), recovery: RecoveryStore? = RecoveryStore(),
         media: MediaStore = MediaStore(), voice: VoiceCoordinator? = nil,
         makeWorkspace: ((HostProfile, HostsModel) -> SessionWorkspace)? = nil) {
        self.preferences = preferences; self.secrets = secrets; self.media = media; self.voice = voice ?? VoiceCoordinator()
        let store = HostStore(preferences: preferences)
        self.store = store
        let loaded = store.load()
        hosts = loaded.hosts
        self.makeWorkspace = makeWorkspace ?? { host, model in
            SessionWorkspace(connection: MacTransport(preferences: model.preferences, secrets: model.secrets, profile: host.connection),
                             recovery: recovery, media: model.media, voice: model.voice)
        }
        if loaded.migrated { try? store.save(hosts) }
        for host in hosts { attach(host) }
        let remembered = preferences.string(forKey: "selected-host").flatMap(UUID.init(uuidString:))
        selectedHostID = hosts.contains(where: { $0.id == remembered }) ? remembered : hosts.first?.id
        sidebarExpanded = workspaces.values.contains { $0.sidebarExpanded }
        dictationHostID = preferences.string(forKey: "dictation-host").flatMap(UUID.init(uuidString:)).flatMap { id in hosts.contains { $0.id == id } ? id : nil }
        loadPublicKey()
        routeDictation()
    }

    /// A fixed, unsaved host list around existing workspaces (UI fixtures).
    init(fixture workspaces: [(label: String, workspace: SessionWorkspace)]) {
        preferences = workspaces.first?.workspace.connection.preferences ?? .standard
        secrets = workspaces.first?.workspace.connection.secrets ?? SecretStore()
        media = workspaces.first?.workspace.media ?? MediaStore()
        voice = workspaces.first?.workspace.voice ?? VoiceCoordinator()
        store = nil
        makeWorkspace = { _, _ in preconditionFailure("fixture hosts are fixed") }
        hosts = workspaces.map { HostProfile(label: $0.label, connection: $0.workspace.connection.profile) }
        for (host, entry) in zip(hosts, workspaces) {
            entry.workspace.hostLabel = host.label
            entry.workspace.tabLimitReached = { [weak self] in (self?.totalTabs ?? 0) >= 8 }
            self.workspaces[host.id] = entry.workspace
            observe(host.id, entry.workspace)
        }
        selectedHostID = hosts.first?.id
        sidebarExpanded = self.workspaces.values.contains { $0.sidebarExpanded }
        loadPublicKey()
        routeDictation()
    }

    var orderedWorkspaces: [(host: HostProfile, workspace: SessionWorkspace)] {
        hosts.compactMap { host in workspaces[host.id].map { (host, $0) } }
    }
    var selectedHost: HostProfile? { hosts.first { $0.id == selectedHostID } }
    var selectedWorkspace: SessionWorkspace? { selectedHostID.flatMap { workspaces[$0] } }
    func workspace(for id: UUID) -> SessionWorkspace? { workspaces[id] }
    func host(_ id: UUID) -> HostProfile? { hosts.first { $0.id == id } }

    var dictationHost: HostProfile? { dictationHostID.flatMap(host) ?? hosts.first }

    private func routeDictation() {
        voice.route = { [weak self] tab in self?.dictationRoute(for: tab) ?? .unavailable("Dictation is unavailable. Try again.") }
    }
    /// Checks the dictation host is usable before recording starts, then sends
    /// the audio over its live connection, or a pinned one opened for this
    /// request only. Only /transcriptions on its loopback is ever reached.
    func dictationRoute(for tab: SessionTab) -> VoiceCoordinator.Route {
        guard let host = dictationHost, let workspace = workspaces[host.id] else {
            return .unavailable("Add a host in Connection settings to use dictation.")
        }
        let token: String
        do {
            guard let data = try secrets.read(host.connection.apiTokenID), let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                return .unavailable("Add the transcription token for \(host.label) in Connection settings first.")
            }
            token = value
            guard try secrets.read(host.connection.trustID) != nil else {
                return .unavailable("Connect to \(host.label) once to verify its host key, then record again.")
            }
        } catch { return .unavailable("Unlock your device to read the transcription settings, then try again.") }
        let port = dictationPort, target = host.connection, secrets = secrets
        return .ready { [weak workspace] audio in
            if let transport = workspace?.connection, transport.connected, let client = transport.client {
                return try await LoopbackAPI.transcribe(client: client, recording: audio, token: token, port: port).text
            }
            let client = try await SSHClient.connect(to: try MacTransport.pinnedSettings(for: target, secrets: secrets))
            do {
                let reply = try await LoopbackAPI.transcribe(client: client, recording: audio, token: token, port: port)
                try? await client.close()
                return reply.text
            } catch {
                try? await client.close()
                throw error
            }
        }
    }

    /// Opens (or switches to) a session on a host and puts that host on screen.
    func select(_ session: RemoteSession, on hostID: UUID) {
        guard let workspace = workspaces[hostID] else { return }
        selectedHostID = hostID
        workspace.select(session)
    }
    /// A host waiting for its host key to be verified, whichever is on screen.
    var verifying: (host: HostProfile, workspace: SessionWorkspace)? {
        orderedWorkspaces.first { $0.workspace.verificationTransport != nil }
    }

    /// Tabs across every host count towards the one eight-tab limit.
    var totalTabs: Int { workspaces.values.reduce(0) { $0 + $1.tabs.count } }

    func add(_ host: HostProfile) throws {
        try persist(hosts + [host])
        attach(host)
        if selectedHostID == nil { selectedHostID = host.id }
    }

    /// Label and default folder can always change. The endpoint cannot change
    /// while that host has open tabs, as with the single connection before.
    func update(_ host: HostProfile) throws {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }), let workspace = workspaces[host.id] else { throw HostStore.InvalidHosts() }
        let previous = hosts[index]
        if previous.connection != host.connection && !workspace.tabs.isEmpty { throw TabsOpen() }
        var updated = hosts; updated[index] = host
        try persist(updated)
        workspace.hostLabel = host.label; workspace.defaultFolder = host.defaultFolder
        if previous.connection != host.connection { workspace.connection.profile = host.connection }
    }

    /// Removes a host, closing its tabs (the caller confirms losing their drafts)
    /// and forgetting its trust and token unless another host shares them.
    func remove(_ id: UUID) throws {
        guard let host = host(id), let workspace = workspaces[id] else { return }
        let remaining = hosts.filter { $0.id != id }
        try persist(remaining)
        for tab in workspace.tabs { workspace.close(tab.id) }
        workspace.disconnect()
        workspaces[id] = nil; changes[id] = nil
        if !remaining.contains(where: { $0.connection.trustID == host.connection.trustID }) {
            try? secrets.remove(host.connection.trustID)
            try? secrets.remove(host.connection.apiTokenID)
        }
        if selectedHostID == id { selectedHostID = remaining.first?.id }
        if dictationHostID == id { dictationHostID = nil }
    }

    /// Whether the app is in the foreground, so a host added now (in settings)
    /// can connect at once rather than after the next activation.
    private var active = false
    func becameActive() { active = true; for workspace in workspaces.values { workspace.becameActive() } }
    func background() { active = false; for workspace in workspaces.values { workspace.background() } }
    func restoreProtectedWorkspaces() { for workspace in workspaces.values { workspace.restoreProtectedWorkspaceIfNeeded() } }

    private func persist(_ updated: [HostProfile]) throws {
        try HostStore.validate(updated)
        try store?.save(updated)
        hosts = updated
    }
    private func attach(_ host: HostProfile) {
        let workspace = makeWorkspace(host, self)
        workspace.hostLabel = host.label; workspace.defaultFolder = host.defaultFolder
        workspace.tabLimitReached = { [weak self] in (self?.totalTabs ?? 0) >= 8 }
        workspace.sidebarExpanded = sidebarExpanded || workspace.sidebarExpanded
        workspaces[host.id] = workspace
        observe(host.id, workspace)
        if active { workspace.becameActive() }
    }
    /// Views reading several hosts (the sidebar, verification) follow every workspace.
    private func observe(_ id: UUID, _ workspace: SessionWorkspace) {
        changes[id] = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Either side may open or close the one sidebar; each only writes on a change.
        workspace.sidebarChanged = { [weak self] expanded in
            if let self, self.sidebarExpanded != expanded { self.sidebarExpanded = expanded }
        }
    }
    private func loadPublicKey() {
        do { publicKey = SSHPrimitives.authorizedKey(try secrets.deviceKey()) }
        catch { publicKey = "" }
    }
    struct TabsOpen: Error {}
}
