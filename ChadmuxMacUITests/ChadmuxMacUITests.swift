import XCTest
import AppKit

/// Mac window UI tests against disposable live tmux fixtures only
/// (test-transport.py --mac --multi-ui / --manage-ui). They drive the real
/// desktop, so they live in their own scheme, ChadmuxMacUI.
final class ChadmuxMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private struct Paths: Decodable { let projectsDir: String?; let claudeTmux: String?; let archPort: Int? }
    private func fixture(_ mode: String) throws -> (path: String, paths: Paths) {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Run test-transport.py --mac " + mode) }
        let paths = try JSONDecoder().decode(Paths.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard paths.claudeTmux != nil, paths.projectsDir != nil else { throw XCTSkip("Pass --claude-tmux to test-transport.py") }
        return (path, paths)
    }
    private func launch(_ argument: String, fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        // --ui-testing: pasted images come from a private test pasteboard, never the clipboard.
        app.launchArguments = [argument, "--ui-testing"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = fixture
        app.launch()
        app.activate()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// On macOS a static text's words are its value, not its label; accept either.
    private func matching(_ format: String, _ text: String) -> NSPredicate {
        NSPredicate(format: "label \(format) %@ OR value \(format) %@", text, text)
    }
    private func wait(_ element: XCUIElement, label format: String, _ value: String, timeout: TimeInterval = 20) {
        expectation(for: matching(format, value), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    private func text(_ app: XCUIApplication, _ format: String, _ value: String) -> XCUIElement {
        app.staticTexts.matching(matching(format, value)).firstMatch
    }
    /// Any element in the open sheet (form section headers are not always static texts).
    private func inSheet(_ app: XCUIApplication, _ format: String, _ value: String) -> XCUIElement {
        app.sheets.firstMatch.descendants(matching: .any).matching(matching(format, value)).firstMatch
    }
    private func string(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
    /// Open tabs are marked on their sidebar row (the cmux-style vertical tabs).
    private func isOpen(_ row: XCUIElement) -> Bool { (row.value as? String)?.hasPrefix("Open") == true }
    private func waitClosed(_ row: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let done = expectation(for: NSPredicate { _, _ in !self.isOpen(row) }, evaluatedWith: row)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }
    private func labelled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private func replace(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(text)
    }

    func testHostsTabsAndShortcutsAgainstLiveTmux() throws {
        let (path, paths) = try fixture("--multi-ui")
        let folder = paths.projectsDir! + "/phone project"
        let app = launch("--multi-host-live-fixture", fixture: path)
        let macShared = app.buttons["session.Mac.$0"], archShared = app.buttons["session.Arch.$0"]
        XCTAssertTrue(macShared.waitForExistence(timeout: 30))
        XCTAssertTrue(archShared.waitForExistence(timeout: 30))
        XCTAssertTrue(labelled(app, "mac-only").exists)
        XCTAssertTrue(labelled(app, "arch-only").exists)
        // The offline host fails on its own without holding up the others.
        let offlineStatus = text(app, "BEGINSWITH", "Offline status:")
        XCTAssertTrue(offlineStatus.waitForExistence(timeout: 10))
        wait(offlineStatus, label: "==", "Offline status: Offline", timeout: 40)
        XCTAssertFalse(app.buttons["New Claude session on Offline"].isEnabled)
        shot(app, "1 Three hosts: two connected, one offline")

        // The same session name on two hosts opens two tabs, each showing its host.
        let evidence = app.staticTexts["manage.fixture.evidence"]
        archShared.click()
        XCTAssertTrue(evidence.waitForExistence(timeout: 20))
        wait(evidence, label: "BEGINSWITH", "Arch|shared-name|")
        XCTAssertEqual(string(app.staticTexts["session.host"]), "Arch")
        macShared.click()
        wait(evidence, label: "BEGINSWITH", "Mac|shared-name|")
        XCTAssertEqual(string(app.staticTexts["session.host"]), "Mac")
        XCTAssertTrue(isOpen(macShared), "open tab marked on its row")
        XCTAssertTrue(isOpen(archShared))
        XCTAssertEqual(macShared.value as? String, "Open, selected")
        shot(app, "2 Two shared-name tabs across hosts")

        // Command-number follows the tab strip (hosts in sidebar order) across hosts.
        app.typeKey("2", modifierFlags: .command)
        wait(evidence, label: "BEGINSWITH", "Arch|shared-name|")
        app.typeKey("1", modifierFlags: .command)
        wait(evidence, label: "BEGINSWITH", "Mac|shared-name|")

        // Command-T offers a new session on the host on screen; Escape cancels.
        app.typeKey("t", modifierFlags: .command)
        let nameField = app.textFields["newSession.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(inSheet(app, "==[c]", "Folder on Mac").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 5))

        // + on Arch creates on Arch only and opens it.
        app.buttons["New Claude session on Arch"].click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(inSheet(app, "==[c]", "Folder on Arch").exists)
        nameField.click(); nameField.typeText("arch-made")
        replace(app.textFields["newSession.folder"], with: folder)
        shot(app, "3 New session sheet on Arch")
        app.buttons["newSession.create"].click()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 20), app.staticTexts["newSession.error"].exists ? string(app.staticTexts["newSession.error"]) : "sheet stayed open")
        wait(evidence, label: "==", "Arch|arch-made|claude|" + folder)
        XCTAssertEqual(string(app.staticTexts["session.host"]), "Arch")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "arch-made")).count, 1, "listed under Arch only")
        XCTAssertTrue(isOpen(labelled(app, "arch-made")))
        shot(app, "4 Created on Arch with + and opened in a tab")

        // − on Mac ends only Mac's session, after a confirmation naming it and the host.
        app.buttons["End session mac-only on Mac"].click()
        let endButton = app.sheets.buttons["End session"].firstMatch
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        XCTAssertTrue(inSheet(app, "CONTAINS", "on Mac, including any Claude conversation").exists)
        shot(app, "5 End confirmation names session and host")
        endButton.click()
        XCTAssertTrue(app.buttons["End session mac-only on Mac"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(labelled(app, "arch-only").exists)

        // Command-W closes the tab on screen; the tmux session keeps running and stays listed.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitClosed(labelled(app, "arch-made")))
        XCTAssertTrue(app.buttons["End session arch-made on Arch"].exists, "closing a tab never ends the session")
        XCTAssertTrue(app.windows.firstMatch.exists, "Command-W closed the tab, not the window")
        // Command-R refreshes every host; the offline host's error stays in its own section.
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.buttons["End session arch-made on Arch"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "BEGINSWITH", "Offline error:").exists)
        shot(app, "6 Tab closed with Command-W; session still listed")
    }

    func testCreateAndEndSessionsAgainstLiveTmux() throws {
        let (path, paths) = try fixture("--manage-ui")
        let folder = paths.projectsDir! + "/phone project"
        let app = launch("--session-manage-live-fixture", fixture: path)
        let existing = labelled(app, "existing")
        XCTAssertTrue(existing.waitForExistence(timeout: 20))
        let endExisting = app.buttons["End session existing on Mac"]
        XCTAssertTrue(endExisting.exists)

        // "replace-me" was replaced after listing: ending it is refused.
        app.buttons["End session replace-me on Mac"].click()
        let endButton = app.sheets.buttons["End session"].firstMatch
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        endButton.click()
        let error = app.staticTexts["connection.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertEqual(string(error), "“replace-me” was replaced by a newer session with the same name, so it was not ended. Review the refreshed list before trying again.")
        XCTAssertTrue(labelled(app, "replace-me").exists)
        shot(app, "1 Replaced session refused")

        // Create from the + button, then duplicate and missing-folder errors inline.
        app.buttons["New Claude session on Mac"].click()
        let nameField = app.textFields["newSession.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["newSession.create"].isEnabled)
        nameField.click(); nameField.typeText("bad name")
        XCTAssertTrue(app.staticTexts["newSession.nameProblem"].exists)
        replace(nameField, with: "mac-made")
        replace(app.textFields["newSession.folder"], with: folder)
        app.buttons["newSession.create"].click()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 20))
        let evidence = app.staticTexts["manage.fixture.evidence"]
        wait(evidence, label: "==", "claude|" + folder + "|sleep")
        XCTAssertTrue(isOpen(labelled(app, "mac-made")))
        shot(app, "2 Created session opened in a tab")

        // No input bar: ⌘V with an image on the clipboard, in the terminal, uploads it to the
        // host and pastes its path (the fake claude has bracketed paste on, as Claude does).
        XCTAssertFalse(app.textViews["composer.draft"].exists, "no input bar on the Mac")
        let board = NSPasteboard(name: NSPasteboard.Name("com.ascinocco.chadmux.uitest-paste"))
        board.clearContents()
        board.setData(Self.invented(), forType: .png)
        // The terminal takes focus once attached; press ⌘V until the upload starts.
        let dropStatus = app.staticTexts["terminal.dropStatus"]
        for _ in 0..<20 where !dropStatus.exists {
            app.typeKey("v", modifierFlags: .command)
            _ = dropStatus.waitForExistence(timeout: 1)
        }
        let added = XCTNSPredicateExpectation(predicate: matching("==", "Added image to the prompt"), object: dropStatus)
        if XCTWaiter().wait(for: [added], timeout: 20) != .completed {
            XCTFail("not added: \(dropStatus.exists ? string(dropStatus) : "no status")")
        }
        shot(app, "2b Pasted image uploaded and its path pasted")

        // Text: ⌘V pastes the clipboard's text into the terminal, and tmux's copy (OSC 52)
        // reaches the Mac clipboard. "existing" runs cat, which echoes the paste; the
        // fixture then has tmux copy "copied TOKEN", as a mouse selection in tmux does.
        labelled(app, "existing").click()
        let token = "t" + UUID().uuidString.prefix(8)
        board.clearContents(); board.setString("copy-request " + token, forType: .string)
        let copied = { board.string(forType: .string) == "copied " + token }
        for _ in 0..<20 where !copied() {
            app.typeKey("v", modifierFlags: .command)
            for _ in 0..<15 where !copied() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        XCTAssertEqual(board.string(forType: .string), "copied " + token, "pasted text reached the host, and tmux's copy reached the clipboard")
        // Cmd-C with no selection in the terminal leaves the clipboard alone.
        board.clearContents(); board.setString("keep", forType: .string)
        app.typeKey("c", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(board.string(forType: .string), "keep", "no selection: the clipboard is not emptied")
        // Select All, then Cmd-C copies the terminal's own text.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        for _ in 0..<50 where board.string(forType: .string) == "keep" { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(board.string(forType: .string)?.contains("copy-request " + token) == true, "Cmd-C copies the selection")
        board.releaseGlobally()
        shot(app, "2c Text pasted and copied")
        labelled(app, "mac-made").click()

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["newSession.folder"].value as? String, folder, "the last folder used is offered")
        nameField.click(); nameField.typeText("mac-made")
        app.buttons["newSession.create"].click()
        let sheetError = app.staticTexts["newSession.error"]
        XCTAssertTrue(sheetError.waitForExistence(timeout: 20))
        XCTAssertEqual(string(sheetError), "claude-tmux: session 'mac-made' already exists")
        replace(nameField, with: "no-folder")
        replace(app.textFields["newSession.folder"], with: "~/definitely-missing-folder")
        app.buttons["newSession.create"].click()
        wait(sheetError, label: "==", "claude-tmux: folder '~/definitely-missing-folder' does not exist")
        shot(app, "3 Missing folder error inline")
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 5))
        XCTAssertFalse(labelled(app, "no-folder").exists)

        // Rename with the hover pencil; a taken name is refused inline.
        app.buttons["Rename session existing on Mac"].click()
        let renameField = app.textFields["renameSession.name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        XCTAssertEqual(renameField.value as? String, "existing")
        replace(renameField, with: "replace-me")
        app.buttons["renameSession.rename"].click()
        let renameError = app.staticTexts["renameSession.error"]
        XCTAssertTrue(renameError.waitForExistence(timeout: 20))
        XCTAssertEqual(string(renameError), "“replace-me” is already a session on Mac. Choose another name.")
        replace(renameField, with: "renamed-here")
        shot(app, "3b Rename sheet")
        app.buttons["renameSession.rename"].click()
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 20))
        XCTAssertTrue(labelled(app, "renamed-here").waitForExistence(timeout: 10))
        XCTAssertFalse(labelled(app, "existing").exists)
        // And back with right-click > Rename…
        labelled(app, "renamed-here").rightClick()
        let renameItem = app.menuItems["Rename…"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5))
        renameItem.click()
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replace(renameField, with: "existing")
        app.buttons["renameSession.rename"].click()
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 20))
        XCTAssertTrue(endExisting.waitForExistence(timeout: 10))

        // End with Cancel changes nothing.
        endExisting.click()
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(endButton.waitForNonExistence(timeout: 5))
        app.buttons["Refresh Mac sessions"].click()
        XCTAssertTrue(endExisting.waitForExistence(timeout: 10), "still running after Cancel")

        // Ending the open tab's session keeps the tab until it is closed.
        app.buttons["End session mac-made on Mac"].click()
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        endButton.click()
        XCTAssertTrue(app.buttons["End session mac-made on Mac"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(isOpen(labelled(app, "mac-made")), "the tab remains until explicitly closed")
        XCTAssertTrue(text(app, "==", "Session no longer exists").waitForExistence(timeout: 10))
        shot(app, "4 Ended session: tab kept")
    }
}

