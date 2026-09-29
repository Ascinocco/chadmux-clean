import Foundation
import Network

/// Reads a host's SSH identification line without authenticating, to explain
/// problems before connecting: nothing listening (e.g. Remote Login off), or
/// Tailscale SSH answering instead of OpenSSH (Chadmux relies on OpenSSH).
enum SSHProbe {
    enum Result: Equatable {
        case openSSH(String), tailscaleSSH(String), otherSSH(String), notSSH, unreachable
        var message: String {
            switch self {
            case .openSSH(let banner): return "OpenSSH is answering (\(banner))."
            case .tailscaleSSH: return "Tailscale SSH is answering on port 22, not OpenSSH. Chadmux uses OpenSSH with this device's key: turn Tailscale SSH off on that host (tailscale set --ssh=false)."
            case .otherSSH(let banner): return "An SSH server is answering (\(banner))."
            case .notSSH: return "Something is listening on that port, but it isn't an SSH server."
            case .unreachable: return "No SSH server is answering. Check the address and Tailscale, and that the host is awake with SSH enabled."
            }
        }
        var isProblem: Bool { self == .notSSH || self == .unreachable || { if case .tailscaleSSH = self { return true }; return false }() }
    }

    static func classify(_ line: String) -> Result {
        let banner = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard banner.hasPrefix("SSH-") else { return .notSSH }
        let shown = String(banner.prefix(64))
        if banner.localizedCaseInsensitiveContains("tailscale") { return .tailscaleSSH(shown) }
        if banner.hasPrefix("SSH-2.0-OpenSSH") { return .openSSH(shown) }
        return .otherSSH(shown)
    }

    static func probe(host: String, port: Int, timeout: TimeInterval = 5) async -> Result {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { return .unreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let outcome = ProbeOutcome()
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Result) -> Void = { result in
                if outcome.claim() { connection.cancel(); continuation.resume(returning: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, _, error in
                        guard error == nil, let data, let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first else { return finish(.notSSH) }
                        finish(classify(String(line)))
                    }
                case .failed, .waiting: finish(.unreachable)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.unreachable) }
        }
    }
    private final class ProbeOutcome: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
}
