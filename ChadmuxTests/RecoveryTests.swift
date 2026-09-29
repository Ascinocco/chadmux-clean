import XCTest
import UIKit
@testable import Chadmux

final class RecoveryTests: XCTestCase {
    @MainActor
    private func workspace(root: URL) -> SessionWorkspace {
        let name = "com.chadmux.recovery-tests." + root.lastPathComponent
        let preferences = UserDefaults(suiteName: name)!
        let connection = MacTransport(preferences: preferences, secrets: SecretStore(service: name))
        connection.profile = MacConnection(host: "fixture.example", port: 22, username: "fixture")
        return SessionWorkspace(connection: connection,
            recovery: RecoveryStore(directory: root.appendingPathComponent("drafts")),
            media: MediaStore(directory: root.appendingPathComponent("images")))
    }
    @MainActor
    private func addTab(_ workspace: SessionWorkspace) -> SessionTab {
        let tab = SessionTab(session: RemoteSession(id: "$0", name: "Fixture", instance: "123:456"),
            profile: workspace.connection.profile, secrets: workspace.connection.secrets, media: workspace.media)
        workspace.tabs = [tab]; workspace.selectedID = tab.id
        return tab
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    @MainActor
    private func image(_ tab: SessionTab) async throws -> DraftAttachment {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let attachment = try await tab.media.importImage(data); tab.attachments.append(attachment)
        return attachment
    }
    @MainActor
    func testRelaunchRestoresDraftImagesTranscriptAndUncertaintyOffline() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Unsent\nmessage"; tab.pendingTranscript = "Review this transcript"; tab.deliveryUncertain = true
        let attachment = try await image(tab)
        let restored = workspace(root: root), result = try XCTUnwrap(restored.selected)
        XCTAssertEqual(result.draft, tab.draft); XCTAssertEqual(result.pendingTranscript, tab.pendingTranscript)
        XCTAssertEqual(result.attachments, [attachment]); XCTAssertTrue(result.deliveryUncertain)
        XCTAssertFalse(restored.connection.connected); XCTAssertFalse(result.transport.connected)
        XCTAssertFalse(result.transport.connecting); XCTAssertNil(result.submissionTask)
        XCTAssertNoThrow(try result.media.data(for: attachment))
        XCTAssertEqual(try original.recovery!.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if !targetEnvironment(simulator)
        let file = try original.recovery!.url(for: original.connection.profile)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        #endif
        result.acknowledgeDelivery()
        XCTAssertFalse(try XCTUnwrap(workspace(root: root).selected).deliveryUncertain)
    }
    @MainActor
    func testDurableCheckpointPrecedesWriteAndCrashRestoresUncertainDraft() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Do not replay"
        var writes = 0
        await tab.submit(pasteEnabled: true) { _ in
            writes += 1
            let archive = try XCTUnwrap(original.recovery!.load(profile: original.connection.profile))
            XCTAssertTrue(archive.tabs[0].writeInFlight)
            XCTAssertEqual(archive.tabs[0].draft, "Do not replay")
            let relaunch = self.workspace(root: root), restored = try XCTUnwrap(relaunch.selected)
            XCTAssertTrue(restored.deliveryUncertain); XCTAssertFalse(restored.transport.connecting)
            XCTAssertEqual(restored.draft, "Do not replay")
            await restored.submit(pasteEnabled: true) { _ in writes += 1 }
            XCTAssertEqual(writes, 1)
            throw MacTransport.NotConnected()
        }
        XCTAssertEqual(writes, 1); XCTAssertTrue(tab.deliveryUncertain)
        let persisted = try XCTUnwrap(original.recovery!.load(profile: original.connection.profile))
        XCTAssertTrue(persisted.tabs[0].deliveryUncertain); XCTAssertFalse(persisted.tabs[0].writeInFlight)
    }
    @MainActor
    func testStorageFailurePreventsSendAndPostWriteFailureRetainsEvidence() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Keep draft"
        let attachment = try await image(tab)
        let persistence = tab.persist
        tab.persist = { throw RecoveryStore.InvalidArchive() }
        var writes = 0
        await tab.submit(pasteEnabled: true, prepare: { _ in ["/fixture/photo.jpg"] }) { _ in writes += 1 }
        XCTAssertEqual(writes, 0); XCTAssertEqual(tab.draft, "Keep draft"); XCTAssertNotNil(tab.persistenceError)
        tab.persist = persistence
        await tab.submit(pasteEnabled: true, prepare: { _ in ["/fixture/photo.jpg"] }) { _ in
            writes += 1
            tab.persist = { throw RecoveryStore.InvalidArchive() }
        }
        XCTAssertEqual(writes, 1); XCTAssertEqual(tab.draft, "Keep draft")
        XCTAssertEqual(tab.attachments, [attachment]); XCTAssertTrue(tab.deliveryUncertain)
        XCTAssertNoThrow(try tab.media.data(for: attachment))
        let restored = try XCTUnwrap(workspace(root: root).selected)
        XCTAssertTrue(restored.deliveryUncertain); XCTAssertEqual(restored.attachments, [attachment])
    }
    @MainActor
    func testSuccessfulSendPersistsNewEditsBeforeDeletingSentImages() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "First"
        let attachment = try await image(tab)
        await tab.submit(pasteEnabled: true, prepare: { _ in ["/fixture/photo.jpg"] }) { _ in tab.draft = "New edit" }
        let restored = try XCTUnwrap(workspace(root: root).selected)
        XCTAssertEqual(restored.draft, "New edit"); XCTAssertTrue(restored.attachments.isEmpty)
        XCTAssertFalse(restored.deliveryUncertain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try tab.media.url(for: attachment).path))
    }
    @MainActor
    func testCorruptArchiveIsNotOverwrittenAndOrphanCleanupRetainsReferencedImages() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Keep"
        let attachment = try await image(tab)
        var invalid = tab.saved
        invalid.session = RemoteSession(id: "$1", name: "Duplicate reference", instance: "123:456")
        XCTAssertThrowsError(try original.recovery!.save(SavedWorkspace(profile: original.connection.profile, selectedID: tab.id, tabs: [tab.saved, invalid])))
        let orphan = try await image(tab)
        tab.attachments.removeLast()
        try original.recovery!.removeOrphanedMedia(in: original.media)
        _ = workspace(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try tab.media.url(for: attachment).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try tab.media.url(for: orphan).path))
        let file = try original.recovery!.url(for: original.connection.profile)
        let corrupt = Data("not an archive".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try original.recovery!.removeOrphanedMedia(in: original.media))
        let failed = workspace(root: root)
        XCTAssertNotNil(failed.recoveryError)
        let newTab = addTab(failed); newTab.draft = "New unsaved edit"
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(newTab.persistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try tab.media.url(for: attachment).path))
    }
    @MainActor
    func testClosingTabAndBackgroundRetainOnlyIntendedData() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Background draft"
        let attachment = try await image(tab)
        original.background()
        XCTAssertEqual(try XCTUnwrap(workspace(root: root).selected).draft, "Background draft")
        original.close(tab.id)
        XCTAssertTrue(workspace(root: root).tabs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try tab.media.url(for: attachment).path))
        XCTAssertTrue(tab.closed)
    }
    @MainActor
    func testTranscriptInsertionIsAtomicAndRollsBackOnSaveFailure() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = workspace(root: root), tab = addTab(original)
        tab.draft = "Existing"; tab.pendingTranscript = "dictation"
        let persistence = tab.persist
        var attempts = 0
        tab.persist = {
            attempts += 1
            XCTAssertEqual(tab.draft, "Existing dictation")
            XCTAssertNil(tab.pendingTranscript)
            throw RecoveryStore.InvalidArchive()
        }
        tab.insertTranscript()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(tab.draft, "Existing"); XCTAssertEqual(tab.pendingTranscript, "dictation")
        let restored = try XCTUnwrap(workspace(root: root).selected)
        XCTAssertEqual(restored.draft, "Existing"); XCTAssertEqual(restored.pendingTranscript, "dictation")
        tab.persist = persistence; tab.insertTranscript()
        let committed = try XCTUnwrap(workspace(root: root).selected)
        XCTAssertEqual(committed.draft, "Existing dictation"); XCTAssertNil(committed.pendingTranscript)
        tab.insertTranscript()
        XCTAssertEqual(tab.draft, "Existing dictation")
    }

    @MainActor
    func testLegacyArchiveMigrationNeverEnablesAutomaticResume() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at:root) }
        let original = workspace(root:root), tab = addTab(original)
        tab.draft = "Legacy draft"; tab.pendingTranscript = "Keep transcript"
        let file = try original.recovery!.url(for:original.connection.profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        json["version"] = 1; json.removeValue(forKey:"resume"); json.removeValue(forKey:"sidebarExpanded")
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        original.resumePermission.set(true,for:original.connection.profile)
        let migrated = workspace(root:root)
        XCTAssertFalse(migrated.resumeDesired); XCTAssertTrue(migrated.resumeSessions.isEmpty)
        XCTAssertEqual(migrated.selected?.draft,"Legacy draft")
        XCTAssertEqual(migrated.selected?.pendingTranscript,"Keep transcript")
        migrated.selected?.draft += " edited"
        XCTAssertEqual(try migrated.recovery!.load(profile:migrated.connection.profile)?.version,2)
        XCTAssertFalse(workspace(root:root).resumeDesired)
    }
    @MainActor
    func testResumeIntentSurvivesBackgroundButDisconnectSurvivesFailedArchiveWrite() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at:root) }
        let original = workspace(root:root), tab = addTab(original)
        tab.draft = "Keep me"; original.sidebarExpanded = true
        tab.transport.connected = true; original.rememberAttachment(tab)
        original.background()
        let resumed = workspace(root:root)
        XCTAssertTrue(resumed.resumeDesired); XCTAssertEqual(resumed.resumeSessions,[tab.session])
        XCTAssertEqual(resumed.selected?.draft,"Keep me"); XCTAssertTrue(resumed.sidebarExpanded)
        XCTAssertFalse(resumed.connection.connected); XCTAssertFalse(resumed.selected!.transport.connected)
        // A corrupt archive refuses writes; Disconnect must still revoke consent.
        let file = try original.recovery!.url(for:original.connection.profile)
        let valid = try Data(contentsOf:file)
        try Data("unreadable".utf8).write(to:file)
        let failed = workspace(root:root); XCTAssertNotNil(failed.recoveryError)
        failed.disconnect()
        try valid.write(to:file) // simulate recovery of the older resumable archive
        XCTAssertFalse(workspace(root:root).resumeDesired)
        XCTAssertFalse(original.resumePermission.allows(MacConnection(host:"other.example",port:22,username:"fixture")))
    }
    @MainActor
    func testDeferredProtectedRecoveryAndClosedTabEligibility() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at:root) }
        let original = workspace(root:root), tab = addTab(original)
        tab.draft = "Protected"; tab.transport.connected = true; original.rememberAttachment(tab)
        var available = false
        let locked = SessionWorkspace(connection:original.connection,recovery:original.recovery,media:original.media,protectedDataAvailable:{ available })
        XCTAssertTrue(locked.tabs.isEmpty); XCTAssertNotNil(locked.recoveryError)
        XCTAssertThrowsError(try locked.saveRecovery())
        available = true; locked.restoreProtectedWorkspaceIfNeeded()
        XCTAssertEqual(locked.selected?.draft,"Protected"); XCTAssertTrue(locked.resumeDesired)
        locked.close(tab.id)
        XCTAssertTrue(workspace(root:root).resumeSessions.isEmpty)
        XCTAssertTrue(workspace(root:root).tabs.isEmpty)
    }

}