/// Dictation into a live session: an injected recorder (the microphone is never
/// opened) and transcriber; the text reaches the pane pasted, with no Enter.
extension ChadmuxMacUITests {
    func testDictationPastesIntoTheTerminalWithoutEnterAgainstLiveTmux() throws {
        let (path, _) = try fixture("--manage-ui")
        let token = "d" + String(UUID().uuidString.filter { $0.isLetter || $0.isNumber }.prefix(10))
        let app = XCUIApplication()
        app.launchArguments = ["--session-manage-live-fixture", "--dictation-live-fixture", "--ui-testing"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = path
        app.launchEnvironment["CHADMUX_DICTATION_TOKEN"] = token
        app.launch()
        app.activate()
        // The fixture reports, over OSC 52 to the private test pasteboard, how many
        // times the pasted transcript appears in the pane: cat echoes typed text once
        // and would repeat the line after an Enter.
        let board = NSPasteboard(name: NSPasteboard.Name("com.ascinocco.chadmux.uitest-paste"))
        board.clearContents()
        defer { board.releaseGlobally() }
        func heard(_ count: Int, timeout: TimeInterval = 20) -> Bool {
            let expected = "heard \(token) x\(count)"
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if board.string(forType: .string) == expected { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            return false
        }
        let session = labelled(app, "dictation")
        XCTAssertTrue(session.waitForExistence(timeout: 30))
        session.click()
        XCTAssertTrue(heard(0), "the fixture reports the pane: \(board.string(forType: .string) ?? "nothing")")

        let mic = app.buttons["terminal.dictate"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertEqual(mic.label, "Dictate")
        let status = app.staticTexts["terminal.dictationStatus"]
        let recording = { self.wait(mic, label: "==", "Stop dictation and paste", timeout: 10) }

        // Esc discards the recording; nothing is pasted.
        mic.click(); recording()
        shot(app, "1 Recording")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        wait(status, label: "==", "Dictation cancelled. Nothing was pasted.")
        XCTAssertEqual(mic.label, "Dictate")
        // So does ×.
        mic.click(); recording()
        app.buttons["terminal.dictationCancel"].click()
        wait(mic, label: "==", "Dictate", timeout: 10)
        XCTAssertTrue(heard(0, timeout: 2), "cancelled: nothing reached the pane")

        // Click, click: transcribed, then pasted into the prompt without Enter.
        mic.click(); recording()
        mic.click()
        wait(status, label: "==", "Dictation pasted. Edit it, then press Enter.")
        XCTAssertTrue(heard(1), "pasted once, newline and controls stripped: \(board.string(forType: .string) ?? "nothing")")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(board.string(forType: .string), "heard \(token) x1", "no Enter: cat has not repeated the line")
        shot(app, "2 Transcript pasted without Enter")

        // "Live" still works beside the mic: scroll into tmux history, then return.
        let live = app.buttons["Return to Live"]
        // The terminal's AppKit view has no identifier of its own: scroll over its middle.
        let terminal = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<10 where !live.exists {
            terminal.scroll(byDeltaX: 0, deltaY: 8)
            _ = live.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(live.exists, "scrolling back shows Live")
        XCTAssertTrue(mic.exists && mic.isHittable, "the mic stays beside Live")
        XCTAssertLessThan(live.frame.maxX, mic.frame.minX, "Live sits to the mic's left")
        shot(app, "3 Live beside the mic")
        live.click()
        XCTAssertTrue(live.waitForNonExistence(timeout: 10), "Live returns to live output")
        XCTAssertTrue(heard(1, timeout: 2), "the pasted text is still there, once")
    }
}

/// Composer on the Mac, over offline view fixtures (no SSH): drafts, images, dictation.
extension ChadmuxMacUITests {
    private func offline(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        app.activate()
        return app
    }

    func testTheMacHasNoInputBar() {
        let app = offline(["--reset-test-profile", "--composer-ui-fixture"])
        XCTAssertTrue(app.buttons["session.Mac.$1"].waitForExistence(timeout: 10))
        app.buttons["session.Mac.$0"].click()
        for gone in ["composer.draft", "composer.send", "dictation.record"] {
            XCTAssertFalse(app.descendants(matching: .any)[gone].exists, gone)
        }
        for gone in ["Choose images", "Terminal keys", "Record dictation"] {
            XCTAssertFalse(app.buttons[gone].exists, gone)
        }
        shot(app, "No input bar")
    }

    func testWindowButtonsAndSidebarCollapse() {
        let app = offline(["--reset-test-profile", "--composer-ui-fixture"])
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["session.Mac.$1"].waitForExistence(timeout: 10))
        // The standard window buttons stay with the hidden title bar.
        XCTAssertTrue(window.buttons["_XCUI:CloseWindow"].exists, "close")
        XCTAssertTrue(window.buttons["_XCUI:MinimizeWindow"].exists, "minimize")
        XCTAssertTrue(window.buttons["_XCUI:FullScreenWindow"].exists, "zoom/full screen")
        let session = app.buttons["session.Mac.$1"]
        XCTAssertTrue(session.isHittable)
        shot(app, "0 Window buttons with the sidebar shown")

        app.buttons["Hide sidebar"].click()
        XCTAssertTrue(app.buttons["Show sidebar"].waitForExistence(timeout: 5))
        XCTAssertFalse(session.isHittable, "the sidebar is collapsed")
        shot(app, "0b Sidebar hidden")
        app.buttons["Show sidebar"].click()
        XCTAssertTrue(app.buttons["Hide sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(session.isHittable)

        // View ▸ Hide Sidebar, Control-Command-S, both ways.
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(app.buttons["Show sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Show Sidebar"].exists, "the menu title follows the state")
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(app.buttons["Hide sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(session.isHittable)
    }

    /// A small invented solid-colour PNG.
    static func invented() -> Data {
        let image = NSImage(size: NSSize(width: 48, height: 48))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 48, height: 48).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
}
