import XCTest
@testable import Chadmux

@MainActor
final class HostTests: XCTestCase {
    private var cleanups: [() -> Void] = []
    override func tearDown() { cleanups.forEach { $0() }; cleanups = [] }

    private let mac = MacConnection(host: "mac.example", port: 22, username: "user")
    private let arch = MacConnection(host: "arch.example", port: 22, username: "user")

    /// Isolated preferences, Keychain service and draft/image folders.
    private func environment() -> (preferences: UserDefaults, secrets: SecretStore, recovery: RecoveryStore, media: MediaStore) {
        let scope = "com.chadmux.host-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: scope)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(scope, isDirectory: true)
        let secrets = SecretStore(service: scope)
        cleanups.append {
            preferences.removePersistentDomain(forName: scope)
            try? FileManager.default.removeItem(at: root)
            for account in ["device-ed25519", self.mac.trustID, self.arch.trustID, self.mac.apiTokenID, self.arch.apiTokenID] { try? secrets.remove(account) }
        }
        return (preferences, secrets, RecoveryStore(directory: root.appendingPathComponent("drafts")), MediaStore(directory: root.appendingPathComponent("images")))
    }
    private func model(_ env: (preferences: UserDefaults, secrets: SecretStore, recovery: RecoveryStore, media: MediaStore)) -> HostsModel {
        HostsModel(preferences: env.preferences, secrets: env.secrets, recovery: env.recovery, media: env.media)
    }
    private func legacy(_ connection: MacConnection, in preferences: UserDefaults) throws {
        preferences.set(try JSONEncoder().encode(connection), forKey: HostStore.legacyKey)
    }

    func testNoSavedConnectionMeansNoHosts() {
        let hosts = model(environment())
        XCTAssertTrue(hosts.hosts.isEmpty)
        XCTAssertNil(hosts.selectedWorkspace)
        XCTAssertFalse(hosts.publicKey.isEmpty, "the device key exists before any host")
    }

    func testMigrationKeepsTrustDraftsResumeAndTokenWithoutRepairing() throws {
        let env = environment()
        try legacy(mac, in: env.preferences)
        try env.secrets.write(Data("ssh-ed25519 AAAAfixture".utf8), account: mac.trustID)
        try env.secrets.write(Data("fixture-token-0123456789".utf8), account: mac.apiTokenID)
        // The pre-upgrade app saved this draft archive and resume choice for the Mac.
        let tab = SavedTab(session: RemoteSession(id: "$3", name: "claude-demo", instance: "10:20"), draft: "Unsent draft",
                           attachments: [], pendingTranscript: nil, deliveryUncertain: false, writeInFlight: false)
        try env.recovery.save(SavedWorkspace(profile: mac, selectedID: "$3", tabs: [tab],
                                             resume: SavedResume(desired: true, sessions: [tab.session])))
        ResumePermission(preferences: env.preferences).set(true, for: mac)

        let hosts = model(env)
        XCTAssertEqual(hosts.hosts.count, 1)
        let host = try XCTUnwrap(hosts.hosts.first)
        XCTAssertEqual(host.label, "Mac"); XCTAssertEqual(host.connection, mac); XCTAssertEqual(host.defaultFolder, "~")
        let workspace = try XCTUnwrap(hosts.selectedWorkspace)
        XCTAssertEqual(workspace.connection.profile, mac)
        XCTAssertEqual(workspace.hostLabel, "Mac")
        XCTAssertEqual(workspace.tabs.map(\.draft), ["Unsent draft"])
        XCTAssertEqual(workspace.selectedID, "$3")
        XCTAssertTrue(workspace.resumeDesired, "an explicit connect before upgrading still resumes")
        XCTAssertEqual(try env.secrets.read(mac.trustID), Data("ssh-ed25519 AAAAfixture".utf8), "no re-pairing")
        XCTAssertEqual(try env.secrets.read(host.connection.apiTokenID), Data("fixture-token-0123456789".utf8))
        // The migration is saved once; the legacy value is left untouched.
        XCTAssertNotNil(env.preferences.data(forKey: HostStore.key))
        XCTAssertNotNil(env.preferences.data(forKey: HostStore.legacyKey))
        let again = model(env)
        XCTAssertEqual(again.hosts, hosts.hosts, "the migrated host keeps its id on the next launch")
    }