@MainActor
final class ForegroundResumeTests: XCTestCase {
    private let first = RemoteSession(id:"$0",name:"First",instance:"100:200")
    private let second = RemoteSession(id:"$1",name:"Second",instance:"100:201")
    private func make(_ operations:ResumeOperations, timeout:TimeInterval = 1) -> SessionWorkspace {
        let scope = "com.chadmux.resume-tests." + UUID().uuidString
        let connection = MacTransport(preferences:UserDefaults(suiteName:scope)!,secrets:SecretStore(service:scope))
        connection.profile = MacConnection(host:"fixture.example",port:22,username:"fixture")
        return SessionWorkspace(connection:connection,protectedDataAvailable:{true},resumeOperations:operations,resumeTimeout:timeout,resumeRetryDelay:0.001)
    }
    private func tab(_ session:RemoteSession, in workspace:SessionWorkspace) -> SessionTab {
        let tab = SessionTab(session:session,profile:workspace.connection.profile,secrets:workspace.connection.secrets)
        workspace.tabs.append(tab); return tab
    }
    func testExplicitConnectThenWarmReturnCoalescesAndAttachesOnlySelected() async {
        var connects = 0, attachments:[String] = []
        let sessions = [first,second]
        let workspace = make(ResumeOperations(connect:{ transport in connects += 1; transport.connected = true },
            list:{ _,_ in sessions },attach:{ tab,_ in attachments.append(tab.id); tab.transport.connected = true }))
        let a = tab(first,in:workspace), b = tab(second,in:workspace)
        a.draft = "Never submit me"; b.pendingTranscript = "Keep transcript"; b.deliveryUncertain = true
        workspace.selectedID = a.id
        workspace.becameActive(); await workspace.waitForResume()
        XCTAssertEqual(connects,0)
        workspace.retryConnection(); await workspace.waitForResume()
        XCTAssertEqual(attachments,[a.id]); XCTAssertTrue(workspace.resumeDesired)
        workspace.select(second); await workspace.waitForResume()
        XCTAssertEqual(attachments,[a.id,b.id])
        workspace.background(); workspace.becameActive(); workspace.becameActive()
        await workspace.waitForResume()
        XCTAssertEqual(connects,2); XCTAssertEqual(attachments,[a.id,b.id,b.id])
        XCTAssertFalse(a.transport.connected); XCTAssertTrue(b.transport.connected)
        XCTAssertEqual(workspace.selectedID,b.id); XCTAssertEqual(a.draft,"Never submit me")
        XCTAssertEqual(b.pendingTranscript,"Keep transcript"); XCTAssertTrue(b.deliveryUncertain)
        XCTAssertNil(a.submissionTask); XCTAssertNil(b.submissionTask)
        workspace.disconnect(); workspace.background(); workspace.becameActive(); await workspace.waitForResume()
        XCTAssertEqual(connects,2); XCTAssertFalse(workspace.resumeDesired)
    }
    func testTransientFailureRetriesOnlyOnceAndRepeatedActivationCannotResetBudget() async {
        var calls = 0
        let workspace = make(ResumeOperations(connect:{ _ in calls += 1; throw ConnectionFailure.network },list:{_,_ in []},attach:{_,_ in XCTFail("Unexpected attach")}))
        workspace.becameActive(); workspace.retryConnection(); await workspace.waitForResume()
        XCTAssertEqual(calls,2); XCTAssertEqual(workspace.resumeState,.unavailable)
        workspace.becameActive(); await workspace.waitForResume(); XCTAssertEqual(calls,2)
        workspace.retryConnection(); await workspace.waitForResume(); XCTAssertEqual(calls,4)
    }
    func testPermanentFailuresNeverRetry() async {
        for failure in [ConnectionFailure.authentication,.changedHost,.verificationRequired,.protectedData,.invalidProfile] {
            var calls = 0
            let workspace = make(ResumeOperations(connect:{ _ in calls += 1; throw failure },list:{_,_ in []},attach:{_,_ in XCTFail("Unexpected attach")}))
            workspace.becameActive(); workspace.retryConnection(); await workspace.waitForResume()
            XCTAssertEqual(calls,1); XCTAssertEqual(workspace.resumeState,.unavailable)
            XCTAssertFalse(workspace.resumeDesired)
        }
    }
    func testMissingOrReplacedSessionNeverAttachesAndPreservesDraft() async {
        var attaches = 0
        let replacement = RemoteSession(id:first.id,name:first.name,instance:"999:999")
        let workspace = make(ResumeOperations(connect:{$0.connected = true},list:{_,_ in [replacement]},attach:{_,_ in attaches += 1}))
        let original = tab(first,in:workspace); original.draft = "Keep original"; workspace.selectedID = original.id
        workspace.becameActive(); workspace.retryConnection(); await workspace.waitForResume()
        XCTAssertEqual(attaches,0); XCTAssertEqual(original.draft,"Keep original")
        XCTAssertEqual(original.session,first); XCTAssertEqual(workspace.resumeState,.unavailable)
    }
    func testBackgroundDuringDiscoveryIgnoresLateResult() async {
        var continuation:CheckedContinuation<[RemoteSession],Error>?
        var attaches = 0
        let workspace = make(ResumeOperations(connect:{$0.connected = true},list:{_,_ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        },attach:{_,_ in attaches += 1}))
        workspace.selectedID = tab(first,in:workspace).id
        workspace.becameActive(); workspace.retryConnection()
        while continuation == nil { await Task.yield() }
        workspace.background(); continuation?.resume(returning:[first])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(attaches,0); XCTAssertFalse(workspace.connection.connected)
        XCTAssertEqual(workspace.resumeState,.idle); XCTAssertTrue(workspace.sessions.isEmpty)
    }
    func testDeadlineClosesResourcesAndLateDiscoveryCannotChangeState() async throws {
        var continuation:CheckedContinuation<[RemoteSession],Error>?
        let workspace = make(ResumeOperations(connect:{$0.connected = true},list:{_,_ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        },attach:{_,_ in XCTFail("Unexpected attach")}),timeout:0.03)
        workspace.selectedID = tab(first,in:workspace).id
        workspace.becameActive(); workspace.retryConnection()
        while continuation == nil { await Task.yield() }
        try await Task.sleep(nanoseconds:60_000_000)
        XCTAssertEqual(workspace.resumeState,.unavailable); XCTAssertFalse(workspace.connection.connected)
        continuation?.resume(returning:[first]); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(workspace.resumeState,.unavailable); XCTAssertTrue(workspace.sessions.isEmpty)
    }
    func testChangingSelectionDuringAttachUsesNewTargetWithoutNewControlConnection() async {
        var continuation:CheckedContinuation<Void,Error>?
        var attached:[String] = []; var connects = 0
        let sessions = [first,second]
        let workspace = make(ResumeOperations(connect:{connects += 1; $0.connected = true},list:{_,_ in sessions},attach:{ tab,_ in
            attached.append(tab.id)
            if tab.id == "$0" { try await withCheckedThrowingContinuation { continuation = $0 } }
            else { tab.transport.connected = true }
        }))
        workspace.selectedID = tab(first,in:workspace).id; _ = tab(second,in:workspace)
        workspace.becameActive(); workspace.retryConnection()
        while continuation == nil { await Task.yield() }
        workspace.select(second); continuation?.resume(throwing:ConnectionFailure.cancelled)
        await workspace.waitForResume()
        XCTAssertEqual(connects,1); XCTAssertEqual(attached,[first.id,second.id])
        XCTAssertEqual(workspace.selectedID,second.id); XCTAssertTrue(workspace.selected!.transport.connected)
    }
    func testDisconnectAndProfileChangeInvalidatePendingDiscovery() async {
        for changeProfile in [false,true] {
            var continuation:CheckedContinuation<[RemoteSession],Error>?
            let workspace = make(ResumeOperations(connect:{$0.connected = true},list:{_,_ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            },attach:{_,_ in XCTFail("Unexpected attach")}))
            workspace.becameActive(); workspace.retryConnection()
            while continuation == nil { await Task.yield() }
            if changeProfile { workspace.connection.profile = MacConnection(host:"other.example",port:22,username:"fixture") }
            else { workspace.disconnect() }
            continuation?.resume(returning:[first]); for _ in 0..<10 { await Task.yield() }
            XCTAssertFalse(workspace.resumeDesired); XCTAssertTrue(workspace.sessions.isEmpty)
            XCTAssertFalse(workspace.connection.connected); XCTAssertEqual(workspace.resumeState,.idle)
        }
    }
}

