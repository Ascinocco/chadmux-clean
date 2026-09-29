import XCTest

final class ChadmuxUITests: XCTestCase {
    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Each scenario launches a fresh app. Rotate SpringBoard rather than
        // waiting for a previous live terminal's animation to become idle.
        XCUIApplication().terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testConnectionSettingsRejectInvalidInput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Add a host"].waitForExistence(timeout:5))
        app.buttons["Connection settings"].firstMatch.tap()
        // With no hosts, settings open straight into adding the first one, labelled Mac.
        XCTAssertEqual(app.textFields["host.label"].value as? String, "Mac")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.staticTexts["Enter a host, username and port between 1 and 65535."].waitForExistence(timeout:3))
        app.swipeUp()  // form rows below the fold are created on demand
        XCTAssertTrue(app.buttons["Copy public key"].waitForExistence(timeout:3))
        app.buttons["host.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Add a host"].waitForExistence(timeout:3))
    }

    @MainActor
    func testSavedConnectionSurvivesRelaunchWithoutAutoConnecting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile"]
        app.launch()
        app.buttons["Connection settings"].firstMatch.tap()
        let host = app.textFields["connection.host"]
        host.tap(); host.typeText("fixture.example")
        let username = app.textFields["connection.username"]
        username.tap(); username.typeText("fixture")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout:3))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout:5))
        app.buttons["Connection settings"].firstMatch.tap()
        app.buttons["hosts.row.Mac"].tap()
        XCTAssertEqual(app.textFields["connection.host"].value as? String,"fixture.example")
        XCTAssertEqual(app.textFields["connection.username"].value as? String,"fixture")
    }
    @MainActor
    func testSidebarStartsCollapsedAndCanToggleWithoutConnection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile"]
        app.launch()
        // There is no sidebar until a host exists.
        XCTAssertFalse(app.buttons["sessions.toggle"].exists)
        app.buttons["Connection settings"].firstMatch.tap()
        app.textFields["connection.host"].tap(); app.textFields["connection.host"].typeText("fixture.example")
        app.textFields["connection.username"].tap(); app.textFields["connection.username"].typeText("fixture")
        app.buttons["connection.save"].tap()
        let toggle = app.buttons["sessions.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Expand sessions")
        toggle.tap()
        XCTAssertEqual(toggle.label, "Collapse sessions")
        XCTAssertTrue(app.buttons["Refresh Mac sessions"].exists)
        XCTAssertFalse(app.buttons["Refresh Mac sessions"].isEnabled)
        toggle.tap()
        XCTAssertEqual(toggle.label, "Expand sessions")
        XCTAssertFalse(app.buttons["Refresh Mac sessions"].exists)
    }

    @MainActor
    func testConnectedSessionStillShowsResizeError() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--session-error-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["session.error"].exists)
        XCTAssertEqual(app.staticTexts["session.error"].label, "Terminal resize failed. Reconnect to restore the correct size.")
    }

    @MainActor
    func testComposerRetainsDraftsAndControlsWithKeyboardOpenOrClosed() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--composer-ui-fixture"]
        app.launch()
        let draft = app.descendants(matching: .any)["composer.draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout:5))
        draft.tap(); draft.typeText("First line\nSecond line")
        let controls = ["Terminal Escape", "Terminal Tab", "Terminal arrow up", "Terminal arrow down", "Terminal arrow left", "Terminal arrow right", "Terminal Enter", "Terminal Control-C"]
        for name in controls { XCTAssertTrue(app.buttons[name].isHittable, name) }
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        app.buttons["Dismiss keyboard"].tap()
        for name in controls { XCTAssertTrue(app.buttons[name].isHittable, name) }
        app.buttons["sessions.toggle"].tap()
        app.buttons["session.Mac.$1"].tap()
        app.buttons["sessions.toggle"].tap()
        XCTAssertEqual(draft.value as? String, "")
        draft.tap(); draft.typeText("Other draft")
        app.buttons["Dismiss keyboard"].tap()
        app.buttons["sessions.toggle"].tap()
        app.buttons["session.Mac.$0"].tap()
        app.buttons["sessions.toggle"].tap()
        XCTAssertEqual(draft.value as? String,"First line\nSecond line")
    }

    @MainActor
    func testSwipeDownDismissesComposerKeyboardWithoutChangingDraft() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--composer-ui-fixture"]
        app.launch()
        let draft = app.descendants(matching:.any)["composer.draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout:5))
        for addition in ["", "Keep this draft", "\nSecond line\nThird line\nFourth line\nFifth line\nSixth line"] {
            draft.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
            if !addition.isEmpty { draft.typeText(addition) }
            let original = draft.value as? String
            draft.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).press(forDuration:0.05,thenDragTo:draft.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).withOffset(CGVector(dx:0,dy:90)))
            expectation(for:NSPredicate { _,_ in app.keyboards.count == 0 },evaluatedWith:app)
            waitForExpectations(timeout:3)
            XCTAssertEqual(draft.value as? String,original)
            XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        }
        draft.tap()
        draft.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)).press(forDuration:0.05,thenDragTo:draft.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        draft.press(forDuration:1)
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Select All")).firstMatch.waitForExistence(timeout:3))
        app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Select All")).firstMatch.tap()
        let selectedDraft = draft.value as? String
        // With a native selection active, a downward movement must keep focus.
        draft.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).press(forDuration:0.05,thenDragTo:draft.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).withOffset(CGVector(dx:0,dy:70)))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(draft.value as? String,selectedDraft)
    }

    @MainActor
    func testPhotoPreviewRemovalAndCameraCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--photo-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Preview image 2"].waitForExistence(timeout:5))
        app.buttons["Preview image 1"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout:3))
        app.buttons["Done"].tap()
        app.buttons["Remove image 1"].tap()
        XCTAssertTrue(app.buttons["Preview image 1"].exists)
        XCTAssertFalse(app.buttons["Preview image 2"].exists)
        app.buttons["Take photo"].tap()
        // Legitimate outcomes, depending on the simulator: the one-time camera
        // permission alert (a freshly created simulator), camera UI with capture
        // disabled, or no camera at all. Handle whichever appears.
        let springboard = XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        let cancel = app.buttons["Cancel"]
        let unavailable = app.staticTexts["Camera is unavailable here. Choose photos from your library."]
        let denied = app.staticTexts["Camera access is off. Enable it for Chadmux in iPhone Settings, or choose library images."]
        // (Once declined, later taps go straight to the "access is off" message.)
        expectation(for:NSPredicate { _,_ in permission.exists || cancel.exists || unavailable.exists || denied.exists },evaluatedWith:app)
        waitForExpectations(timeout:10)
        if permission.exists {
            permission.buttons.element(boundBy:0).tap()   // "Don't Allow"
            XCTAssertTrue(denied.waitForExistence(timeout:5), "declining explains how to enable the camera")
        } else if cancel.exists {
            cancel.tap()
        }
        XCTAssertTrue(app.buttons["Preview image 1"].exists)
        XCTAssertTrue(app.buttons["Choose photos"].exists)
        let draft = app.descendants(matching:.any)["composer.draft"].firstMatch
        draft.tap(); draft.typeText("Check remaining image")
        XCTAssertTrue(app.buttons["Terminal Enter"].isHittable)
        app.buttons["Dismiss keyboard"].tap()
        app.buttons["Remove image 1"].tap()
        XCTAssertFalse(app.buttons["Preview image 1"].exists)
    }

    @MainActor
    func testPendingDictationRequiresInsertionAndRemainsEditable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--composer-ui-fixture", "--voice-ui-fixture"]
        app.launch()
        let draft = app.descendants(matching: .any)["composer.draft"].firstMatch
        XCTAssertTrue(app.buttons["dictation.insert"].waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "My revised draft")
        XCTAssertFalse(app.buttons["dictation.record"].isEnabled)
        app.buttons["dictation.insert"].tap()
        XCTAssertEqual(draft.value as? String, "My revised draft Please inspect the test failure")
        XCTAssertFalse(app.buttons["dictation.insert"].exists)
        draft.tap(); draft.typeText(" carefully")
        XCTAssertTrue((draft.value as? String)?.contains("carefully") == true)
        XCTAssertTrue((draft.value as? String)?.contains("My revised draft Please inspect the test failure") == true)
        app.buttons["Dismiss keyboard"].tap()
        app.buttons["dictation.record"].tap()
        XCTAssertEqual(app.staticTexts["dictation.status"].label, "Add the transcription token for Mac in Connection settings first.")
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
    }

    @MainActor
    func testDraftAndImagesSurviveProcessRelaunchOffline() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile", "--photo-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Preview image 2"].waitForExistence(timeout: 5))
        let draft = app.descendants(matching: .any)["composer.draft"].firstMatch
        draft.tap(); draft.typeText("Keep across relaunch")
        app.buttons["Dismiss keyboard"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep across relaunch")
        XCTAssertTrue(app.buttons["Preview image 1"].exists)
        XCTAssertTrue(app.buttons["Preview image 2"].exists)
        XCTAssertTrue(app.staticTexts["Restored offline"].exists)
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        app.buttons["sessions.toggle"].tap()
        app.buttons["Close Fixture on Mac"].tap()
        app.buttons["Discard draft and close"].tap()
        app.terminate(); app.launch()
        XCTAssertFalse(app.buttons["Preview image 1"].exists)
    }

}