    func testCorruptHostListFallsBackToTheLegacyConnection() throws {
        let env = environment()
        try legacy(mac, in: env.preferences)
        env.preferences.set(Data("not json".utf8), forKey: HostStore.key)
        XCTAssertEqual(model(env).hosts.map(\.connection), [mac])
        let invalidList = [HostProfile(label: "", connection: arch)]
        env.preferences.set(try JSONEncoder().encode(invalidList), forKey: HostStore.key)
        XCTAssertEqual(model(env).hosts.map(\.connection), [mac], "a list that fails validation is not trusted")
    }

    func testValidationRejectsDuplicatesAndBadFields() {
        let a = HostProfile(label: "Mac", connection: mac)
        XCTAssertNoThrow(try HostStore.validate([a, HostProfile(label: "Arch", connection: arch)]))
        XCTAssertThrowsError(try HostStore.validate([a, HostProfile(label: "mac", connection: arch)]), "labels are case-insensitive")
        XCTAssertThrowsError(try HostStore.validate([a, HostProfile(label: "Other", connection: mac)]), "one host per user and address")
        XCTAssertNoThrow(try HostStore.validate([a, HostProfile(label: "Root", connection: MacConnection(host: "mac.example", port: 22, username: "root"))]))
        XCTAssertThrowsError(try HostStore.validate([a, HostProfile(id: a.id, label: "Arch", connection: arch)]), "unique ids")
        XCTAssertThrowsError(try HostStore.validate((0...8).map { HostProfile(label: "H\($0)", connection: MacConnection(host: "h\($0).example", port: 22, username: "u")) }))
        for bad in [HostProfile(label: " Mac", connection: mac), HostProfile(label: String(repeating: "x", count: 33), connection: mac),
                    HostProfile(label: "Ma\nc", connection: mac), HostProfile(label: "Mac", connection: MacConnection()),
                    HostProfile(label: "Mac", connection: mac, defaultFolder: ""), HostProfile(label: "Mac", connection: mac, defaultFolder: "~/a\nb")] {
            XCTAssertNotNil(bad.problem, bad.label)
        }
        XCTAssertEqual(HostProfile(label: "Mac", connection: MacConnection()).problem, "Enter a host, username and port between 1 and 65535.")
    }

    func testAddEditAndRemovePersistAndUpdateTheLiveWorkspace() throws {
        let env = environment()
        let hosts = model(env)
        try hosts.add(HostProfile(label: "Mac", connection: mac))
        let archHost = HostProfile(label: "Arch", connection: arch, defaultFolder: "~/Projects")
        try hosts.add(archHost)
        XCTAssertEqual(hosts.hosts.map(\.label), ["Mac", "Arch"])
        XCTAssertEqual(hosts.selectedHost?.label, "Mac", "the first host stays selected")
        let archWorkspace = try XCTUnwrap(hosts.workspace(for: archHost.id))
        XCTAssertEqual(archWorkspace.connection.profile, arch, "each host has its own endpoint and pinned trust")
        XCTAssertFalse(archWorkspace.connection === hosts.selectedWorkspace?.connection)
        XCTAssertEqual(archWorkspace.newSessionFolder, "~/Projects")
        XCTAssertThrowsError(try hosts.add(HostProfile(label: "ARCH", connection: MacConnection(host: "x", port: 22, username: "y"))))

        var renamed = archHost; renamed.label = "Arch Linux"; renamed.defaultFolder = "~/src"
        try hosts.update(renamed)
        XCTAssertEqual(archWorkspace.hostLabel, "Arch Linux")
        XCTAssertEqual(archWorkspace.newSessionFolder, "~/src")
        XCTAssertEqual(model(env).hosts.map(\.label), ["Mac", "Arch Linux"], "persisted")

        // The endpoint is locked while the host has tabs, then changes the live transport.
        archWorkspace.tabs = [SessionTab(session: RemoteSession(id: "$0", name: "a"), profile: arch, secrets: env.secrets)]
        var moved = renamed; moved.connection = MacConnection(host: "arch2.example", port: 2222, username: "user")
        XCTAssertThrowsError(try hosts.update(moved)) { XCTAssertTrue($0 is HostsModel.TabsOpen) }
        archWorkspace.close("$0")
        try hosts.update(moved)
        XCTAssertEqual(archWorkspace.connection.profile, moved.connection)

        try hosts.remove(archHost.id)
        XCTAssertEqual(hosts.hosts.map(\.label), ["Mac"])
        XCTAssertNil(hosts.workspace(for: archHost.id))
        XCTAssertEqual(model(env).hosts.map(\.label), ["Mac"])
    }

