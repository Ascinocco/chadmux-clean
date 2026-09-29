import XCTest
import AppKit
@testable import Chadmux

/// The Mac window's tab strip, shortcuts and menus, over injected hosts: no network.
@MainActor
final class MacWindowTests: XCTestCase {
    private let mac = MacConnection(host: "mac.example", port: 22, username: "user")
    private let arch = MacConnection(host: "arch.example", port: 22, username: "user")
    private let first = RemoteSession(id: "$0", name: "first", instance: "100:1")
    private let second = RemoteSession(id: "$1", name: "second", instance: "100:1")

    private func model(offline: Set<String> = []) async throws -> (HostsModel, UUID, UUID) {
        struct Unreachable: Error {}
        let scope = "com.chadmux.mac-window-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: scope)!
        let images = FileManager.default.temporaryDirectory.appendingPathComponent(scope)
        addTeardownBlock { preferences.removePersistentDomain(forName: scope); try? FileManager.default.removeItem(at: images) }
        let sessions = [first, second]
        let hosts = HostsModel(preferences: preferences, secrets: SecretStore(service: scope), recovery: nil,
                               media: MediaStore(directory: images)) { host, model in
            let operations = ResumeOperations(
                connect: { transport in
                    if offline.contains(transport.profile.host) { throw Unreachable() }
                    transport.connected = true
                },
                list: { _, _ in sessions },
                attach: { tab, _ in tab.transport.connected = true })
            return SessionWorkspace(connection: MacTransport(preferences: model.preferences, secrets: model.secrets, profile: host.connection),
                                    voice: model.voice, protectedDataAvailable: { true }, resumeOperations: operations,
                                    resumeTimeout: 2, resumeRetryDelay: 0.001)
        }
        let macHost = HostProfile(label: "Mac", connection: mac), archHost = HostProfile(label: "Arch", connection: arch)
        try hosts.add(macHost); try hosts.add(archHost)
        hosts.becameActive()
        for (_, workspace) in hosts.orderedWorkspaces { workspace.retryConnection() }
        for (_, workspace) in hosts.orderedWorkspaces { await workspace.waitForResume() }
        return (hosts, macHost.id, archHost.id)
    }
    private func open(_ session: RemoteSession, on id: UUID, in hosts: HostsModel) async {
        hosts.select(session, on: id)
        await hosts.workspace(for: id)?.waitForResume()
    }

    func testTabsRunAcrossHostsInHostOrderAndCommandNumberSelectsThem() async throws {
        let (hosts, macID, archID) = try await model()
        await open(first, on: archID, in: hosts)
        await open(second, on: macID, in: hosts)
        await open(first, on: macID, in: hosts)
        XCTAssertEqual(MacTabs.all(hosts).map { "\($0.host.label):\($0.tab.name)" }, ["Mac:second", "Mac:first", "Arch:first"],
                       "hosts in sidebar order, each host's tabs in the order they opened")
        XCTAssertEqual(MacTabs.selected(hosts)?.host.id, macID)
        XCTAssertEqual(MacTabs.selected(hosts)?.tab.name, "first")

        MacTabs.select(number: 3, in: hosts)
        XCTAssertEqual(hosts.selectedHostID, archID, "Command-3 crosses to the other host")
        XCTAssertEqual(MacTabs.selected(hosts)?.tab.name, "first")
        MacTabs.select(number: 1, in: hosts)
        XCTAssertEqual(hosts.selectedHostID, macID)
        XCTAssertEqual(MacTabs.selected(hosts)?.tab.name, "second")
        MacTabs.select(number: 4, in: hosts)
        MacTabs.select(number: 0, in: hosts)
        XCTAssertEqual(MacTabs.selected(hosts)?.tab.name, "second", "a number with no tab does nothing")
        XCTAssertEqual(hosts.totalTabs, 3)
    }

    func testControlCommandBracketsCycleTabsAcrossHostsAndWrap() async throws {
        let (hosts, macID, archID) = try await model()
        await open(first, on: archID, in: hosts)
        await open(second, on: macID, in: hosts)
        // Order: Mac:second, Arch:first. Selected: Mac:second.
        MacTabs.cycle(by: 1, in: hosts)
        XCTAssertEqual(hosts.selectedHostID, archID)
        MacTabs.cycle(by: 1, in: hosts)
        XCTAssertEqual(hosts.selectedHostID, macID, "wraps to the first")
        MacTabs.cycle(by: -1, in: hosts)
        XCTAssertEqual(hosts.selectedHostID, archID, "and backwards")
    }