extension ForegroundResumeTests {
    func testAttachmentFailureClassificationPreservesPermanentAndTransientReasons() {
        XCTAssertEqual(ConnectionFailure.attachment(MacTransport.SessionReplaced()),.sessionUnavailable)
        XCTAssertEqual(ConnectionFailure.attachment(ConnectionFailure.timeout),.timeout)
        XCTAssertEqual(ConnectionFailure.attachment(MacTransport.NotConnected()),.network)
        XCTAssertEqual(ConnectionFailure.attachment(CancellationError()),.cancelled)
    }
}

extension ForegroundResumeTests {
    func testEightSavedTabsRestoreOnlySelectedAndRenameRetainsOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let scope = "com.chadmux.eight-tabs." + UUID().uuidString
        let prefs = UserDefaults(suiteName:scope)!, secrets = SecretStore(service:scope)
        let connection = MacTransport(preferences:prefs,secrets:secrets)
        connection.profile = MacConnection(host:"fixture.example",port:22,username:"fixture")
        let sessions = (0..<8).map { RemoteSession(id:"$\($0)",name:"Session \($0)",instance:"100:\($0)") }
        var attachments:[String] = [], connects = 0
        let renamed = sessions.map { RemoteSession(id:$0.id,name:"Renamed "+$0.name,instance:$0.instance) }
        let operations = ResumeOperations(connect:{ connects += 1; $0.connected = true },list:{_,_ in renamed},attach:{tab,_ in attachments.append(tab.id); tab.transport.connected = true})
        let recovery = RecoveryStore(directory:root)
        let original = SessionWorkspace(connection:connection,recovery:recovery,protectedDataAvailable:{true},resumeOperations:operations)
        for session in sessions {
            let saved = tab(session,in:original); saved.draft = "Draft "+session.id
            saved.transport.connected = true; original.rememberAttachment(saved)
        }
        original.selectedID = "$6"; original.background()
        var unlocked = false
        let restored = SessionWorkspace(connection:connection,recovery:recovery,protectedDataAvailable:{unlocked},resumeOperations:operations)
        restored.becameActive(); XCTAssertTrue(restored.tabs.isEmpty); XCTAssertEqual(connects,0)
        unlocked = true; restored.becameActive(); restored.becameActive(); await restored.waitForResume()
        XCTAssertEqual(connects,1); XCTAssertEqual(attachments,["$6"])
        XCTAssertEqual(restored.tabs.map(\.id),sessions.map(\.id)); XCTAssertEqual(restored.selectedID,"$6")
        XCTAssertEqual(restored.selected?.name,"Renamed Session 6"); XCTAssertEqual(restored.selected?.draft,"Draft $6")
        restored.disconnect()
    }
}