    func testRemovingAHostClosesItsTabsAndForgetsOnlyItsOwnTrust() throws {
        let env = environment()
        let hosts = model(env)
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        let rootOnMac = HostProfile(label: "Mac root", connection: MacConnection(host: "mac.example", port: 22, username: "root"))
        try hosts.add(macHost); try hosts.add(archHost); try hosts.add(rootOnMac)
        for connection in [mac, arch] {
            try env.secrets.write(Data("pin".utf8), account: connection.trustID)
            try env.secrets.write(Data("token-for-tests-0123456789".utf8), account: connection.apiTokenID)
        }
        let archWorkspace = try XCTUnwrap(hosts.workspace(for: archHost.id))
        let tab = SessionTab(session: RemoteSession(id: "$0", name: "a", instance: "1:2"), profile: arch, secrets: env.secrets)
        tab.draft = "discarded with the host"
        archWorkspace.tabs = [tab]
        try hosts.remove(archHost.id)
        XCTAssertTrue(tab.closed)
        XCTAssertNil(try env.secrets.read(arch.trustID)); XCTAssertNil(try env.secrets.read(arch.apiTokenID))
        // Another profile still uses the Mac's address, so its host key stays trusted.
        try hosts.remove(macHost.id)
        XCTAssertNotNil(try env.secrets.read(mac.trustID))
        XCTAssertEqual(hosts.selectedHost?.label, "Mac root")
    }

    func testTheEightTabLimitSpansAllHosts() async throws {
        let env = environment()
        let hosts = model(env)
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        try hosts.add(macHost); try hosts.add(archHost)
        let macWorkspace = try XCTUnwrap(hosts.workspace(for: macHost.id)), archWorkspace = try XCTUnwrap(hosts.workspace(for: archHost.id))
        macWorkspace.tabs = (0..<5).map { SessionTab(session: RemoteSession(id: "$\($0)", name: "m\($0)", instance: "1:\($0)"), profile: mac, secrets: env.secrets) }
        archWorkspace.tabs = (0..<3).map { SessionTab(session: RemoteSession(id: "$\($0)", name: "a\($0)", instance: "1:\($0)"), profile: arch, secrets: env.secrets) }
        XCTAssertEqual(hosts.totalTabs, 8)
        // A ninth tab on either host is refused before contacting it.
        archWorkspace.connection.connected = true
        archWorkspace.sessions = [RemoteSession(id: "$9", name: "ninth", instance: "1:9")]
        archWorkspace.select(archWorkspace.sessions[0])
        XCTAssertEqual(archWorkspace.error, "Close a tab before opening another (eight open tabs maximum).")
        XCTAssertEqual(archWorkspace.tabs.count, 3)
        let refused = await macWorkspace.createSession(name: "ninth", folder: "~")
        XCTAssertEqual(refused, "Close a tab before creating another session (eight open tabs maximum).")
        archWorkspace.connection.connected = false
    }

    func testOneMicrophoneAndDisconnectingAnotherHostKeepsDictation() async throws {
        let env = environment()
        // Never asks the simulator for microphone access: the request just stays pending.
        let voice = VoiceCoordinator(permission: { try? await Task.sleep(nanoseconds: 30_000_000_000); return false })
        let hosts = HostsModel(preferences: env.preferences, secrets: env.secrets, recovery: env.recovery, media: env.media, voice: voice)
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        try hosts.add(macHost); try hosts.add(archHost)
        let macWorkspace = try XCTUnwrap(hosts.workspace(for: macHost.id)), archWorkspace = try XCTUnwrap(hosts.workspace(for: archHost.id))
        XCTAssertTrue(macWorkspace.voice === archWorkspace.voice)
        let archTab = SessionTab(session: RemoteSession(id: "$0", name: "a", instance: "1:2"), profile: arch, secrets: env.secrets)
        archWorkspace.tabs = [archTab]
        hosts.voice.start(tab: archTab) { _ in "unused" }
        XCTAssertTrue(hosts.voice.active)
        macWorkspace.disconnect()
        XCTAssertTrue(hosts.voice.active, "another host's disconnect must not stop this recording")
        archWorkspace.disconnect()
        XCTAssertFalse(hosts.voice.active, "its own host's disconnect does")
    }

    func testUnknownLastUsedFolderFallsBackToTheHostDefault() throws {
        let env = environment()
        let hosts = model(env)
        let host = HostProfile(label: "Arch", connection: arch, defaultFolder: "~/Projects")
        try hosts.add(host)
        let workspace = try XCTUnwrap(hosts.workspace(for: host.id))
        XCTAssertEqual(workspace.newSessionFolder, "~/Projects")
        workspace.newSessionFolder = "~/elsewhere"
        XCTAssertEqual(workspace.newSessionFolder, "~/elsewhere", "the last folder used on this host wins")
    }
}