    func testCloseTabIsImmediateOnTheMac() async throws {
        let (hosts, macID, _) = try await model()
        await open(first, on: macID, in: hosts)
        await open(second, on: macID, in: hosts)
        let actions = MacWindowActions(model: hosts)
        let workspace = try XCTUnwrap(hosts.workspace(for: macID))

        // No input bar on the Mac: a draft saved by an older version is not shown,
        // so there is nothing visible to protect and no prompt about it.
        workspace.selected?.draft = "left over from the old composer"
        workspace.selected?.pendingTranscript = "dictated"
        XCTAssertFalse(MacTabs.needsConfirmation(try XCTUnwrap(MacTabs.selected(hosts))))
        actions.closeSelectedTab()
        XCTAssertNil(actions.closing)
        XCTAssertEqual(workspace.tabs.map(\.name), ["first"], "closes at once; tmux keeps running")
        XCTAssertEqual(MacTabs.selected(hosts)?.tab.name, "first", "the next tab is selected")
        actions.closeSelectedTab()
        XCTAssertNil(MacTabs.selected(hosts))
        actions.closeSelectedTab()
        XCTAssertNil(actions.closing, "with no tab, Close Tab does nothing")
    }

    func testNewSessionGoesToTheHostOnScreenOrTheFirstConnectedOne() async throws {
        let (hosts, macID, archID) = try await model(offline: ["mac.example"])
        let actions = MacWindowActions(model: hosts)
        hosts.selectedHostID = macID
        XCTAssertEqual(MacTabs.newSessionHost(hosts), archID, "the host on screen is offline, so the connected one")
        actions.newSession()
        XCTAssertEqual(actions.creatingOn, archID)
        hosts.selectedHostID = archID
        XCTAssertEqual(MacTabs.newSessionHost(hosts), archID)
        hosts.workspace(for: archID)?.disconnect()
        XCTAssertNil(MacTabs.newSessionHost(hosts), "no connected host, no new session")
        actions.creatingOn = nil
        actions.newSession()
        XCTAssertEqual(actions.creatingOn, archID, "then the host on screen, whose sheet says to connect first")
    }

    func testSidebarStartsShownAndItsStateIsRemembered() throws {
        let scope = "com.chadmux.mac-window-tests.sidebar." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { preferences.removePersistentDomain(forName: scope) }
        let hosts = HostsModel(preferences: preferences, secrets: SecretStore(service: scope), recovery: nil)
        let actions = MacWindowActions(model: hosts, preferences: preferences)
        XCTAssertTrue(actions.sidebarVisible, "shown on first launch (unlike the phone's default)")
        actions.toggleSidebar()
        XCTAssertFalse(MacWindowActions(model: hosts, preferences: preferences).sidebarVisible, "remembered")
        actions.toggleSidebar()
        XCTAssertTrue(MacWindowActions(model: hosts, preferences: preferences).sidebarVisible)
    }

    /// The app's real menu bar, built from its SwiftUI commands.
    func testMenusCarryTheSessionAndTerminalShortcuts() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func item(_ title: String) -> NSMenuItem? {
            func search(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let submenu = item.submenu, let found = search(submenu) { return found }
                }
                return nil
            }
            return search(menu)
        }
        func assertShortcut(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, line: UInt = #line) {
            guard let found = item(title) else { return XCTFail("no menu item \(title)", line: line) }
            XCTAssertEqual(found.keyEquivalent, key, title, line: line)
            XCTAssertEqual(found.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]), modifiers, title, line: line)
        }
        assertShortcut("New Claude Session…", "t")
        assertShortcut("Close Tab", "w")
        assertShortcut("Refresh All Hosts", "r")
        XCTAssertNotNil(item("Rename Session…"), "Sessions > Rename Session…")
        for number in 1...8 { assertShortcut("Show Tab \(number)", "\(number)") }
        assertShortcut("Clear Screen", "k")
        assertShortcut("Previous Tab", "[", [.control, .command])
        assertShortcut("Next Tab", "]", [.control, .command])
        XCTAssertTrue(item("Hide Sidebar") != nil || item("Show Sidebar") != nil, "View ▸ Show/Hide Sidebar")
        XCTAssertNotNil(item("Find…") ?? item("Find"), "Terminal ▸ Find")
        XCTAssertNil(item("New Window"), "Command-T/N open sessions, not duplicate windows")

        // Command-W belongs to Close Tab alone: the window's Close gives it up.
        let file = try XCTUnwrap(item("Close Tab")?.menu)
        let commandW = file.items.filter { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == .command }
        XCTAssertEqual(commandW.map(\.title), ["Close Tab"])
    }
}
