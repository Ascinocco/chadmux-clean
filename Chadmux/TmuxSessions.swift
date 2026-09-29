import Foundation
#if os(iOS)
import UIKit
#endif
import Citadel

struct RemoteSession: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    var instance: String = ""
}

struct DraftAttachment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let filename: String
    var mediaType = "image/jpeg"
}

enum TmuxSessions {
    // SSH exec does not load the interactive Homebrew shell configuration.
    static let command = "/usr/bin/env LC_ALL=en_US.UTF-8 PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin tmux -u"
    static func announcedPID(in output: String, marker: String) -> String? {
        guard let start = output.range(of: "\u{1e}" + marker + ":"),
              let end = output[start.upperBound...].firstIndex(of: "\u{1f}") else { return nil }
        let pid = String(output[start.upperBound..<end])
        guard !pid.isEmpty, pid.count <= 12, pid.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return pid
    }
    static func validID(_ id: String) -> Bool {
        id.first == "$" && id.count > 1 && id.count <= 20 && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
    static func parseIDs(_ output: String) throws -> [String] {
        let ids = output.split(separator: "\n").map(String.init)
        guard ids.count <= 128, ids.allSatisfy(validID), Set(ids).count == ids.count else { throw InvalidListing() }
        return ids
    }
    static func list(using client: SSHClient, command: String = command) async throws -> [RemoteSession] {
        let output = try await client.executeCommand(command + " list-sessions -F '#{session_id}'", maxResponseSize: 8192)
        let ids = try parseIDs(String(buffer: output))
        var sessions: [RemoteSession] = []
        for id in ids {
            let target = command + " display-message -p -t " + SSHPrimitives.shellQuote(id)
            let instance = try await readInstance(using: client, id: id, command: command)
            let name = try await client.executeCommand(target + " '#{session_name}'", maxResponseSize: 8192)
            var text = String(buffer: name)
            if text.hasSuffix("\n") { text.removeLast() }
            sessions.append(RemoteSession(id: id, name: text, instance: instance))
        }
        return sessions
    }
    static func readInstance(using client: SSHClient, id: String, command: String) async throws -> String {
        guard validID(id) else { throw InvalidListing() }
        let result = try await client.executeCommand(command + " display-message -p -t " + SSHPrimitives.shellQuote(id) + " '#{pid}:#{session_created}'", maxResponseSize: 128)
        let instance = String(buffer: result).trimmingCharacters(in: .newlines)
        let parts = instance.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { throw InvalidListing() }
        return instance
    }
    struct InvalidListing: Error {}

    /// What the sidebar shows under a session's name. Best effort and display
    /// only: nothing is decided from it, and a failure leaves it blank.
    struct Context: Equatable {
        var path: String
        var clients: Int
        var activity: Date?
    }
    static func parseContext(_ output: String) -> Context? {
        let fields = output.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let clients = Int(fields[0]), clients >= 0, clients < 1000 else { return nil }
        let activity = TimeInterval(fields[1]).map { Date(timeIntervalSince1970: $0) }
        let path = String(fields[2].prefix(1024))
        // Tabs are legal in folder names; escapes and other controls never reach the sidebar.
        guard !path.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 && $0 != 9 } == true }) else { return nil }
        return Context(path: path, clients: clients, activity: activity)
    }
    static func context(using client: SSHClient, id: String, command: String = command) async -> Context? {
        guard validID(id) else { return nil }
        let format = "'#{session_attached}\t#{session_activity}\t#{pane_current_path}'"
        guard let output = try? await client.executeCommand(command + " display-message -p -t " + SSHPrimitives.shellQuote(id) + " " + format, maxResponseSize: 2048) else { return nil }
        return parseContext(String(buffer: output))
    }
    /// A path with the home folder shown as ~.
    static func displayPath(_ path: String, user: String) -> String {
        for home in ["/Users/" + user, "/home/" + user, user == "root" ? "/root" : nil].compactMap({ $0 }) where !user.isEmpty {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }
}

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    let id: String
    var name: String { session.name }
    @Published var session: RemoteSession
    let transport: MacTransport
    let media: MediaStore
    var closed = false
    var persist: (() throws -> Void)?
    var suppressCheckpoint = false
    var writeInFlight = false
    @Published var persistenceError: String?
    var submissionTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    @Published var thumbnails: [UUID: PlatformImage] = [:]
    @Published var preparing = false
    @Published var importing = false
    @Published var mediaError: String?
    @Published var sending = false
    @Published var deliveryUncertain = false { didSet { checkpoint() } }
    @Published var submissionMessage: String?
    @Published var dictationStatus: String?
    @Published var pendingTranscript: String? { didSet { checkpoint() } }
    @Published var draft = "" { didSet { checkpoint() } }
    @Published var attachments: [DraftAttachment] = [] { didSet { checkpoint() } }
    init(session: RemoteSession, profile: MacConnection, secrets: SecretStore, media: MediaStore = MediaStore()) {
        self.media = media
        id = session.id; self.session = session
        transport = MacTransport(secrets: secrets)
        transport.profile = profile
    }
}