@MainActor
final class MultiHostWorkspaceTests: XCTestCase {
    private let mac = MacConnection(host: "mac.example", port: 22, username: "user")
    private let arch = MacConnection(host: "arch.example", port: 22, username: "user")
    private let shared = RemoteSession(id: "$0", name: "shared-name", instance: "100:1")

    /// Hosts whose connect/list/attach are injected per host: no network.
    private func model(connect: @escaping (MacConnection) throws -> Void) throws -> (HostsModel, UUID, UUID, UserDefaults) {
        let scope = "com.chadmux.multihost-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: scope)!
        addTeardownBlock { preferences.removePersistentDomain(forName: scope) }
        let shared = self.shared
        let hosts = HostsModel(preferences: preferences, secrets: SecretStore(service: scope), recovery: nil,
                               media: MediaStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(scope))) { host, model in
            let operations = ResumeOperations(
                connect: { transport in try connect(transport.profile); transport.connected = true },
                list: { _, _ in [shared] },
                attach: { tab, _ in tab.transport.connected = true })
            return SessionWorkspace(connection: MacTransport(preferences: model.preferences, secrets: model.secrets, profile: host.connection),
                                    voice: model.voice, protectedDataAvailable: { true }, resumeOperations: operations,
                                    resumeTimeout: 2, resumeRetryDelay: 0.001)
        }
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        try hosts.add(macHost); try hosts.add(archHost)
        return (hosts, macHost.id, archHost.id, preferences)
    }
    private func connectAll(_ hosts: HostsModel) async {
        hosts.becameActive()
        for (_, workspace) in hosts.orderedWorkspaces { workspace.retryConnection() }
        for (_, workspace) in hosts.orderedWorkspaces { await workspace.waitForResume() }
    }

    func testTheSameSessionIdOnTwoHostsOpensTwoIndependentTabs() async throws {
        let (hosts, macID, archID, _) = try model { _ in }
        await connectAll(hosts)
        hosts.select(shared, on: archID)
        XCTAssertEqual(hosts.selectedHostID, archID)
        let archWorkspace = try XCTUnwrap(hosts.workspace(for: archID)), macWorkspace = try XCTUnwrap(hosts.workspace(for: macID))
        await archWorkspace.waitForResume()
        hosts.select(shared, on: macID)
        await macWorkspace.waitForResume()
        XCTAssertEqual(hosts.selectedHostID, macID)
        let archTab = try XCTUnwrap(archWorkspace.tabs.first), macTab = try XCTUnwrap(macWorkspace.tabs.first)
        XCTAssertFalse(archTab === macTab)
        XCTAssertEqual(archTab.transport.profile, arch); XCTAssertEqual(macTab.transport.profile, mac)
        archTab.draft = "for arch"; macTab.draft = "for mac"
        XCTAssertEqual(archTab.draft, "for arch", "same id and name, separate drafts")
        XCTAssertEqual(hosts.totalTabs, 2)
        macWorkspace.close("$0")
        XCTAssertEqual(archWorkspace.tabs.map(\.draft), ["for arch"], "closing one host's tab leaves the other")
    }

    func testAHostAddedWhileTheAppIsActiveCanConnectAtOnce() async throws {
        let (hosts, _, _, _) = try model { _ in }
        await connectAll(hosts)
        // Added from settings while the app is in the foreground: no new activation arrives.
        let added = HostProfile(label: "Added", connection: MacConnection(host: "added.example", port: 22, username: "user"))
        try hosts.add(added)
        let workspace = try XCTUnwrap(hosts.workspace(for: added.id))
        workspace.retryConnection()
        await workspace.waitForResume()
        XCTAssertNil(workspace.error, "Connect works without backgrounding the app first")
        XCTAssertTrue(workspace.connection.connected)
        XCTAssertEqual(workspace.resumeState, .ready)
        // After going to the background, a newly added host waits for the next activation.
        hosts.background()
        let later = HostProfile(label: "Later", connection: MacConnection(host: "later.example", port: 22, username: "user"))
        try hosts.add(later)
        let waiting = try XCTUnwrap(hosts.workspace(for: later.id))
        waiting.retryConnection()
        XCTAssertEqual(waiting.resumeState, .unavailable)
        hosts.becameActive()
        waiting.retryConnection()
        await waiting.waitForResume()
        XCTAssertTrue(waiting.connection.connected)
    }

    func testAnOfflineHostDoesNotBlockAHealthyOne() async throws {
        struct Unreachable: Error {}
        let (hosts, macID, archID, _) = try model { connection in
            if connection.host == "arch.example" { throw Unreachable() }
        }
        await connectAll(hosts)
        let macWorkspace = try XCTUnwrap(hosts.workspace(for: macID)), archWorkspace = try XCTUnwrap(hosts.workspace(for: archID))
        XCTAssertEqual(macWorkspace.resumeState, .ready)
        XCTAssertTrue(macWorkspace.connection.connected)
        XCTAssertEqual(macWorkspace.sessions, [shared])
        XCTAssertEqual(archWorkspace.resumeState, .unavailable)
        XCTAssertFalse(archWorkspace.connection.connected)
        XCTAssertEqual(archWorkspace.error, "Could not reconnect to Arch. Check the host and Tailscale, then retry. Your draft is retained.")
        XCTAssertNil(macWorkspace.error)
        hosts.select(shared, on: macID)
        await macWorkspace.waitForResume()
        XCTAssertTrue(try XCTUnwrap(macWorkspace.selected).transport.connected)
    }

    func testSelectionAndSidebarAreSharedAndRemembered() throws {
        let (hosts, _, archID, preferences) = try model { _ in }
        hosts.selectedHostID = archID
        hosts.sidebarExpanded = true
        XCTAssertTrue(hosts.orderedWorkspaces.allSatisfy { $0.workspace.sidebarExpanded })
        // A workspace opening or closing the sidebar updates the one app-wide sidebar.
        hosts.orderedWorkspaces[1].workspace.sidebarExpanded = false
        XCTAssertFalse(hosts.sidebarExpanded)
        XCTAssertTrue(hosts.orderedWorkspaces.allSatisfy { !$0.workspace.sidebarExpanded })
        hosts.orderedWorkspaces[0].workspace.sidebarExpanded = true
        XCTAssertTrue(hosts.sidebarExpanded)
        let relaunched = HostsModel(preferences: preferences, secrets: hosts.secrets, recovery: nil, media: hosts.media)
        XCTAssertEqual(relaunched.selectedHostID, archID)
        preferences.set(UUID().uuidString, forKey: "selected-host")
        XCTAssertEqual(HostsModel(preferences: preferences, secrets: hosts.secrets, recovery: nil, media: hosts.media).selectedHost?.label, "Mac",
                       "an unknown remembered host falls back to the first")
    }

    func testAHostWaitingForVerificationIsFoundWhenNotOnScreen() throws {
        let (hosts, macID, archID, _) = try model { _ in }
        hosts.selectedHostID = macID
        XCTAssertNil(hosts.verifying)
        let archWorkspace = try XCTUnwrap(hosts.workspace(for: archID))
        archWorkspace.verificationTransport = archWorkspace.connection
        XCTAssertEqual(hosts.verifying?.host.label, "Arch")
        XCTAssertTrue(hosts.verifying?.workspace === archWorkspace)
    }
}

