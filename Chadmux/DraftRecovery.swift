import Foundation
import Crypto

struct SavedTab: Codable {
    var session: RemoteSession
    var draft: String
    var attachments: [DraftAttachment]
    var pendingTranscript: String?
    var deliveryUncertain: Bool
    var writeInFlight: Bool
}
struct SavedResume: Codable {
    var desired: Bool
    var sessions: [RemoteSession]
}
struct SavedWorkspace: Codable {
    var version = 2
    var profile: MacConnection
    var selectedID: String?
    var tabs: [SavedTab]
    var resume: SavedResume? = nil
    var sidebarExpanded: Bool? = nil
}

struct RecoveryStore {
    let directory: URL
    init(directory: URL? = nil) {
        var location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chadmux/Drafts", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            location = FileManager.default.temporaryDirectory.appendingPathComponent("ChadmuxUITestDrafts", isDirectory: true)
        }
        #endif
        self.directory = directory ?? location
    }
    static func profileKey(_ profile: MacConnection) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(profile)).map { String(format: "%02x", $0) }.joined()
        return hash
    }
    func url(for profile: MacConnection) throws -> URL {
        directory.appendingPathComponent(try Self.profileKey(profile) + ".json")
    }
    func load(profile: MacConnection) throws -> SavedWorkspace? {
        let file = try url(for: profile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let result = try read(file)
        guard result.profile == profile else { throw InvalidArchive() }
        return result
    }
    private func read(_ file: URL) throws -> SavedWorkspace {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 10 * 1024 * 1024 else { throw InvalidArchive() }
        let snapshot = try JSONDecoder().decode(SavedWorkspace.self, from: Data(contentsOf: file))
        try validate(snapshot)
        return snapshot
    }
    private func validate(_ snapshot: SavedWorkspace) throws {
        guard [1,2].contains(snapshot.version), snapshot.tabs.count <= 8,
              Set(snapshot.tabs.map { $0.session.id }).count == snapshot.tabs.count,
              Set(snapshot.tabs.flatMap { $0.attachments.map(\.id) }).count == snapshot.tabs.reduce(0, { $0 + $1.attachments.count }) else { throw InvalidArchive() }
        if let resume = snapshot.resume {
            guard snapshot.version == 2, resume.sessions.count <= 8,
                  Set(resume.sessions.map(\.id)).count == resume.sessions.count,
                  resume.sessions.allSatisfy({ session in
                      !session.instance.isEmpty && snapshot.tabs.contains { $0.session.id == session.id && $0.session.instance == session.instance }
                  }) else { throw InvalidArchive() }
        }
        for tab in snapshot.tabs {
            guard TmuxSessions.validID(tab.session.id), tab.session.name.utf8.count <= 8192,
                  tab.session.instance.utf8.count <= 128, tab.draft.utf8.count <= 1024 * 1024,
                  (tab.pendingTranscript?.utf8.count ?? 0) <= 65_536,
                  tab.attachments.count <= MediaStore.maximumAttachments,
                  Set(tab.attachments.map(\.id)).count == tab.attachments.count,
                  tab.attachments.allSatisfy({ $0.filename == $0.id.uuidString.lowercased() + ".jpg" && $0.mediaType == "image/jpeg" }) else { throw InvalidArchive() }
        }
    }
    func save(_ snapshot: SavedWorkspace) throws {
        try validate(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 10 * 1024 * 1024 else { throw InvalidArchive() }
        try PrivateStorage.createDirectory(directory)
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try PrivateStorage.write(data, to: url(for: snapshot.profile))
    }
    // Only at startup, before any import can be in flight. A corrupt/locked
    // archive prevents cleanup, so its potentially referenced files are retained.
    func removeOrphanedMedia(in media: MediaStore) throws {
        let files = FileManager.default.fileExists(atPath: directory.path)
            ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
        var referenced = Set<String>()
        for file in files where file.pathExtension == "json" {
            for tab in try read(file).tabs { referenced.formUnion(tab.attachments.map(\.filename)) }
        }
        guard FileManager.default.fileExists(atPath: media.directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: media.directory, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "jpg", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  !referenced.contains(file.lastPathComponent) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
    struct InvalidArchive: Error {}
}

@MainActor
extension SessionTab {
    var saved: SavedTab {
        SavedTab(session: session, draft: draft, attachments: attachments, pendingTranscript: pendingTranscript,
                 deliveryUncertain: deliveryUncertain, writeInFlight: writeInFlight)
    }
    func apply(_ value: SavedTab) {
        suppressCheckpoint = true
        draft = value.draft; attachments = value.attachments; pendingTranscript = value.pendingTranscript
        deliveryUncertain = value.deliveryUncertain; writeInFlight = value.writeInFlight
        suppressCheckpoint = false
    }
    @discardableResult
    func checkpoint() -> Bool {
        guard !suppressCheckpoint else { return true }
        do { try persist?(); persistenceError = nil; return true }
        catch { persistenceError = "Could not save this draft. Unlock the phone and check free space before sending or closing Chadmux."; return false }
    }
    @discardableResult
    func savedChange(_ change: () -> Void) -> Bool {
        let previous = saved
        suppressCheckpoint = true; change(); suppressCheckpoint = false
        guard checkpoint() else { apply(previous); return false }
        return true
    }
    func insertTranscript() {
        guard let transcript = pendingTranscript, !closed else { return }
        if savedChange({
            draft = VoiceCoordinator.appending(transcript, to: draft)
            pendingTranscript = nil
        }) { dictationStatus = "Dictation added. Edit it before sending." }
    }
    func acknowledgeDelivery() {
        if savedChange({ deliveryUncertain = false; writeInFlight = false }) {
            submissionMessage = "Draft ready. Send again only if needed."
        }
    }
}

/// Non-secret opt-out is independent of the protected draft archive. A failed
/// draft write must never resurrect a deliberately disconnected workspace.
struct ResumePermission {
    let preferences: UserDefaults
    private func key(_ profile: MacConnection) -> String? {
        (try? RecoveryStore.profileKey(profile)).map { "resume-allowed:" + $0 }
    }
    func allows(_ profile: MacConnection) -> Bool {
        guard let key = key(profile) else { return false }
        return preferences.bool(forKey:key)
    }
    func set(_ allowed: Bool, for profile: MacConnection) {
        guard let key = key(profile) else { return }
        preferences.set(allowed,forKey:key)
    }
}