extension ChadmuxUITests {
    @MainActor
    func testNativeGesturesAgainstLiveTmux() throws {
        XCUIDevice.shared.orientation = .portrait
        guard let fixture = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], fixture.hasPrefix("/") else { throw XCTSkip("Run test-transport.py --native-ui") }
        let app = XCUIApplication()
        app.launchArguments = ["--native-scroll-live-fixture"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = fixture
        app.launch()
        let evidence = app.staticTexts["native.fixture.evidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout:20))
        let live = NSPredicate(format:"label == %@","Live terminal rendered")
        expectation(for:live,evaluatedWith:evidence)
        waitForExpectations(timeout:10)
        let surface = app.descendants(matching:.any)["terminal.surface"].firstMatch
        XCTAssertFalse(app.buttons["Touch controls"].exists)
        // The first tap outside sessions must not reach the live terminal,
        // composer Send, or Disconnect underneath the dismissal layer.
        let sidebar = app.buttons["sessions.toggle"]
        sidebar.tap()
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5)).tap()
        XCTAssertEqual(sidebar.label,"Expand sessions")
        XCTAssertEqual(app.keyboards.count,0)
        let retainedDraft = app.descendants(matching:.any)["composer.draft"].firstMatch
        retainedDraft.tap(); retainedDraft.typeText("Retain this draft")
        app.buttons["Dismiss keyboard"].tap()
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        XCTAssertFalse(app.staticTexts["composer.status"].exists)
        sidebar.tap()
        app.buttons["composer.send"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertEqual(sidebar.label,"Expand sessions")
        XCTAssertEqual(retainedDraft.value as? String,"Retain this draft")
        XCTAssertFalse(app.staticTexts["composer.status"].waitForExistence(timeout:1))
        sidebar.tap()
        app.buttons["connection.disconnect"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertEqual(sidebar.label,"Expand sessions")
        XCTAssertEqual(app.staticTexts["connection.status"].label,"Connected")
        // Clear only the synthetic draft before the existing exact Paste check.
        retainedDraft.tap(); retainedDraft.press(forDuration:1)
        let selectAllDraft = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Select All")).firstMatch
        XCTAssertTrue(selectAllDraft.waitForExistence(timeout:3)); selectAllDraft.tap()
        retainedDraft.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(retainedDraft.value as? String,"")
        app.buttons["Dismiss keyboard"].tap()
        func historyPosition() -> [Int] {
            (evidence.value as? String ?? "").split(separator:":").compactMap { Int($0) }
        }
        let before = historyPosition()
        XCTAssertEqual(before.count,2)
        guard before.count == 2 else { return }
        XCTAssertGreaterThan(before[1],10)
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.25)).press(forDuration:0.05,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8)))
        let after = historyPosition()
        XCTAssertEqual(after.count,2)
        guard after.count == 2 else { return }
        // One ordinary swipe must travel at least one visible page of history,
        // not merely enter copy mode or move a few lines after repeated swipes.
        XCTAssertGreaterThanOrEqual(before[0]-after[0],before[1],"History travel: \(before) -> \(after)")
        XCTAssertEqual(evidence.label,"Older history rendered")
        // Select a rendered word locally. Copy must not depend on remote clipboard.
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.12,dy:0.3)).press(forDuration:1.0)
        let copy = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout:4))
        XCTAssertTrue(app.textViews["terminal.selection"].exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Paste")).firstMatch.exists)
        XCTAssertTrue((app.textViews["terminal.selection"].value as? String ?? "").contains("café 你好"))
        let selectionEvidence = XCTAttachment(screenshot:app.screenshot())
        selectionEvidence.name = "Native selection in disposable tmux"
        selectionEvidence.lifetime = .keepAlways; add(selectionEvidence)
        copy.tap()
        XCTAssertFalse(app.textViews["terminal.selection"].exists)
        let draft = app.descendants(matching:.any)["composer.draft"].firstMatch
        draft.tap(); draft.press(forDuration:1.0)
        let paste = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout:3)); paste.tap()
        XCTAssertFalse((draft.value as? String ?? "").isEmpty)
        XCTAssertEqual(draft.value as? String,"nativecopy")
        app.buttons["Return to live terminal"].tap()
        expectation(for:live,evaluatedWith:evidence)
        waitForExpectations(timeout:5)
        XCTAssertFalse(app.buttons["Return to live terminal"].exists)
        if app.buttons["Dismiss keyboard"].exists { app.buttons["Dismiss keyboard"].tap() }
        expectation(for:NSPredicate { _,_ in app.keyboards.count == 0 },evaluatedWith:app)
        waitForExpectations(timeout:5)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        // Rotation returns before SwiftUI and keyboard layout have necessarily
        // settled. Wait for stable landscape geometry before synthesizing input.
        var lastRect = CGRect.zero
        var unchangedSince = Date()
        expectation(for:NSPredicate { _,_ in
            let rect = surface.frame
            guard app.frame.width > app.frame.height, rect.width > rect.height, rect.height > 40 else { return false }
            if rect != lastRect { lastRect = rect; unchangedSince = Date(); return false }
            return Date().timeIntervalSince(unchangedSince) > 0.3
        },evaluatedWith:surface)
        waitForExpectations(timeout:5)
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.2)).press(forDuration:0.05,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.7)))
        XCTAssertTrue(app.buttons["Return to live terminal"].waitForExistence(timeout:3))
        app.buttons["Return to live terminal"].tap()
        XCTAssertEqual(draft.value as? String,"nativecopy")
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.12,dy:0.3)).press(forDuration:1.0)
        XCTAssertTrue(app.buttons["Close text selection"].waitForExistence(timeout:3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Close text selection"].isHittable)
        app.buttons["Close text selection"].tap()
        XCTAssertTrue(surface.exists)
    }
}