@MainActor
final class DictationHostTests: XCTestCase {
    private let mac = MacConnection(host: "mac.example", port: 22, username: "user")
    private let arch = MacConnection(host: "arch.example", port: 22, username: "user")
    private func environment() -> (UserDefaults, SecretStore) {
        let scope = "com.chadmux.dictation-host-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: scope)!, secrets = SecretStore(service: scope)
        addTeardownBlock {
            preferences.removePersistentDomain(forName: scope)
            for account in ["device-ed25519", self.mac.trustID, self.arch.trustID, self.mac.apiTokenID, self.arch.apiTokenID] { try? secrets.remove(account) }
        }
        return (preferences, secrets)
    }
    private func message(_ route: VoiceCoordinator.Route) -> String? {
        if case .unavailable(let message) = route { return message }
        return nil
    }
    private func tab(on connection: MacConnection, secrets: SecretStore) -> SessionTab {
        SessionTab(session: RemoteSession(id: "$0", name: "t", instance: "1:2"), profile: connection, secrets: secrets)
    }

    func testDictationNeedsAHostATokenAndAVerifiedKeyBeforeRecording() throws {
        let (preferences, secrets) = environment()
        let hosts = HostsModel(preferences: preferences, secrets: secrets, recovery: nil)
        let probe = tab(on: arch, secrets: secrets)
        XCTAssertEqual(message(hosts.dictationRoute(for: probe)), "Add a host in Connection settings to use dictation.")
        try hosts.add(HostProfile(label: "Mac", connection: mac))
        XCTAssertEqual(message(hosts.dictationRoute(for: probe)), "Add the transcription token for Mac in Connection settings first.")
        try secrets.write(Data("fixture-transcription-token".utf8), account: mac.apiTokenID)
        XCTAssertEqual(message(hosts.dictationRoute(for: probe)), "Connect to Mac once to verify its host key, then record again.")
        try secrets.write(Data("ssh-ed25519 AAAApin".utf8), account: mac.trustID)
        XCTAssertNil(message(hosts.dictationRoute(for: probe)), "ready: token and pinned key present")
    }