/// Whether files and Keychain items protected until first unlock are readable.
/// macOS has no per-file protection classes: the disk is protected at rest.
enum ProtectedData {
    @MainActor static func isAvailable() -> Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}

enum ResumeState: String {
    case idle = "Disconnected", reconnecting = "Reconnecting…", discovering = "Finding sessions…"
    case attaching = "Attaching…", ready = "Connected", unavailable = "Reconnect needed"
}
@MainActor
struct ResumeOperations {
    var connect: (MacTransport) async throws -> Void
    var list: (MacTransport,String) async throws -> [RemoteSession]
    var attach: (SessionTab,String) async throws -> Void
    static var live: ResumeOperations {
        ResumeOperations(connect: { try await $0.connectAndWait(openShell:false) }, list: { connection,command in
            guard let client = connection.client, connection.connected else { throw ConnectionFailure.network }
            return try await TmuxSessions.list(using:client,command:command)
        }, attach: { tab,command in
            try await tab.transport.connectAndWait(sessionID:tab.id,expectedInstance:tab.session.instance,tmuxCommand:command)
        })
    }
}

@MainActor
final class SessionWorkspace: ObservableObject {
    let connection: MacTransport
    /// Shared by every host's workspace: there is one microphone.
    let voice: VoiceCoordinator
    @Published var hostLabel = "Mac"
    /// Offered for a new session until one is created in another folder here.
    var defaultFolder = "~"
    /// The app-wide tab limit across hosts; alone, a workspace allows eight.
    var tabLimitReached: (() -> Bool)?
    private var atTabLimit: Bool { tabLimitReached?() ?? (tabs.count >= 8) }
    let recovery: RecoveryStore?
    let media: MediaStore
    private var restoring = false
    private var foreground = false
    private var activationAttempted = false
    private var resumeGeneration = UUID()
    private var resumeTask: Task<Void,Never>?
    private var resumeDeadline: Task<Void,Never>?
    private var resumeAllowsSelected = false
    private let resumeOperations: ResumeOperations
    private let resumeTimeout: TimeInterval
    private let resumeRetryDelay: TimeInterval
    @Published var resumeState = ResumeState.idle
    @Published var verificationTransport: MacTransport?
    private var recoveryReadable = true
    private var restoreDeferred = false
    let protectedDataAvailable: () -> Bool
    private(set) var resumeDesired = false
    private(set) var resumeSessions: [RemoteSession] = []
    var resumePermission: ResumePermission { ResumePermission(preferences:connection.preferences) }
    @Published var sidebarExpanded = false { didSet { checkpointWorkspace(); sidebarChanged?(sidebarExpanded) } }
    /// Tells the app-wide sidebar (HostsModel) when this workspace opens or closes it.
    var sidebarChanged: ((Bool) -> Void)?
    @Published var recoveryError: String?
    let tmuxCommand: String
    let claudeTmux: ClaudeTmux
    @Published var creatingSession = false
    #if DEBUG
    @Published var fixtureEvidence = ""
    #endif
    @Published var endingSessionID: String?
    @Published var renamingSessionID: String?
    /// Where the Mac's terminal image uploads go on the host (PhotoUpload's
    /// default); disposable UI fixtures point it at a private directory.
    var uploadRoot = ".chadmux/uploads"
    @Published var sessions: [RemoteSession] = []
    @Published var tabs: [SessionTab] = [] { didSet {
        for tab in tabs { tab.persist = { [weak self] in try self?.saveRecovery() } }
        checkpointWorkspace()
    } }
    @Published var selectedID: String? { didSet { checkpointWorkspace() } }
    @Published var refreshing = false
    @Published var error: String?
    /// Folder, attached clients and last activity per session id, for the sidebar.
    @Published var sessionContext: [String: TmuxSessions.Context] = [:]
    private var contextTask: Task<Void, Never>?
    var sidebarSessions: [RemoteSession] { tabs.map(\.session) + sessions.filter { remote in !tabs.contains { $0.id == remote.id } } }
    var selected: SessionTab? { tabs.first { $0.id == selectedID } }
    init(connection: MacTransport? = nil, tmuxCommand: String = TmuxSessions.command,
         claudeTmux: ClaudeTmux = ClaudeTmux(), recovery: RecoveryStore? = nil, media: MediaStore = MediaStore(),
         voice: VoiceCoordinator? = nil,
         protectedDataAvailable: @escaping () -> Bool = ProtectedData.isAvailable,
         resumeOperations: ResumeOperations? = nil, resumeTimeout: TimeInterval = 30, resumeRetryDelay: TimeInterval = 2) {
        self.connection = connection ?? MacTransport(); self.tmuxCommand = tmuxCommand; self.claudeTmux = claudeTmux
        self.recovery = recovery; self.media = media; self.voice = voice ?? VoiceCoordinator(); self.protectedDataAvailable = protectedDataAvailable
        self.resumeOperations = resumeOperations ?? .live
        self.resumeTimeout = resumeTimeout; self.resumeRetryDelay = resumeRetryDelay
        self.connection.onProfileChanged = { [weak self] previous in self?.profileChanged(previous) }
        self.connection.onConnectionLost = { [weak self] in
            guard let self else { return }
            for tab in self.tabs { tab.transport.disconnect() }
            if self.resumeTask == nil { self.resumeState = .unavailable }
        }
        restore()
    }
    private func restore() {
        guard let recovery else { return }
        guard protectedDataAvailable() else {
            restoreDeferred = true; recoveryReadable = false
            recoveryError = "Unlock your phone to restore your workspace."
            return
        }
        restoreDeferred = false; recoveryReadable = true
        restoring = true
        defer { restoring = false }
        do {
            if let saved = try recovery.load(profile: connection.profile) {
                tabs = saved.tabs.map { value in
                    let tab = SessionTab(session: value.session, profile: saved.profile, secrets: connection.secrets, media: media)
                    tab.apply(value)
                    tab.deliveryUncertain = value.deliveryUncertain || value.writeInFlight
                    tab.writeInFlight = false
                    tab.transport.status = "Restored offline"
                    if tab.deliveryUncertain { tab.submissionMessage = "Delivery may have completed before Chadmux stopped. Inspect the terminal before choosing to send again." }
                    if tab.attachments.contains(where: { (try? media.data(for: $0)) == nil }) {
                        tab.mediaError = "An attached image is missing or locked. Unlock the phone, or remove and choose that image again. Nothing will send until every image is available."
                    }
                    for image in tab.attachments { tab.thumbnails[image.id] = media.thumbnail(image) }
                    return tab
                }
                sidebarExpanded = saved.sidebarExpanded ?? false
                resumeDesired = saved.version == 2 && saved.resume?.desired == true && resumePermission.allows(saved.profile)
                resumeSessions = resumeDesired ? saved.resume?.sessions ?? [] : []
                selectedID = tabs.contains(where: { $0.id == saved.selectedID }) ? saved.selectedID : tabs.first?.id
            }
            recoveryError = nil
        } catch {
            recoveryReadable = false
            recoveryError = "Draft recovery could not be read. Existing files were retained. Unlock the phone/check free space and relaunch before sending; keep any new edits safe."
        }
    }
    func saveRecovery(tabs selectedTabs: [SessionTab]? = nil) throws {
        guard let recovery, !restoring else { return }
        guard recoveryReadable, protectedDataAvailable() else { throw RecoveryStore.InvalidArchive() }
        let retained = selectedTabs ?? tabs
        let eligible = resumeSessions.filter { session in retained.contains { $0.id == session.id && $0.session.instance == session.instance } }
        try recovery.save(SavedWorkspace(profile: connection.profile, selectedID: selectedID,
            tabs: retained.map(\.saved), resume: SavedResume(desired:resumeDesired,sessions:eligible), sidebarExpanded:sidebarExpanded))
        if recoveryError != nil { recoveryError = nil }
    }
    func checkpointWorkspace() {
        do { try saveRecovery(); if recoveryReadable { recoveryError = nil } }
        catch { recoveryError = "Could not save session recovery. Unlock the phone and check free space. Drafts remain in memory; do not close Chadmux yet." }
    }
    func restoreProtectedWorkspaceIfNeeded() {
        if restoreDeferred && protectedDataAvailable() { restore() }
    }
    @discardableResult
    func rememberConnectionIntent() -> Bool {
        guard recoveryReadable, protectedDataAvailable() else { return false }
        resumeDesired = true
        do {
            try saveRecovery()
            // No archive means only an in-memory workspace (e.g. a fixture).
            if recovery != nil { resumePermission.set(true,for:connection.profile) }
            return true
        } catch {
            resumePermission.set(false,for:connection.profile)
            recoveryError = "Could not save automatic reconnect. Your draft is retained; retry saving before closing Chadmux."
            return false
        }
    }
    func rememberAttachment(_ tab: SessionTab) {
        guard tab.transport.connected, !tab.session.instance.isEmpty, !tab.closed else { return }
        resumeSessions.removeAll { $0.id == tab.id }
        resumeSessions.append(tab.session)
        _ = rememberConnectionIntent()
    }