extension ChadmuxUITests {
    @MainActor
    func testForegroundResumeAgainstLiveTmux() throws {
        guard let fixture = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], fixture.hasPrefix("/") else { throw XCTSkip("Run test-transport.py --resume-ui") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--resume-live-fixture","--reset-resume-fixture"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = fixture
        app.launch()
        let draft = app.descendants(matching:.any)["composer.draft"].firstMatch
        func live(_ text:String) {
            expectation(for:NSPredicate { _,_ in
                app.staticTexts["connection.status"].label == "Connected" && draft.exists && draft.value as? String == text
            },evaluatedWith:app)
            waitForExpectations(timeout:20)
            XCTAssertTrue(app.descendants(matching:.any)["terminal.surface"].firstMatch.exists)
        }
        live("Unsent resume draft")
        draft.tap(); draft.typeText(" edited")
        let edited = try XCTUnwrap(draft.value as? String)
        XCTAssertTrue(edited.contains("edited")); XCTAssertTrue(edited.contains("Unsent resume draft"))
        // Home/activate drives the real SwiftUI scene lifecycle, not a model call.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5))
        app.activate(); live(edited)
        XCTAssertEqual(app.keyboards.count,0)
        XCTAssertFalse(app.textViews["terminal.selection"].exists)
        XCTAssertFalse(app.otherElements["sessions.sidebar"].exists)
        // Switch to the other retained session. Its draft and selected identity
        // must persist through an actual process termination and reconstruction.
        app.buttons["sessions.toggle"].tap()
        app.buttons.matching(NSPredicate(format:"label == %@","resume-second")).firstMatch.tap()
        live("Second retained draft")
        app.terminate()
        app.launchArguments = ["--resume-live-fixture"]
        app.launch(); live("Second retained draft")
        XCTAssertTrue(app.buttons["Collapse sessions"].exists)
        XCTAssertEqual(app.keyboards.count,0)
        let evidence = XCTAttachment(screenshot:app.screenshot())
        evidence.name = "Foreground resume - synthetic second session after cold launch"
        evidence.lifetime = .keepAlways; add(evidence)
        // Explicit Disconnect is durable and must defeat both warm and cold resume.
        app.buttons["sessions.toggle"].tap()
        app.buttons["connection.disconnect"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout:5))
        XCTAssertFalse(app.descendants(matching:.any)["terminal.surface"].firstMatch.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout:5))
        XCTAssertEqual(draft.value as? String,"Second retained draft")
        XCTAssertFalse(app.descendants(matching:.any)["terminal.surface"].firstMatch.exists)
        app.buttons["connection.connect"].tap(); live("Second retained draft")
    }
}