    func testATabOnAnyHostUsesTheChosenDictationHost() throws {
        let (preferences, secrets) = environment()
        let hosts = HostsModel(preferences: preferences, secrets: secrets, recovery: nil)
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        try hosts.add(macHost); try hosts.add(archHost)
        XCTAssertEqual(hosts.dictationHost?.label, "Mac", "defaults to the first host")
        let archTab = tab(on: arch, secrets: secrets)
        // Arch's own token doesn't matter: the dictation host's does.
        try secrets.write(Data("arch-token-0123456789abc".utf8), account: arch.apiTokenID)
        XCTAssertEqual(message(hosts.dictationRoute(for: archTab)), "Add the transcription token for Mac in Connection settings first.")
        hosts.dictationHostID = archHost.id
        XCTAssertEqual(message(hosts.dictationRoute(for: tab(on: mac, secrets: secrets))), "Connect to Arch once to verify its host key, then record again.")
        // Remembered, and reset to the first host if that host is removed.
        XCTAssertEqual(HostsModel(preferences: preferences, secrets: secrets, recovery: nil).dictationHost?.label, "Arch")
        try hosts.remove(archHost.id)
        XCTAssertNil(hosts.dictationHostID)
        XCTAssertEqual(hosts.dictationHost?.label, "Mac")
    }

    func testTheSharedMicrophoneUsesTheRouteAndReportsWhyItCannotStart() throws {
        let (preferences, secrets) = environment()
        let voice = VoiceCoordinator(permission: { true })
        let hosts = HostsModel(preferences: preferences, secrets: secrets, recovery: nil, voice: voice)
        try hosts.add(HostProfile(label: "Mac", connection: mac))
        let archTab = tab(on: arch, secrets: secrets)
        archTab.transport.connected = true   // the tab's own connection is irrelevant now
        voice.start(tab: archTab)
        XCTAssertFalse(voice.active, "nothing records until the dictation host is usable")
        XCTAssertEqual(archTab.dictationStatus, "Add the transcription token for Mac in Connection settings first.")
        archTab.transport.connected = false
    }
}

final class SessionContextTests: XCTestCase {
    func testContextParsesAttachedActivityAndPathWithTabs() {
        let context = TmuxSessions.parseContext("2\t1790000000\t/Users/user/Projects/with\ttab and spaces\n")
        XCTAssertEqual(context?.clients, 2)
        XCTAssertEqual(context?.activity, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(context?.path, "/Users/user/Projects/with\ttab and spaces", "the path is last, so it may contain tabs")
    }
    func testMalformedContextIsIgnoredNotShown() {
        XCTAssertNil(TmuxSessions.parseContext(""))
        XCTAssertNil(TmuxSessions.parseContext("x\t1\t/tmp"))
        XCTAssertNil(TmuxSessions.parseContext("-1\t1\t/tmp"))
        XCTAssertNil(TmuxSessions.parseContext("1\t1\t/tmp/\u{1b}[31mred"), "no terminal escapes into the sidebar")
        XCTAssertEqual(TmuxSessions.parseContext("0\tnot-a-time\t/tmp")?.activity, nil)
    }
    func testHomeFoldersDisplayAsTilde() {
        XCTAssertEqual(TmuxSessions.displayPath("/Users/user", user: "user"), "~")
        XCTAssertEqual(TmuxSessions.displayPath("/Users/user/Projects/demo", user: "user"), "~/Projects/demo")
        XCTAssertEqual(TmuxSessions.displayPath("/home/user/src", user: "user"), "~/src")
        XCTAssertEqual(TmuxSessions.displayPath("/Users/usera/src", user: "user"), "/Users/usera/src", "only the user's own home")
        XCTAssertEqual(TmuxSessions.displayPath("/srv/app", user: "user"), "/srv/app")
    }
}
