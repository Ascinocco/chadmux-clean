import Foundation
import Citadel

/// Creates and closes Claude tmux sessions through the host's own `claude-tmux`
/// script, so a phone-made session is the same as one made in a terminal.
struct ClaudeTmux {
    /// nil uses the installed `~/.claude/scripts/claude-tmux.sh` on the host.
    var scriptPath: String?
    /// SSH exec skips the interactive Homebrew configuration that provides tmux.
    var pathPrefix = "/opt/homebrew/bin:/usr/local/bin"

    static let installedScript = "~/.claude/scripts/claude-tmux.sh"
    static let exitMarker = "chadmux-exit"

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// Runs the script through the user's login shell so `claude` is on PATH,
    /// then always reports its exit status: Citadel discards output on failure.
    func command(_ arguments: [String]) -> String {
        let q = SSHPrimitives.shellQuote
        let script = scriptPath.map(q) ?? "\"$HOME\"/.claude/scripts/claude-tmux.sh"
        let inner = "PATH=" + q(pathPrefix) + ":\"$PATH\"; export PATH; "
            + ([script] + arguments.map(q)).joined(separator: " ")
        return "\"${SHELL:-/bin/sh}\" -lc " + q(inner) + " </dev/null; printf '\\n\\036"
            + Self.exitMarker + ":%s\\037\\n' \"$?\""
    }
    func createCommand(name: String, folder: String) -> String {
        command(["create", name, "--dir", folder])
    }
    func closeCommand(_ session: RemoteSession) -> String {
        command(["close", session.name, "--id", session.id] + (session.instance.isEmpty ? [] : ["--instance", session.instance]))
    }
    /// Renames by id (and instance), so a session renamed or replaced elsewhere
    /// since the last listing is never renamed by mistake.
    func renameCommand(_ session: RemoteSession, to name: String) -> String {
        command(["rename", session.name, name, "--id", session.id] + (session.instance.isEmpty ? [] : ["--instance", session.instance]))
    }
    /// Names a session can be renamed to: as for create, and not starting with
    /// `-` (claude-tmux refuses those rather than sanitizing them).
    static func validNewName(_ name: String) -> Bool { validName(name) && !name.hasPrefix("-") }

    struct Reply: Decodable, Equatable {
        let ok: Bool
        var name: String?
        var old: String?
        var id: String?
        var dir: String?
        var error: String?
        var message: String?
    }
    enum Outcome: Equatable {
        case succeeded(Reply)
        case failed(error: String, message: String)
    }
    struct ConnectionLost: Error {}

    static func parse(_ output: String) throws -> Outcome {
        guard let start = output.range(of: "\u{1e}" + exitMarker + ":", options: .backwards),
              let end = output[start.upperBound...].firstIndex(of: "\u{1f}"),
              let status = Int(output[start.upperBound..<end]) else { throw ConnectionLost() }
        let body = output[..<start.lowerBound]
        // Login-shell startup files may print too; the script's reply is its JSON line.
        let reply = body.split(whereSeparator: \.isNewline).reversed().lazy
            .filter { $0.hasPrefix("{") }
            .compactMap { try? JSONDecoder().decode(Reply.self, from: Data($0.utf8)) }.first
        if let reply {
            if reply.ok && status == 0 { return .succeeded(reply) }
            return .failed(error: reply.error ?? "failed", message: reply.message ?? "claude-tmux failed (exit \(status)).")
        }
        if status == 127 || status == 126 {
            return .failed(error: "not_installed", message: "claude-tmux is not installed at \(installedScript) on this host. Install claude-tmux there (scripts/install-claude-tmux.sh from github.com/Ascinocco/q-factory-clean).")
        }
        let last = body.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return .failed(error: "failed", message: "claude-tmux failed (exit \(status))" + (last.isEmpty ? "." : ": " + String(last.prefix(300))))
    }

    func run(_ command: String, using client: SSHClient) async throws -> Outcome {
        let output = try await client.executeCommand(command, maxResponseSize: 65536, mergeStreams: true)
        return try Self.parse(String(buffer: output))
    }
}