extension ChadmuxUITests {
    @MainActor
    func testOutsideSidebarTapDismissesWithoutActivatingUnderlyingControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing","--reset-test-profile","--composer-ui-fixture"]
        app.launch()
        let toggle = app.buttons["sessions.toggle"]
        let draft = app.descendants(matching:.any)["composer.draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout:5))
        draft.tap(); draft.typeText("Preserve my draft")
        app.buttons["Dismiss keyboard"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            var previousFrame = CGRect.zero
            var stableSince = Date()
            expectation(for:NSPredicate { _,_ in
                let frame = toggle.frame
                let correctOrientation = orientation == .portrait ? app.frame.height > app.frame.width : app.frame.width > app.frame.height
                guard correctOrientation, toggle.isHittable else { return false }
                if frame != previousFrame { previousFrame = frame; stableSince = Date(); return false }
                return Date().timeIntervalSince(stableSince) > 0.3
            },evaluatedWith:app)
            waitForExpectations(timeout:5)
            toggle.tap()
            // Session controls remain interactive, and selecting stays inside.
            app.buttons["session.Mac.$1"].tap()
            XCTAssertEqual(toggle.label,"Collapse sessions")
            app.buttons["session.Mac.$0"].tap()
            XCTAssertEqual(toggle.label,"Collapse sessions")
            app.buttons["Close Fixture on Mac"].tap()
            XCTAssertTrue(app.buttons["Discard draft and close"].waitForExistence(timeout:3))
            app.buttons["Cancel"].tap()
            draft.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            XCTAssertEqual(toggle.label,"Expand sessions")
            XCTAssertEqual(draft.value as? String,"Preserve my draft")
            XCTAssertEqual(app.keyboards.count,0)
            toggle.tap()
            app.buttons["Connection settings"].firstMatch.tap()
            XCTAssertEqual(toggle.label,"Expand sessions")
            XCTAssertFalse(app.buttons["hosts.done"].exists)
            // The very next tap works normally after the dismissal layer is gone.
            app.buttons["Connection settings"].firstMatch.tap()
            XCTAssertTrue(app.buttons["hosts.done"].waitForExistence(timeout:3))
            app.buttons["hosts.done"].tap()
        }
        XCUIDevice.shared.orientation = .portrait
        expectation(for:NSPredicate { _,_ in app.frame.height > app.frame.width },evaluatedWith:app)
        waitForExpectations(timeout:5)
        let evidence = XCTAttachment(screenshot:app.screenshot())
        evidence.name = "Sidebar dismissal retains synthetic draft"
        evidence.lifetime = .keepAlways; add(evidence)
    }
}