    func background() {
        foreground = false; activationAttempted = false
        cancelResume(); verificationTransport = nil
        resumeState = .idle
        cancelOwnDictation(message: "Dictation stopped when the app went into the background. Your draft is retained.")
        for tab in tabs { tab.submissionTask?.cancel(); tab.importTask?.cancel() }
        checkpointWorkspace()
        disconnectTransports()
    }

    func refresh() async {
        guard let client = connection.client, connection.connected, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let fetched = try await TmuxSessions.list(using: client, command: tmuxCommand)
            guard connection.client === client else { return }
            applySessions(fetched)
        }
        catch { if connection.client === client { self.error = "Could not list tmux sessions on \(hostLabel). Check that tmux is installed there, then refresh." } }
    }

    /// The folder offered for the next new session: the last one used on this
    /// host, or the host's default folder.
    var newSessionFolder: String {
        get { connection.preferences.string(forKey: "new-session-folder:" + connection.profile.trustID) ?? defaultFolder }
        set { connection.preferences.set(newValue, forKey: "new-session-folder:" + connection.profile.trustID) }
    }

    /// Creates a Claude session with the host's claude-tmux and opens it in a tab.
    /// Returns the message to show in the sheet, or nil once the tab is open.
    func createSession(name: String, folder rawFolder: String) async -> String? {
        let folder = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeTmux.validName(name) else { return "Use 1–64 letters, numbers, hyphens or underscores for the name." }
        guard !folder.isEmpty else { return "Enter a folder on \(hostLabel)." }
        guard !atTabLimit else { return "Close a tab before creating another session (eight open tabs maximum)." }
        guard let client = connection.client, connection.connected else { return "Connect to \(hostLabel) before creating a session." }
        guard !creatingSession else { return "A session is already being created." }
        creatingSession = true
        defer { creatingSession = false }
        let outcome: ClaudeTmux.Outcome
        do { outcome = try await claudeTmux.run(claudeTmux.createCommand(name: name, folder: folder), using: client) }
        catch { return "Could not reach \(hostLabel) to create the session. Refresh to check whether it started before trying again." }
        let reply: ClaudeTmux.Reply
        switch outcome {
        case .failed(_, let message): return message
        case .succeeded(let created): reply = created
        }
        newSessionFolder = folder
        let created = reply.name ?? name
        guard connection.client === client, await reloadSessions(client) else {
            return "“\(created)” was created, but the session list could not be refreshed. Close this sheet and refresh to open it."
        }
        guard let session = sessions.first(where: { $0.id == reply.id && $0.name == reply.name }) else {
            return "“\(created)” was created but is not running now. Check that claude starts in that folder on \(hostLabel), then refresh."
        }
        select(session)
        return nil
    }

    /// Ends a remote tmux session (and everything in it) through claude-tmux,
    /// refusing if the listed session was replaced. An open tab keeps its draft.
    func endSession(_ session: RemoteSession) async {
        guard let client = connection.client, connection.connected else { error = "Connect to \(hostLabel) before ending a session."; return }
        guard endingSessionID == nil else { return }
        endingSessionID = session.id
        defer { endingSessionID = nil }
        let outcome: ClaudeTmux.Outcome
        do { outcome = try await claudeTmux.run(claudeTmux.closeCommand(session), using: client) }
        catch { self.error = "Could not reach \(hostLabel) to end “\(session.name)”. Refresh to check whether it is still running."; return }
        guard connection.client === client else { return }
        _ = await reloadSessions(client)
        switch outcome {
        case .succeeded: break
        case .failed("not_found", _): error = "“\(session.name)” had already ended."
        case .failed("replaced", _): error = "“\(session.name)” was replaced by a newer session with the same name, so it was not ended. Review the refreshed list before trying again."
        case .failed(_, let message): error = message
        }
    }

    /// Renames the real tmux session through claude-tmux (tmux stays the source
    /// of truth). Returns the message to show in the rename sheet, or nil once
    /// renamed. Tabs, drafts and images are keyed by session id, so they stay.
    func renameSession(_ session: RemoteSession, to rawName: String) async -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeTmux.validNewName(name) else {
            return "Use 1–64 letters, numbers, hyphens or underscores, not starting with a hyphen."
        }
        guard name != session.name else { return nil }
        guard let client = connection.client, connection.connected else { return "Connect to \(hostLabel) before renaming a session." }
        guard renamingSessionID == nil else { return "Another session is being renamed." }
        renamingSessionID = session.id
        defer { renamingSessionID = nil }
        let outcome: ClaudeTmux.Outcome
        do { outcome = try await claudeTmux.run(claudeTmux.renameCommand(session, to: name), using: client) }
        catch { return "Could not reach \(hostLabel) to rename “\(session.name)”. Refresh to check its name before trying again." }
        guard connection.client === client else { return "The connection to \(hostLabel) changed. Refresh to check the name." }
        switch outcome {
        case .succeeded(let reply):
            applyRename(id: reply.id ?? session.id, instance: session.instance, to: reply.name ?? name)
            _ = await reloadSessions(client)
            return nil
        case .failed(let error, let message):
            if error == "not_found" || error == "replaced" { _ = await reloadSessions(client) }
            return Self.renameFailure(error, message: message, old: session.name, new: name, host: hostLabel)
        }
    }

    /// What the rename sheet says for each claude-tmux refusal.
    nonisolated static func renameFailure(_ error: String, message: String, old: String, new: String, host: String) -> String {
        switch error {
        case "name_taken": return "“\(new)” is already a session on \(host). Choose another name."
        case "not_found": return "“\(old)” is no longer running on \(host)."
        case "replaced": return "“\(old)” was replaced by a newer session with the same name, so it was not renamed. Review the refreshed list."
        // An older claude-tmux has no rename command (usage, or no JSON at all).
        case "usage", "failed": return "Update claude-tmux on \(host) to rename sessions (scripts/install-claude-tmux.sh from github.com/Ascinocco/q-factory-clean)."
        default: return message
        }
    }

    /// Shows a confirmed rename at once, before the next listing arrives.
    private func applyRename(id: String, instance: String, to name: String) {
        func renamed(_ old: RemoteSession) -> RemoteSession {
            old.id == id && old.instance == instance ? RemoteSession(id: old.id, name: name, instance: old.instance) : old
        }
        sessions = sessions.map(renamed)
        resumeSessions = resumeSessions.map(renamed)
        for tab in tabs where tab.session.id == id && tab.session.instance == instance { tab.session = renamed(tab.session) }
        checkpointWorkspace()
    }

    private func reloadSessions(_ client: SSHClient) async -> Bool {
        do {
            let fetched = try await TmuxSessions.list(using: client, command: tmuxCommand)
            guard connection.client === client else { return false }
            applySessions(fetched)
            return true
        } catch {
            if connection.client === client { self.error = "Could not list tmux sessions. Refresh to try again." }
            return false
        }
    }

    func select(_ session: RemoteSession) {
        let previous = selected
        if previous?.id != session.id, previous?.transport.connecting == true { previous?.transport.disconnect() }
        resumeAllowsSelected = true
        guard connection.connected else {
            if tabs.contains(where: { $0.id == session.id && $0.session.instance == session.instance }) { selectedID = session.id }
            else { error = "Connect to \(hostLabel) before selecting a session." }
            return
        }
        guard sessions.contains(where: { $0.id == session.id && $0.instance == session.instance }) else {
            selectedID = tabs.first(where: { $0.id == session.id })?.id
            error = "This session ended or was replaced. Its draft is retained; close the old tab before selecting its replacement."
            return
        }
        if let tab = tabs.first(where: { $0.id == session.id }) {
            guard tab.session.instance == session.instance else {
                error = "Close the old tab before opening this replacement session. Its draft is retained."
                return
            }
            selectedID = tab.id
            if !tab.transport.connected && resumeTask == nil { startResume(explicit:true) }
            return
        }
        guard !atTabLimit else { error = "Close a tab before opening another (eight open tabs maximum)."; return }
        let tab = SessionTab(session: session, profile: connection.profile, secrets: connection.secrets, media: media)
        tabs.append(tab); selectedID = tab.id
        if resumeTask == nil { startResume(explicit:true) }
    }

    func close(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        do { try saveRecovery(tabs: tabs.filter { $0.id != id }) }
        catch { recoveryError = "Could not save tab closure. Draft and images retained; unlock the phone/check free space and retry."; return }
        if voice.origin === tab { voice.cancel() }
        tab.closed = true; tab.submissionTask?.cancel(); tab.importTask?.cancel()
        for attachment in tab.attachments { try? tab.media.remove(attachment) }
        tab.transport.disconnect() // closes only this phone client; never kills tmux
        resumeSessions.removeAll { $0.id == id }
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs.first?.id }
    }

    func disconnect() {
        cancelResume(); verificationTransport = nil; resumeState = .idle
        resumePermission.set(false,for:connection.profile)
        resumeDesired = false; resumeSessions = []
        checkpointWorkspace()
        disconnectTransports()
    }
    func becameActive() {
        foreground = true
        restoreProtectedWorkspaceIfNeeded()
        guard protectedDataAvailable(), recoveryReadable, !activationAttempted else { return }
        activationAttempted = true
        if resumeDesired { startResume(explicit:false) }
    }
    func retryConnection() {
        guard foreground, protectedDataAvailable(), recoveryReadable else {
            resumeState = .unavailable; error = "Unlock your phone and restore your saved workspace before connecting."
            return
        }
        activationAttempted = true
        startResume(explicit:true)
    }
    func trustResumeHost() {
        guard let transport = verificationTransport else { return }
        do { try transport.acceptHostKey(); verificationTransport = nil; retryConnection() }
        catch { self.error = "Could not save the verified host key. Unlock your phone and try again." }
    }
    func cancelHostVerification() {
        verificationTransport?.unknownHost = nil; verificationTransport = nil
        resumeState = .unavailable
    }
    func waitForResume() async { await resumeTask?.value }

    private func startResume(explicit:Bool) {
        cancelResume()
        let token = UUID(), profile = connection.profile
        resumeGeneration = token; resumeAllowsSelected = explicit
        error = nil; verificationTransport = nil; resumeState = .reconnecting
        resumeTask = Task { await runResume(token:token,profile:profile,explicit:explicit) }
        resumeDeadline = Task {
            do { try await Task.sleep(nanoseconds:UInt64(resumeTimeout * 1_000_000_000)) }
            catch { return }
            guard validResume(token,profile:profile) else { return }
            cancelResume(); disconnectTransports()
            resumeState = .unavailable
            error = "Reconnect to \(hostLabel) timed out. Check the host and Tailscale, then retry. Your draft is retained."
        }
    }
    private func validResume(_ token:UUID,profile:MacConnection) -> Bool {
        resumeGeneration == token && connection.profile == profile && foreground && !Task.isCancelled
    }
    private func runResume(token:UUID,profile:MacConnection,explicit:Bool) async {
        defer {
            if resumeGeneration == token { resumeTask = nil; resumeDeadline?.cancel(); resumeDeadline = nil }
        }
        for attempt in 0..<2 {
            guard validResume(token,profile:profile) else { return }
            do {
                if !connection.connected {
                    connection.disconnect()
                    resumeState = .reconnecting
                    try await resumeOperations.connect(connection)
                }
                guard validResume(token,profile:profile), connection.connected else { throw ConnectionFailure.cancelled }
                if explicit { _ = rememberConnectionIntent() }
                resumeState = .discovering
                let fetched = try await resumeOperations.list(connection,tmuxCommand)
                guard validResume(token,profile:profile), connection.connected else { throw ConnectionFailure.cancelled }
                applySessions(fetched)
                try await attachCurrentSelection(token:token,profile:profile)
                guard validResume(token,profile:profile) else { return }
                resumeState = .ready
                return
            } catch {
                guard validResume(token,profile:profile) else { return }
                let failure = error as? ConnectionFailure ?? (error is SSHClient.CommandFailed || error is TmuxSessions.InvalidListing ? .sessionUnavailable : .network)
                if failure.isTransient && attempt == 0 {
                    disconnectTransports()
                    resumeState = .reconnecting
                    do { try await Task.sleep(nanoseconds:UInt64(resumeRetryDelay * 1_000_000_000)) }
                    catch { return }
                    continue
                }
                resumeState = .unavailable
                if failure == .verificationRequired {
                    verificationTransport = connection.unknownHost != nil ? connection : selected?.transport
                    self.error = "Verify \(hostLabel)’s host key before reconnecting."
                } else if failure == .sessionUnavailable {
                    self.error = "The saved tmux session is unavailable or was replaced. Its draft is retained; refresh sessions or close the old tab."
                } else if failure == .changedHost {
                    self.error = "Connection refused: \(hostLabel)’s SSH host key changed. Verify it before changing saved trust."
                } else if failure == .authentication {
                    self.error = "SSH authentication to \(hostLabel) failed. Check the username and that this device’s public key is authorized there."
                } else if failure == .protectedData {
                    self.error = "Unlock your phone to access its SSH key, then retry."
                } else {
                    self.error = "Could not reconnect to \(hostLabel). Check the host and Tailscale, then retry. Your draft is retained."
                }
                return
            }
        }
    }
    private func attachCurrentSelection(token:UUID,profile:MacConnection) async throws {
        while validResume(token,profile:profile), let tab = selected {
            guard resumeAllowsSelected || resumeSessions.contains(where:{$0.id == tab.id && $0.instance == tab.session.instance}) else { return }
            guard sessions.contains(where:{$0.id == tab.id && $0.instance == tab.session.instance}) else {
                tab.transport.status = "Session no longer exists"
                throw ConnectionFailure.sessionUnavailable
            }
            if tab.transport.connected { return }
            resumeState = .attaching
            do {
                try await resumeOperations.attach(tab,tmuxCommand)
            } catch {
                guard validResume(token,profile:profile) else { throw ConnectionFailure.cancelled }
                if selected !== tab { continue }
                throw error
            }
            guard validResume(token,profile:profile) else { throw ConnectionFailure.cancelled }
            if selected !== tab { tab.transport.disconnect(); continue }
            guard tab.transport.connected, !tab.closed else { throw ConnectionFailure.sessionUnavailable }
            rememberAttachment(tab)
            return
        }
    }
    private func cancelResume() {
        resumeGeneration = UUID()
        resumeTask?.cancel(); resumeTask = nil
        resumeDeadline?.cancel(); resumeDeadline = nil
    }
    private func profileChanged(_ previous:MacConnection) {
        cancelResume(); disconnectTransports()
        resumePermission.set(false,for:previous)
        resumePermission.set(false,for:connection.profile)
        resumeDesired = false; resumeSessions = []; sessions = []
        // Settings permit profile changes only after tabs have been closed.
        // Do not move or rewrite an old profile's drafts under the new profile.
        restoring = true; tabs = []; selectedID = nil; restoring = false
        recoveryReadable = true; recoveryError = nil
        resumeState = .idle; verificationTransport = nil
    }
    private func applySessions(_ fetched:[RemoteSession]) {
        sessions = fetched; error = nil
        loadContexts()
        for tab in tabs {
            if let current = fetched.first(where:{$0.id == tab.id && $0.instance == tab.session.instance}) {
                tab.session = current
            } else {
                tab.transport.disconnect(); tab.transport.status = "Session no longer exists"
            }
        }
    }

    /// Refreshes the sidebar context in the background; never blocks or fails a listing.
    private func loadContexts() {
        guard let client = connection.client, connection.connected else { return }
        let ids = sidebarSessions.map(\.id), command = tmuxCommand
        contextTask?.cancel()
        contextTask = Task { [weak self] in
            var found: [String: TmuxSessions.Context] = [:]
            for id in ids {
                if Task.isCancelled { return }
                if let context = await TmuxSessions.context(using: client, id: id, command: command) { found[id] = context }
            }
            guard let self, !Task.isCancelled, self.connection.client === client else { return }
            self.sessionContext = found
        }
    }

    /// Dictation belongs to one tab; only stop it when that tab is this host's.
    private func cancelOwnDictation(message: String? = nil) {
        guard let origin = voice.origin, tabs.contains(where: { $0 === origin }) else { return }
        if let message { voice.cancel(message: message) } else { voice.cancel() }
    }
    private func disconnectTransports() {
        cancelOwnDictation()
        connection.disconnect()
        for tab in tabs { tab.transport.disconnect() }
    }
}
