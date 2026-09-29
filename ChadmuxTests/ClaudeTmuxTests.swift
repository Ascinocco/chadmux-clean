import XCTest
@testable import Chadmux

final class ClaudeTmuxTests: XCTestCase {
    func testNameValidationMatchesScriptCharset() {
        for valid in ["a", "claude-demo", "Proj_2", String(repeating: "x", count: 64)] {
            XCTAssertTrue(ClaudeTmux.validName(valid), valid)
        }
        for invalid in ["", "has space", "dot.name", "colon:name", "semi;colon", "$(x)", "'q'", "tab\tname",
                        "new\nline", "你好", "é", String(repeating: "x", count: 65)] {
            XCTAssertFalse(ClaudeTmux.validName(invalid), invalid)
        }
    }

    func testCreateCommandQuotesEveryArgumentForBothShellLayers() {
        let command = ClaudeTmux().createCommand(name: "demo", folder: "~/it's $(touch pwned) \"dir\"")
        XCTAssertEqual(command,
            #""${SHELL:-/bin/sh}" -lc 'PATH='\''/opt/homebrew/bin:/usr/local/bin'\'':"$PATH"; export PATH; "$HOME"/.claude/scripts/claude-tmux.sh '\''create'\'' '\''demo'\'' '\''--dir'\'' '\''~/it'\''\'\'''\''s $(touch pwned) "dir"'\''' </dev/null; printf '\n\036chadmux-exit:%s\037\n' "$?""#)
    }

    func testInnerCommandUnquotesToLiteralArguments() throws {
        // Undo the outer quoting exactly as sh would, and check the login shell
        // receives each value as one literal word with nothing left to expand.
        let hostile = "a'b\"c $(d) `e` ;f |g \\h\n你好"
        let command = ClaudeTmux(scriptPath: "/tmp/x y/claude-tmux.sh").command(["close", hostile])
        let inner = try XCTUnwrap(singleQuoted(after: " -lc ", in: command))
        XCTAssertEqual(inner, "PATH='/opt/homebrew/bin:/usr/local/bin':\"$PATH\"; export PATH; '/tmp/x y/claude-tmux.sh' 'close' " + SSHPrimitives.shellQuote(hostile))
        XCTAssertEqual(try XCTUnwrap(singleQuoted(after: "'close' ", in: inner)), hostile)
    }

    func testCloseCommandBindsIdAndInstance() {
        let session = RemoteSession(id: "$7", name: "alpha $(x)", instance: "123:1700000000")
        let command = ClaudeTmux(scriptPath: "/s").closeCommand(session)
        XCTAssertTrue(command.contains(#"'\''close'\'' '\''alpha $(x)'\'' '\''--id'\'' '\''$7'\'' '\''--instance'\'' '\''123:1700000000'\''"#), command)
        let unknown = ClaudeTmux(scriptPath: "/s").closeCommand(RemoteSession(id: "$7", name: "n"))
        XCTAssertFalse(unknown.contains("--instance"))
    }

    func testParseSuccessIgnoresLoginShellNoise() throws {
        let output = "Now using node v22\n{\"not\":\"ours\"\nclaude-tmux: warning\n{\"ok\":true,\"name\":\"demo\",\"id\":\"$3\",\"dir\":\"/Users/me/Projects\"}\n\u{1e}chadmux-exit:0\u{1f}\n"
        XCTAssertEqual(try ClaudeTmux.parse(output), .succeeded(.init(ok: true, name: "demo", id: "$3", dir: "/Users/me/Projects")))
    }

    func testParseReportsScriptErrorsVerbatim() throws {
        let cases: [(String, Int, String)] = [
            ("name_taken", 3, "claude-tmux: session 'demo' already exists"),
            ("folder_missing", 4, "claude-tmux: folder '~/nope' does not exist"),
            ("claude_missing", 5, "claude-tmux: claude CLI not found on PATH"),
            ("replaced", 8, "claude-tmux: session 'x' was replaced; refusing to close it"),
        ]
        for (error, status, message) in cases {
            let body = message + "\n{\"ok\":false,\"error\":\"\(error)\",\"message\":\"\(message)\"}\n\u{1e}chadmux-exit:\(status)\u{1f}\n"
            XCTAssertEqual(try ClaudeTmux.parse(body), .failed(error: error, message: message))
        }
    }

    func testParseNeverTreatsANonZeroExitAsSuccess() throws {
        let output = "{\"ok\":true,\"name\":\"demo\",\"id\":\"$3\"}\n\u{1e}chadmux-exit:1\u{1f}"
        guard case .failed = try ClaudeTmux.parse(output) else { return XCTFail("exit 1 must not succeed") }
    }

    func testParseExplainsMissingScriptAndUnknownFailures() throws {
        let missing = "zsh:1: no such file or directory: /Users/me/.claude/scripts/claude-tmux.sh\n\u{1e}chadmux-exit:127\u{1f}\n"
        guard case .failed("not_installed", let message) = try ClaudeTmux.parse(missing) else { return XCTFail() }
        XCTAssertTrue(message.contains("install-claude-tmux.sh"))
        let other = "boom\n\u{1e}chadmux-exit:1\u{1f}\n"
        XCTAssertEqual(try ClaudeTmux.parse(other), .failed(error: "failed", message: "claude-tmux failed (exit 1): boom"))
    }

    func testParseRejectsOutputWithoutAnExitStatus() {
        // A dropped connection must not be mistaken for any script result.
        for truncated in ["{\"ok\":true,\"name\":\"demo\",\"id\":\"$3\"}\n", "\u{1e}chadmux-exit:0", "\u{1e}chadmux-exit:x\u{1f}", ""] {
            XCTAssertThrowsError(try ClaudeTmux.parse(truncated)) { XCTAssertTrue($0 is ClaudeTmux.ConnectionLost) }
        }
        // An echoed command line contains the marker text but not a status.
        let echoed = ClaudeTmux().createCommand(name: "a", folder: "/b")
        XCTAssertThrowsError(try ClaudeTmux.parse(echoed))
    }

    @MainActor
    func testCreateRefusesBeforeContactingTheMac() async {
        let name = "com.chadmux.claude-tmux-tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let workspace = SessionWorkspace(connection: MacTransport(preferences: prefs, secrets: SecretStore(service: name)))
        workspace.hostLabel = "Arch"
        let invalid = await workspace.createSession(name: "bad name", folder: "~")
        XCTAssertEqual(invalid, "Use 1–64 letters, numbers, hyphens or underscores for the name.")
        let emptyFolder = await workspace.createSession(name: "ok", folder: "  ")
        XCTAssertEqual(emptyFolder, "Enter a folder on Arch.")
        let offline = await workspace.createSession(name: "ok", folder: "~")
        XCTAssertEqual(offline, "Connect to Arch before creating a session.")
        workspace.tabs = (0..<8).map { SessionTab(session: RemoteSession(id: "$\($0)", name: "t\($0)"), profile: MacConnection(), secrets: SecretStore(service: name)) }
        let full = await workspace.createSession(name: "ok", folder: "~")
        XCTAssertEqual(full, "Close a tab before creating another session (eight open tabs maximum).")
        XCTAssertFalse(workspace.creatingSession)
    }

    @MainActor
    func testEndRequiresConnectionAndFolderDefaultIsPerMac() async {
        let name = "com.chadmux.claude-tmux-tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let transport = MacTransport(preferences: prefs, secrets: SecretStore(service: name))
        let workspace = SessionWorkspace(connection: transport)
        workspace.hostLabel = "Arch"
        await workspace.endSession(RemoteSession(id: "$1", name: "x", instance: "1:2"))
        XCTAssertEqual(workspace.error, "Connect to Arch before ending a session.")
        XCTAssertNil(workspace.endingSessionID)
        XCTAssertEqual(workspace.newSessionFolder, "~")
        try? transport.save(MacConnection(host: "mac-a", port: 22, username: "me"))
        workspace.newSessionFolder = "~/Projects"
        try? transport.save(MacConnection(host: "mac-b", port: 22, username: "me"))
        XCTAssertEqual(workspace.newSessionFolder, "~")
        try? transport.save(MacConnection(host: "mac-a", port: 22, username: "me"))
        XCTAssertEqual(workspace.newSessionFolder, "~/Projects")
    }

    func testRenameCommandBindsIdAndInstanceAndQuotesNames() throws {
        let session = RemoteSession(id: "$4", name: "old $(x)", instance: "321:1700000001")
        let command = ClaudeTmux(scriptPath: "/s").renameCommand(session, to: "new-name")
        XCTAssertTrue(command.contains(#"'\''rename'\'' '\''old $(x)'\'' '\''new-name'\'' '\''--id'\'' '\''$4'\'' '\''--instance'\'' '\''321:1700000001'\''"#), command)
        let inner = try XCTUnwrap(singleQuoted(after: " -lc ", in: command))
        XCTAssertEqual(try XCTUnwrap(singleQuoted(after: "'rename' ", in: inner)), "old $(x)", "the old name arrives as one literal word")
        XCTAssertFalse(ClaudeTmux(scriptPath: "/s").renameCommand(RemoteSession(id: "$4", name: "n"), to: "m").contains("--instance"))
    }

    func testRenameNamesFollowTheScript() {
        for valid in ["a", "renamed", "Proj_2", "x-", String(repeating: "x", count: 64)] {
            XCTAssertTrue(ClaudeTmux.validNewName(valid), valid)
        }
        for invalid in ["", "-lead", "has space", "dot.name", "co:lon", "$(x)", "é", String(repeating: "x", count: 65)] {
            XCTAssertFalse(ClaudeTmux.validNewName(invalid), invalid)
        }
    }

    func testParseRenameReplyCarriesOldAndNewNames() throws {
        let output = "{\"ok\":true,\"old\":\"before\",\"name\":\"after\",\"id\":\"$2\"}\n\u{1e}chadmux-exit:0\u{1f}\n"
        guard case .succeeded(let reply) = try ClaudeTmux.parse(output) else { return XCTFail("expected success") }
        XCTAssertEqual(reply.old, "before"); XCTAssertEqual(reply.name, "after"); XCTAssertEqual(reply.id, "$2")
    }

    func testRenameFailuresReadWellAndOldScriptsSayToUpdate() throws {
        func message(_ error: String) -> String {
            SessionWorkspace.renameFailure(error, message: "raw \(error)", old: "before", new: "after", host: "Arch")
        }
        XCTAssertEqual(message("name_taken"), "“after” is already a session on Arch. Choose another name.")
        XCTAssertEqual(message("not_found"), "“before” is no longer running on Arch.")
        XCTAssertTrue(message("replaced").hasPrefix("“before” was replaced by a newer session"))
        let update = "Update claude-tmux on Arch to rename sessions (scripts/install-claude-tmux.sh from github.com/Ascinocco/q-factory-clean)."
        XCTAssertEqual(message("usage"), update)
        XCTAssertEqual(message("failed"), update)
        XCTAssertEqual(message("invalid_name"), "raw invalid_name")
        XCTAssertEqual(message("not_installed"), "raw not_installed")
        // An older script prints no JSON for an unknown command: that parses as "failed".
        guard case .failed(let error, _) = try ClaudeTmux.parse("open terminal failed: not a terminal\n\u{1e}chadmux-exit:1\u{1f}\n") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, "failed")
    }

    @MainActor
    func testRenameRefusesBeforeContactingTheHost() async {
        let name = "com.chadmux.claude-tmux-tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let workspace = SessionWorkspace(connection: MacTransport(preferences: prefs, secrets: SecretStore(service: name)))
        workspace.hostLabel = "Arch"
        let session = RemoteSession(id: "$1", name: "before", instance: "1:2")
        let invalid = await workspace.renameSession(session, to: "bad name")
        XCTAssertEqual(invalid, "Use 1–64 letters, numbers, hyphens or underscores, not starting with a hyphen.")
        let leadingDash = await workspace.renameSession(session, to: "-x")
        XCTAssertEqual(leadingDash, invalid)
        let unchanged = await workspace.renameSession(session, to: " before ")
        XCTAssertNil(unchanged, "the same name is a no-op, even offline")
        let offline = await workspace.renameSession(session, to: "after")
        XCTAssertEqual(offline, "Connect to Arch before renaming a session.")
        XCTAssertNil(workspace.renamingSessionID)
    }

    /// The content of the first single-quoted shell word after `marker`, unquoted
    /// the way POSIX sh does ('\'' closes, escapes a quote and reopens).
    private func singleQuoted(after marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        var rest = text[start.upperBound...]
        var result = ""
        guard rest.first == "'" else { return nil }
        rest = rest.dropFirst()
        while let quote = rest.firstIndex(of: "'") {
            result += rest[..<quote]
            rest = rest[rest.index(after: quote)...]
            if rest.hasPrefix("\\''") { result += "'"; rest = rest.dropFirst(3) } else { return result }
        }
        return nil
    }
}