extension ChadmuxUITests {
    /// Create and end Claude sessions from the sidebar against a disposable SSH
    /// host running the real claude-tmux script with a fake `claude`.
    @MainActor
    func testCreateAndEndSessionsAgainstLiveTmux() throws {
        guard let fixture = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], fixture.hasPrefix("/") else { throw XCTSkip("Run test-transport.py --manage-ui") }
        struct Paths: Decodable { let projectsDir: String?; let claudeTmux: String? }
        let paths = try JSONDecoder().decode(Paths.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        guard paths.claudeTmux != nil, let projects = paths.projectsDir else { throw XCTSkip("Pass --claude-tmux to test-transport.py") }
        let folder = projects + "/phone project"
        let app = XCUIApplication()
        app.launchArguments = ["--session-manage-live-fixture"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = fixture
        app.launch()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func row(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch }
        func endButton(_ name: String) -> XCUIElement { app.buttons["End session " + name + " on Mac"] }
        // The sidebar container's identifier masks its children's, so use labels.
        let newSession = app.buttons["New Claude session on Mac"]
        func openSidebar() { if !newSession.exists { app.buttons["sessions.toggle"].tap() } }
        let existing = row("existing")
        XCTAssertTrue(existing.waitForExistence(timeout: 20))
        XCTAssertTrue(endButton("existing").exists)
        shot("1 Sidebar with + and − controls")

        // First, before anything reloads the list: "replace-me" was replaced on the
        // Mac after Chadmux listed it, so ending it must be refused, not kill the new one.
        let alert = app.alerts.firstMatch
        let error = app.staticTexts["connection.error"]
        endButton("replace-me").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["End session"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertEqual(error.label, "“replace-me” was replaced by a newer session with the same name, so it was not ended. Review the refreshed list before trying again.")
        XCTAssertTrue(row("replace-me").exists, "the replacement keeps running and is listed")
        shot("2 Replaced session refused")

        // Create: the sheet names the host, starts at the default folder, and opens the new session.
        newSession.tap()
        let nameField = app.textFields["newSession.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        let folderField = app.textFields["newSession.folder"]
        XCTAssertEqual(folderField.value as? String, "~")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Folder on Mac")).firstMatch.exists)
        XCTAssertFalse(app.buttons["newSession.create"].isEnabled)
        nameField.tap(); nameField.typeText("bad name")
        XCTAssertTrue(app.staticTexts["newSession.nameProblem"].exists)
        XCTAssertFalse(app.buttons["newSession.create"].isEnabled)
        nameField.clearAndType("phone-made")
        XCTAssertFalse(app.staticTexts["newSession.nameProblem"].exists)
        folderField.clearAndType(folder)
        shot("3 New session sheet")
        app.buttons["newSession.create"].tap()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 20), app.staticTexts["newSession.error"].exists ? app.staticTexts["newSession.error"].label : "sheet stayed open")
        let evidence = app.staticTexts["manage.fixture.evidence"]
        expectation(for: NSPredicate(format: "label == %@", "claude|" + folder + "|sleep"), evaluatedWith: evidence)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.staticTexts["phone-made"].exists) // selected tab title
        XCTAssertTrue(row("phone-made").exists)
        expectation(for: NSPredicate(format: "label == %@", "Connected"), evaluatedWith: app.staticTexts["connection.status"])
        waitForExpectations(timeout: 20)
        shot("4 Created session opened in a tab (claude running in the chosen folder)")

        // Duplicate name and missing folder: inline errors, the sheet stays open and editable.
        openSidebar()
        newSession.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(folderField.value as? String, folder, "the last folder used on this Mac is offered")
        nameField.tap(); nameField.typeText("phone-made")
        app.buttons["newSession.create"].tap()
        let sheetError = app.staticTexts["newSession.error"]
        XCTAssertTrue(sheetError.waitForExistence(timeout: 20))
        XCTAssertEqual(sheetError.label, "claude-tmux: session 'phone-made' already exists")
        shot("5 Duplicate name error inline")
        nameField.clearAndType("no-folder")
        folderField.clearAndType("~/definitely-missing-folder")
        app.buttons["newSession.create"].tap()
        expectation(for: NSPredicate(format: "label == %@", "claude-tmux: folder '~/definitely-missing-folder' does not exist"), evaluatedWith: sheetError)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(nameField.exists)
        shot("6 Missing folder error inline")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 5))
        XCTAssertFalse(row("no-folder").exists)

        // Rename with the pencil: the real tmux session is renamed; a taken name is refused inline.
        openSidebar()
        app.buttons["Rename session existing on Mac"].tap()
        let renameField = app.textFields["renameSession.name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        XCTAssertEqual(renameField.value as? String, "existing", "prefilled with the current name")
        renameField.clearAndType("replace-me")
        app.buttons["renameSession.rename"].tap()
        let renameError = app.staticTexts["renameSession.error"]
        XCTAssertTrue(renameError.waitForExistence(timeout: 20))
        XCTAssertEqual(renameError.label, "“replace-me” is already a session on Mac. Choose another name.")
        renameField.clearAndType("renamed-here")
        shot("6b Rename sheet")
        app.buttons["renameSession.rename"].tap()
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 20))
        openSidebar()
        XCTAssertTrue(row("renamed-here").waitForExistence(timeout: 10))
        XCTAssertFalse(row("existing").exists)
        shot("6c Renamed in the sidebar")
        // And back, so the rest of the test finds it.
        app.buttons["Rename session renamed-here on Mac"].tap()
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.clearAndType("existing")
        app.buttons["renameSession.rename"].tap()
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 20))
        openSidebar()
        XCTAssertTrue(existing.waitForExistence(timeout: 10))

        // End with Cancel (the default) changes nothing.
        openSidebar()
        endButton("existing").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.label, "End “existing”?")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "on Mac, including any Claude conversation")).firstMatch.exists)
        shot("7 End confirmation names session and host")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(existing.exists)
        XCTAssertTrue(endButton("existing").exists)
        app.buttons["Refresh Mac sessions"].tap()
        XCTAssertTrue(existing.waitForExistence(timeout: 10), "still running on the Mac after Cancel")

        // End the open tab's session: the tab stays, shows it is gone, and keeps its draft.
        row("phone-made").tap()
        let draft = app.descendants(matching: .any)["composer.draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        // A tap outside an open sidebar only dismisses it, so close it first.
        if newSession.exists { app.buttons["sessions.toggle"].tap() }
        draft.tap(); draft.typeText("Draft kept after ending")
        openSidebar()
        endButton("phone-made").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["End session"].tap()
        XCTAssertTrue(endButton("phone-made").waitForNonExistence(timeout: 20))
        XCTAssertTrue(row("phone-made").exists, "the tab remains until explicitly closed")
        XCTAssertTrue(app.staticTexts["Session no longer exists"].waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "Draft kept after ending")
        XCTAssertFalse(error.exists)
        shot("8 Ended session: tab kept with its draft")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            // A long value is displayed truncated, so a tap cannot reliably place
            // the cursor at its end: select everything and delete it instead.
            press(forDuration: 1.0)
            let selectAll = XCUIApplication().menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 3) { selectAll.tap(); typeText(XCUIKeyboardKey.delete.rawValue) }
            let remaining = value as? String ?? ""  // an empty field reports its placeholder
            XCTAssertTrue(remaining.isEmpty || remaining == placeholderValue, "field still contains " + remaining)
        }
        typeText(text)
    }
}

extension ChadmuxUITests {
    /// Offline: host settings, switching and persistence need no connection.
    @MainActor
    func testHostsCanBeAddedSwitchedRenamedAndRemoved() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-profile"]
        app.launch()
        func fill(_ id: String, _ text: String) {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5), id)
            field.tap()
            if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
                field.press(forDuration: 1.0)
                if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            field.typeText(text)
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        // First host.
        XCTAssertTrue(app.staticTexts["Add a host"].waitForExistence(timeout: 5))
        app.buttons["Connection settings"].firstMatch.tap()
        fill("connection.host", "mac.example"); fill("connection.username", "user"); fill("host.folder", "~/Projects")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.staticTexts["Connect to Mac"].waitForExistence(timeout: 5))
        app.buttons["sessions.toggle"].tap()
        XCTAssertTrue(app.buttons["Refresh Mac sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect to Mac"].exists)
        app.buttons["sessions.toggle"].tap()

        // Second host, from the list; a duplicate label is refused.
        app.buttons["Connection settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["hosts.row.Mac"].waitForExistence(timeout: 5))
        app.buttons["hosts.add"].tap()
        XCTAssertEqual(app.textFields["host.label"].value as? String, app.textFields["host.label"].placeholderValue)
        fill("host.label", "mac"); fill("connection.host", "arch.example"); fill("connection.username", "user")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.staticTexts["host.error"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["host.error"].label, "Another host already uses that label or that user and address.")
        fill("host.label", "Arch")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.buttons["hosts.row.Arch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["hosts.row.Mac"].exists)
        shot("Hosts list with Mac and Arch")
        app.buttons["hosts.done"].tap()

        // Both hosts appear in the one sidebar, each with its own status and controls.
        app.buttons["sessions.toggle"].tap()
        XCTAssertTrue(app.buttons["Refresh Arch sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh Mac sessions"].exists)
        XCTAssertTrue(app.buttons["Connect to Mac"].exists)
        XCTAssertTrue(app.buttons["Connect to Arch"].exists)
        XCTAssertFalse(app.buttons["New Claude session on Arch"].isEnabled, "create needs that host connected")
        XCTAssertEqual(app.staticTexts["session.host"].label, "Mac", "the first host is on screen")
        shot("Both hosts in one sidebar")
        app.buttons["sessions.toggle"].tap()

        // Rename and change its default folder.
        app.buttons["Connection settings"].firstMatch.tap()
        if !app.buttons["hosts.row.Arch"].waitForExistence(timeout: 3) { app.buttons["Connection settings"].firstMatch.tap() }
        app.buttons["hosts.row.Arch"].tap()
        fill("host.label", "Arch Linux")
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.buttons["hosts.row.Arch Linux"].waitForExistence(timeout: 5))

        // Relaunch: both hosts persist.
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["Connection settings"].firstMatch.tap()
        // The sidebar reopens as it was left; the first tap only closes it.
        if !app.buttons["hosts.done"].waitForExistence(timeout: 2) { app.buttons["Connection settings"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["hosts.row.Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["hosts.row.Arch Linux"].exists)

        // Remove Arch with confirmation.
        app.buttons["hosts.row.Arch Linux"].tap()
        XCTAssertTrue(app.textFields["host.label"].waitForExistence(timeout: 5))
        for _ in 0..<6 where !app.buttons["host.remove"].exists { app.swipeUp() }
        app.buttons["host.remove"].tap()
        XCTAssertTrue(app.staticTexts["Remove Arch Linux?"].waitForExistence(timeout: 3))
        // The dialog's button, not the form's: the last "Remove host" once it is showing.
        let removeButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Remove host")).allElementsBoundByIndex
        try XCTUnwrap(removeButtons.last(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["hosts.row.Mac"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hosts.row.Arch Linux"].exists)
        shot("Arch removed")
        app.buttons["hosts.done"].tap()
        XCTAssertTrue(app.staticTexts["Connect to Mac"].waitForExistence(timeout: 5))
    }
}

extension ChadmuxUITests {
    /// Two real hosts (independent tmux servers behind a disposable sshd) and
    /// an offline one, all in one sidebar. Never touches personal sessions.
    @MainActor
    func testMultipleHostsInOneSidebarAgainstLiveTmux() throws {
        guard let fixture = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], fixture.hasPrefix("/") else { throw XCTSkip("Run test-transport.py --multi-ui") }
        // The second ("Arch") host's socket; the fixture key was renamed from tmuxSocket2
        // when Linux hosts arrived (17320fa), which silently skipped this test since.
        struct Paths: Decodable { let projectsDir: String?; let claudeTmux: String?; let archTmuxSocket: String? }
        let paths = try JSONDecoder().decode(Paths.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        guard paths.claudeTmux != nil, paths.archTmuxSocket != nil, let projects = paths.projectsDir else { throw XCTSkip("Pass --claude-tmux to test-transport.py") }
        let app = XCUIApplication()
        app.launchArguments = ["--multi-host-live-fixture"]
        app.launchEnvironment["CHADMUX_TRANSPORT_FIXTURE"] = fixture
        app.launch()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func waitFor(_ element: XCUIElement, label format: String, _ value: String, timeout: TimeInterval = 20) {
            expectation(for: NSPredicate(format: "label " + format + " %@", value), evaluatedWith: element)
            waitForExpectations(timeout: timeout)
        }
        let macShared = app.buttons["session.Mac.$0"], archShared = app.buttons["session.Arch.$0"]
        XCTAssertTrue(macShared.waitForExistence(timeout: 30))
        XCTAssertTrue(archShared.waitForExistence(timeout: 30))
        XCTAssertEqual(macShared.label, "shared-name"); XCTAssertEqual(archShared.label, "shared-name")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "mac-only")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "arch-only")).firstMatch.exists)
        // The offline host fails on its own and says so, without holding up the others.
        let offlineStatus = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline status:")).firstMatch
        XCTAssertTrue(offlineStatus.waitForExistence(timeout: 10))
        waitFor(offlineStatus, label: "==", "Offline status: Offline", timeout: 40)
        XCTAssertTrue(app.buttons["Connect to Offline"].exists, "an offline host can be retried")
        XCTAssertFalse(app.buttons["New Claude session on Offline"].isEnabled)
        XCTAssertTrue(app.buttons["New Claude session on Mac"].isEnabled)
        XCTAssertTrue(app.buttons["New Claude session on Arch"].isEnabled)
        shot("1 Three hosts: two connected, one offline")

        // The same session name and id on two hosts opens two separate tabs.
        let evidence = app.staticTexts["manage.fixture.evidence"]
        archShared.tap()
        XCTAssertTrue(evidence.waitForExistence(timeout: 20))
        waitFor(evidence, label: "BEGINSWITH", "Arch|shared-name|")
        XCTAssertEqual(app.staticTexts["session.host"].label, "Arch", "the tab's host badge")
        shot("2 Arch's shared-name on screen")
        macShared.tap()
        waitFor(evidence, label: "BEGINSWITH", "Mac|shared-name|")
        XCTAssertEqual(app.staticTexts["session.host"].label, "Mac")
        XCTAssertTrue(app.buttons["Close shared-name on Mac"].exists)
        XCTAssertTrue(app.buttons["Close shared-name on Arch"].exists)
        archShared.tap()
        waitFor(evidence, label: "BEGINSWITH", "Arch|shared-name|")
        shot("3 Back on Arch: both tabs stay open")

        // + on Arch creates the session on Arch only.
        app.buttons["New Claude session on Arch"].tap()
        let nameField = app.textFields["newSession.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Folder on Arch")).firstMatch.exists)
        nameField.tap(); nameField.typeText("arch-made")
        let folderField = app.textFields["newSession.folder"]
        folderField.tap()
        folderField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap(); folderField.typeText(XCUIKeyboardKey.delete.rawValue) }
        folderField.typeText(projects + "/phone project")
        app.buttons["newSession.create"].tap()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 20))
        waitFor(evidence, label: "==", "Arch|arch-made|claude|" + projects + "/phone project")
        XCTAssertEqual(app.staticTexts["session.host"].label, "Arch")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "arch-made")).count, 1, "listed under Arch only")
        shot("4 Created on Arch with +")

        // − on Mac ends only Mac's session.
        if !app.buttons["New Claude session on Mac"].exists { app.buttons["sessions.toggle"].tap() }
        app.buttons["End session mac-only on Mac"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "on Mac, including any Claude conversation")).firstMatch.exists)
        alert.buttons["End session"].tap()
        XCTAssertTrue(app.buttons["End session mac-only on Mac"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "arch-only")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Close shared-name on Mac"].exists)
        // The offline host's error stays in its own section, not under the terminal.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline error:")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["connection.error"].exists)
        shot("5 Ended on Mac only; Offline still isolated")
    }
}
